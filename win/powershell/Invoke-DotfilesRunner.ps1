# PowerShell の dotfiles 関数 (win/powershell/dotfiles.ps1) と dotfiles --self-update (Invoke-DotfilesSelfUpdate.ps1) が runner を起こす launcher
# (win/README.md の「runner の exe (Release)」。dotfiles-private の docs/adr/117_win_runner_exe_release_*)。配った写しでなく clone の中のこの script を
# 呼ぶので、直した pull は、$PROFILE で読んだ関数が古いままでも次の呼び出しから効く。
#
#   Invoke-DotfilesRunner.ps1 <clone> [<runner の引数>…]
#
# runner の exe は CI (.github/workflows/win-runner-release.yml) が作り、public な dotfiles の GitHub の Release に置く。key は clone の HEAD の
# win/runner の git の tree の hash (git rev-parse HEAD:win/runner) で、Release は win-runner-<key の頭 12 字>、asset は dotfiles-win.exe と
# dotfiles-win.exe.sha256。この script は、clone に合う key の exe を %LOCALAPPDATA%\dotfiles\runner\<key>\ に置き (無ければ落として sha256 と、exe が
# version で名乗る key を確かめてから)、runner の引数の 1 つ目の後ろに --repo <clone> を差し込んで起こす。
#
# 選び方 (環境変数 DOTFILES_RUNNER。空なら自動):
#   - 自動: 置き場の exe を使う。無ければ落とす。win/runner に commit していない変更があれば cargo で build する (cargo が無ければ ⚠ を出して
#     HEAD の exe で流す)。落とせない (Release が無い・つながらない) ときは cargo があれば build し、無ければ直し方を出して止まる
#   - exe: cargo を使わない (落とせなければ止まる)
#   - cargo: いつも win\runner で cargo run --quiet --release --locked -- <引数> (今までの形。--repo は渡さない: 手元の build の既定の clone は
#     その clone)
# sha256 か key が合わないときは、cargo があっても黙って build に戻らずに止まる。exe を起こせない (Smart App Control・App Control・AppLocker に
# 止められた・DLL が無い) ときは、自動で cargo があれば build に戻る (%LOCALAPPDATA% の exe を止める決まりでも、clone の中で作った exe は通ることがある)。
# URL の根は環境変数 DOTFILES_RUNNER_BASE_URL で替えられる (試験用)。
#
# 終了コード: runner の終了コード。この script が runner を起こせないときは 2。Ctrl+C で止めたときは 1。
#
# BOM 付きの UTF-8 で保存すること。Windows PowerShell 5.1 でも動かす (7 にしか無い書き方を使わない。Invoke-DotfilesRunner.Tests.ps1 が見る)。
# 引数は $args で受ける (param ブロックを置くと、runner の -h などを PowerShell が自分の引数の名前として読む)。
# dot-source したとき (テスト) は関数だけを読み、本体は走らせない (末尾)。

# 既定の URL の根 (Release の download の URL。REST API は呼ばない)
$script:DotfilesRunnerBaseUrl = 'https://github.com/pollenjp/dotfiles/releases/download'
# Release の asset の名前
$script:DotfilesRunnerExeName = 'dotfiles-win.exe'
$script:DotfilesRunnerShaName = 'dotfiles-win.exe.sha256'
# version で key を確かめた印 (置き場の key のディレクトリの中)
$script:DotfilesRunnerMarkName = 'verified'
# 置き場に残す key のディレクトリの数 (今の key を含む)
$script:DotfilesRunnerKeep = 3

# ---------------------------------------------------------------------------
# 副作用の無い関数 (Invoke-DotfilesRunner.Tests.ps1 で確かめる)
# ---------------------------------------------------------------------------

# 環境変数 DOTFILES_RUNNER の値から選び方を決める (auto・exe・cargo。大文字小文字は区別する)。分からない値なら $null
function Get-DotfilesRunnerMode {
    param([string]$Value)
    if (-not $Value) { return 'auto' }
    if ($Value -ceq 'exe') { return 'exe' }
    if ($Value -ceq 'cargo') { return 'cargo' }
    $null
}

# key の形 (git の SHA-1 の object の名前。40 字の小文字の 16 進) か
function Test-DotfilesRunnerKey {
    param([string]$Key)
    [bool]("$Key" -cmatch '^[0-9a-f]{40}$')
}

# key の Release の tag
function Get-DotfilesRunnerTag {
    param([string]$Key)
    "win-runner-$($Key.Substring(0, 12))"
}

# key の Release の asset の URL
function Get-DotfilesRunnerUrl {
    param([string]$BaseUrl, [string]$Key, [string]$Name)
    "$($BaseUrl.TrimEnd('/'))/$(Get-DotfilesRunnerTag -Key $Key)/$Name"
}

# .sha256 のファイルの中身 (sha256sum の形「<64 字>  <名前>」) から、1 行目の頭の 64 字の 16 進を小文字で。無ければ空
function ConvertFrom-DotfilesRunnerSha256 {
    param([string]$Text)
    $lines = @("$Text" -split "`r?`n" | Where-Object { $_.Trim() })
    if ($lines.Count -eq 0) { return '' }
    $token = @($lines[0].Trim() -split '\s+')[0]
    if ($token -match '^[0-9a-fA-F]{64}$') { return $token.ToLowerInvariant() }
    ''
}

# 置き場の key のディレクトリ (%LOCALAPPDATA%\dotfiles\runner\<key>)
function Get-DotfilesRunnerCacheDir {
    param([string]$LocalAppData, [string]$Key)
    [IO.Path]::Combine($LocalAppData, 'dotfiles', 'runner', $Key)
}

# exe に渡す引数。runner の引数の 1 つ目 (コマンド) の直後に --repo <clone> を差し込む (runner はオプションをコマンドの後ろのどこでも受け、
# import の -- より前なので名前と混ざらない)。引数が無ければ何も足さない (runner が使い方を出す)
function Get-DotfilesRunnerArgs {
    param([string]$Clone, [string[]]$Arguments)
    $all = @($Arguments)
    if ($all.Count -eq 0) { return @() }
    $result = @($all[0], '--repo', $Clone)
    if ($all.Count -gt 1) { $result += @($all[1..($all.Count - 1)]) }
    $result
}

# 消す key のディレクトリの名前。今の key は消さず、ほかを新しい順に (Keep - 1) 個残す。key の形でない名前には触らない
function Select-DotfilesRunnerStaleDirs {
    param([object[]]$Dirs, [string]$Current, [int]$Keep = 3)
    $others = @(@($Dirs) | Where-Object {
            $_ -and (Test-DotfilesRunnerKey -Key "$($_.Name)") -and ("$($_.Name)" -cne $Current)
        } | Sort-Object -Property LastWriteTime -Descending)
    $keepOthers = [Math]::Max(0, $Keep - 1)
    if ($others.Count -le $keepOthers) { return @() }
    @($others[$keepOthers..($others.Count - 1)] | ForEach-Object { "$($_.Name)" })
}

# 選び方の決まり (win/README.md の「runner の exe (Release)」の表)。Action は cached (置き場のものを使う)・download (落とす)・cargo (手元で
# build する)・error (止まる)。Notes は · の行、Warn は ⚠ の行、Error は止めるわけ。GitMessage は key を読めなかったときの git の文 (わけに添える)
function Get-DotfilesRunnerDecision {
    param([string]$Mode, [bool]$HaveGit, [string]$Key, [bool]$Dirty, [bool]$HaveCargo, [bool]$Cached, [string]$GitMessage = '')
    $result = [pscustomobject]@{ Action = ''; Notes = @(); Warn = @(); Error = '' }
    if ($Mode -eq 'cargo') {
        $result.Action = 'cargo'
        $result.Notes = @('· $env:DOTFILES_RUNNER が cargo なので、手元で build する (cargo)')
        return $result
    }
    if ((-not $HaveGit) -or (-not (Test-DotfilesRunnerKey -Key $Key))) {
        $why = 'clone の HEAD の win/runner を git で読めない'
        if ($GitMessage) { $why = "$why ($GitMessage)" }
        if (-not $HaveGit) { $why = 'git が見つからない' }
        if (($Mode -eq 'auto') -and $HaveCargo) {
            $result.Action = 'cargo'
            $result.Notes = @("· $why ので、手元で build する (cargo)")
            return $result
        }
        $result.Action = 'error'
        $result.Error = "$why (clone に合う runner の exe を選べない。git は win\bootstrap\Install-Bootstrap.ps1 が入れる)"
        return $result
    }
    if ($Dirty) {
        if (($Mode -eq 'auto') -and $HaveCargo) {
            $result.Action = 'cargo'
            $result.Notes = @('· win/runner に commit していない変更があるので、手元で build する (cargo)')
            return $result
        }
        $why = 'cargo が無い'
        if ($Mode -eq 'exe') { $why = '$env:DOTFILES_RUNNER が exe' }
        $result.Warn = @("⚠ win/runner に commit していない変更があるが、$why ので HEAD の runner の exe で流す (変更は効かない)")
    }
    if ($Cached) { $result.Action = 'cached' } else { $result.Action = 'download' }
    $result
}

# 合う exe を使えないときに止めるか cargo に戻るか。Kind は download (落とせない)・launch (起こせない・version が 0 でなく終わった)・hard
# (sha256・key が合わない・置き場の中身が壊れた)。hard はいつも止まり (差し替えの印を隠さない)、ほかは自動で cargo があれば cargo に戻る
# (起こせないのが %LOCALAPPDATA% の exe を止める決まりなら、clone の中で作った exe は通ることがある)
function Get-DotfilesRunnerFallback {
    param([string]$Mode, [bool]$HaveCargo, [string]$Kind, [string]$Reason, [string]$CacheDir)
    if (($Kind -ne 'hard') -and ($Mode -eq 'auto') -and $HaveCargo) {
        return [pscustomobject]@{
            Action = 'cargo'; Notes = @("· 配った runner の exe を使えない ($Reason) ので、手元で build する (cargo)"); Error = ''; Hints = @()
        }
    }
    $hints = @(Get-DotfilesRunnerHints -CacheDir $CacheDir)
    if ($Kind -eq 'hard') {
        $hints = @(
            '→ 中身が Release の sha256・key と合わない (Release か置き場のファイルが壊れているか、差し替えられている)。置いた物は使わない'
            "→ 置き場 ($CacheDir) を消して打ち直すと落とし直す。手元で build するなら `$env:DOTFILES_RUNNER = 'cargo' (Build Tools と rustup が要る)"
        )
    } elseif ($Kind -eq 'launch') {
        $hints = @("→ 手元で build するなら `$env:DOTFILES_RUNNER = 'cargo' (Build Tools と rustup が要る。Smart App Control に止められているなら、cargo の産物も止められる)")
    }
    [pscustomobject]@{
        Action = 'error'; Notes = @(); Error = "clone の HEAD の win/runner に合う runner の exe を使えない ($Reason)"; Hints = $hints
    }
}

# 合う exe を落とせず、cargo も無い (cargo で作れない) ときの直し方
function Get-DotfilesRunnerHints {
    param([string]$CacheDir)
    @(
        '→ merge の直後なら、CI が exe を作り終えるまで数分待って打ち直す'
        '→ clone が古ければ、dotfiles --self-update で進める (古い key の Release は 30 日で消える)'
        '→ win/runner を変えた commit が手元にあるなら、push して merge するか、win\bootstrap\Install-Bootstrap.ps1 -Rust で Build Tools と rustup を入れる (cargo で build する)'
        "→ github.com に届かない PC は、別の PC で落とした $($script:DotfilesRunnerExeName) と $($script:DotfilesRunnerShaName) を $CacheDir に置く (win/README.md の「runner の exe (Release)」)"
    )
}

# exe を起こせなかったわけ (例外の文と、Win32 の誤りの番号)。4551 は App Control (Smart App Control・WDAC)、1260 はグループ ポリシー (AppLocker・
# ソフトウェアの制限のポリシー) が止めた
function Get-DotfilesRunnerLaunchHint {
    param([string]$Message, [int]$NativeErrorCode)
    if (($NativeErrorCode -eq 4551) -or ($NativeErrorCode -eq 1260) -or ($Message -match 'Application Control|アプリケーション制御|group policy|グループ ポリシー')) {
        return 'Smart App Control か App Control・AppLocker に止められた → Smart App Control は、Windows セキュリティ → アプリとブラウザーの制御 → スマート アプリ コントロールの設定 でオフにする (会社の PC の App Control・AppLocker は管理者に聞く)'
    }
    if (($NativeErrorCode -eq 2) -or ($NativeErrorCode -eq 225)) {
        return "exe が無いか、ウイルス対策に止められた ($Message) → Windows セキュリティの「保護の履歴」を見る"
    }
    $Message
}

# ---------------------------------------------------------------------------
# Windows・git・ネットワークに触る関数 (通しの試験は Invoke-DotfilesRunner.Tests.ps1 (Linux) と CI の .github/scripts/win-runner-e2e.ps1)
# ---------------------------------------------------------------------------

# 1 行を出す。色は、環境変数 NO_COLOR が空のときだけ付ける (runner・Invoke-DotfilesSelfUpdate.ps1 と同じ)
function Write-DotfilesRunnerLine {
    param([string]$Text, [string]$Color = '')
    if ($Color -and -not $env:NO_COLOR) {
        Write-Host $Text -ForegroundColor $Color
    } else {
        Write-Host $Text
    }
}

# PATH にある実行ファイルのパス (無ければ空)
function Find-DotfilesRunnerApplication {
    param([string]$Name)
    $found = @(Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue)
    if ($found.Count -eq 0) { return '' }
    "$($found[0].Path)"
}

# 打つ cargo。名前で引ける (PATH の exe・試験の偽物の関数) なら 'cargo'、無ければ CARGO_HOME\bin・%USERPROFILE%\.cargo\bin の絶対パス、どれも無ければ空
function Find-DotfilesRunnerCargo {
    if (Get-Command -Name 'cargo' -ErrorAction SilentlyContinue) { return 'cargo' }
    $exe = 'cargo'
    if ([IO.Path]::DirectorySeparatorChar -eq '\') { $exe = 'cargo.exe' }
    foreach ($root in @($env:CARGO_HOME, [IO.Path]::Combine($HOME, '.cargo'))) {
        if (-not $root) { continue }
        $p = [IO.Path]::Combine($root, 'bin', $exe)
        if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
    }
    ''
}

# git を clone で打ち、出力の行 (stdout と stderr) と終了コードを返す。git にプロンプトを出させず、index.lock も取らせない (--no-optional-locks。
# 並んで動いている git を止めない)
function Invoke-DotfilesRunnerGit {
    param([string]$Git, [string]$Clone, [string[]]$Arguments)
    $ErrorActionPreference = 'Continue'
    $savedPrompt = $env:GIT_TERMINAL_PROMPT
    $lines = @()
    $code = -1
    try {
        $env:GIT_TERMINAL_PROMPT = '0'
        try {
            $lines = @(& $Git --no-optional-locks -C $Clone @Arguments 2>&1 | ForEach-Object { "$_" })
            $code = $LASTEXITCODE
        } catch {
            $lines = @("$($_.Exception.Message)")
            $code = -1
        }
    } finally {
        $env:GIT_TERMINAL_PROMPT = $savedPrompt
    }
    [pscustomobject]@{ ExitCode = $code; Lines = $lines }
}

# clone の HEAD の win/runner の tree の hash (key)。読めなければ Key は空で、Message に git の出力の 1 行目
function Read-DotfilesRunnerCloneKey {
    param([string]$Git, [string]$Clone)
    $r = Invoke-DotfilesRunnerGit -Git $Git -Clone $Clone -Arguments @('rev-parse', 'HEAD:win/runner')
    $first = @($r.Lines | Where-Object { "$_".Trim() } | Select-Object -First 1)
    $line = ''
    if ($first.Count -gt 0) { $line = "$($first[0])".Trim() }
    if (($r.ExitCode -eq 0) -and (Test-DotfilesRunnerKey -Key $line)) { return [pscustomobject]@{ Key = $line; Message = '' } }
    [pscustomobject]@{ Key = ''; Message = $line }
}

# clone の HEAD の win/runner の tree の hash (key)。読めなければ空
function Get-DotfilesRunnerCloneKey {
    param([string]$Git, [string]$Clone)
    (Read-DotfilesRunnerCloneKey -Git $Git -Clone $Clone).Key
}

# win/runner に commit していない変更 (作業ツリー・index・未追跡のファイル) があるか
function Test-DotfilesRunnerDirty {
    param([string]$Git, [string]$Clone)
    $r = Invoke-DotfilesRunnerGit -Git $Git -Clone $Clone -Arguments @('status', '--porcelain', '--untracked-files=all', '--', 'win/runner')
    if ($r.ExitCode -ne 0) { return $false }
    [bool](@($r.Lines | Where-Object { "$_".Trim() }).Count -gt 0)
}

# ファイルの SHA-256 (小文字の 16 進)。読めなければ空。Get-FileHash は使わない (PowerShell 7 から起こした 5.1 では見つからないことがある)
function Get-DotfilesRunnerFileSha256 {
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
        ''
    } finally {
        $sha.Dispose()
    }
}

# 例外から Win32 の誤りの番号を拾う (InnerException もたどる。無ければ 0)
function Get-DotfilesRunnerNativeErrorCode {
    param($Exception)
    $e = $Exception
    while ($null -ne $e) {
        $p = $e.PSObject.Properties['NativeErrorCode']
        if ($null -ne $p) { return [int]$p.Value }
        $e = $e.InnerException
    }
    0
}

# exe の version を打ち、名乗る key を読む。Error は起こせなかった・0 でなく終わったわけ (どちらも差し替えの印ではない: 止める決まり・DLL が
# 無い (0xC0000135) など)
function Read-DotfilesRunnerVersion {
    param([string]$ExePath)
    $ErrorActionPreference = 'Continue'
    try {
        $lines = @(& $ExePath 'version' 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
    } catch {
        $hint = Get-DotfilesRunnerLaunchHint -Message $_.Exception.Message -NativeErrorCode (Get-DotfilesRunnerNativeErrorCode -Exception $_.Exception)
        return [pscustomobject]@{ Key = ''; Error = "exe を起こせない: $hint" }
    }
    if ($code -ne 0) {
        return [pscustomobject]@{ Key = ''; Error = ('exe の version が終了コード {0} (0x{0:X8}) で終わった (DLL が無い・exe が壊れているなど)' -f $code) }
    }
    $keyLine = @($lines | Where-Object { $_ -like 'key=*' } | Select-Object -First 1)
    $key = ''
    if ($keyLine.Count -gt 0) { $key = "$($keyLine[0])".Substring(4).Trim() }
    [pscustomobject]@{ Key = $key; Error = '' }
}

# 置き場の key のディレクトリの様子。State は none (exe か .sha256 が無い)・ok (sha256 が合い、key を確かめた印がこの exe のもの)・unverified
# (sha256 は合うが、まだ key を確かめていない。落とした直後・手で置いたもの)・bad (sha256 が合わない・.sha256 が読めない)。ExeSha は exe の sha256
function Test-DotfilesRunnerCached {
    param([string]$Dir)
    $exe = Join-Path $Dir $script:DotfilesRunnerExeName
    $shaFile = Join-Path $Dir $script:DotfilesRunnerShaName
    $result = [pscustomobject]@{ State = 'none'; ExeSha = '' }
    if (-not ((Test-Path -LiteralPath $exe -PathType Leaf) -and (Test-Path -LiteralPath $shaFile -PathType Leaf))) { return $result }
    $result.ExeSha = Get-DotfilesRunnerFileSha256 -Path $exe
    $expected = ConvertFrom-DotfilesRunnerSha256 -Text ([IO.File]::ReadAllText($shaFile))
    if ((-not $expected) -or ($result.ExeSha -cne $expected)) {
        $result.State = 'bad'
        return $result
    }
    $mark = Join-Path $Dir $script:DotfilesRunnerMarkName
    $result.State = 'unverified'
    if (Test-Path -LiteralPath $mark -PathType Leaf) {
        # 印の頭は、確かめた exe の sha256 (exe を替えたら確かめ直す)
        $marked = @(([IO.File]::ReadAllText($mark)).Trim() -split '\s+')[0]
        if ($marked -ceq $result.ExeSha) { $result.State = 'ok' }
    }
    $result
}

# URL の中身を OutFile に落とす。落とせなければ例外
function Invoke-DotfilesRunnerDownload {
    param([string]$Url, [string]$OutFile, [int]$TimeoutSec)
    # 進み具合の表示は Windows PowerShell 5.1 で落とすのを大きく遅くする
    $ProgressPreference = 'SilentlyContinue'
    # 5.1 (.NET Framework) は既定で TLS 1.2 を使わないことがあり、GitHub に断られる
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
    # -UseBasicParsing は 5.1 の KB5074596 からの確かめを出させないため (7 では何もしない)
    Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop
}

# 落とせなかったわけ (HTTP の状態の番号があれば添える)
function Get-DotfilesRunnerDownloadReason {
    param($ErrorRecord)
    $status = 0
    try {
        $p = $ErrorRecord.Exception.PSObject.Properties['Response']
        if (($null -ne $p) -and ($null -ne $p.Value)) { $status = [int]$p.Value.StatusCode }
    } catch {
        $status = 0
    }
    if ($status -eq 404) { return 'Release が無い (HTTP 404)' }
    if ($status -gt 0) { return "落とせない (HTTP $status)" }
    "落とせない ($($ErrorRecord.Exception.Message))"
}

# key の Release から exe と .sha256 を置き場に落とし、sha256 が合うときだけ置く (置き場に片方だけ残っていた物は、落とした物で置き換える)。
# 結果は Ok・Kind (落とせない・置けないは download、.sha256 が読めない・sha256 が合わないは hard)・Reason
function Install-DotfilesRunnerExe {
    param([string]$Dir, [string]$Key, [string]$BaseUrl)
    $null = New-Item -ItemType Directory -Force -Path $Dir
    # 止められた実行 (Ctrl+C など) が残した途中の物は、10 分より古ければ消す
    foreach ($old in @(Get-ChildItem -LiteralPath $Dir -File -Filter '*.download-*' -ErrorAction SilentlyContinue)) {
        if ($old.LastWriteTime -lt (Get-Date).AddMinutes(-10)) { Remove-Item -LiteralPath $old.FullName -Force -ErrorAction SilentlyContinue }
    }
    $exe = Join-Path $Dir $script:DotfilesRunnerExeName
    $shaFile = Join-Path $Dir $script:DotfilesRunnerShaName
    $tmpExe = "$exe.download-$PID"
    $tmpSha = "$shaFile.download-$PID"
    $result = [pscustomobject]@{ Ok = $false; Kind = 'download'; Reason = '' }
    try {
        try {
            # .sha256 は小さいので、届かないネットワークで長く待たないよう短く切る
            Invoke-DotfilesRunnerDownload -Url (Get-DotfilesRunnerUrl -BaseUrl $BaseUrl -Key $Key -Name $script:DotfilesRunnerShaName) -OutFile $tmpSha -TimeoutSec 20
            Invoke-DotfilesRunnerDownload -Url (Get-DotfilesRunnerUrl -BaseUrl $BaseUrl -Key $Key -Name $script:DotfilesRunnerExeName) -OutFile $tmpExe -TimeoutSec 300
        } catch {
            $result.Reason = Get-DotfilesRunnerDownloadReason -ErrorRecord $_
            return $result
        }
        $expected = ConvertFrom-DotfilesRunnerSha256 -Text ([IO.File]::ReadAllText($tmpSha))
        if (-not $expected) {
            $result.Kind = 'hard'
            $result.Reason = "Release の $($script:DotfilesRunnerShaName) が読めない"
            return $result
        }
        $actual = Get-DotfilesRunnerFileSha256 -Path $tmpExe
        if ($actual -cne $expected) {
            $result.Kind = 'hard'
            $result.Reason = "落とした exe の sha256 ($actual) が Release の値 ($expected) と合わない (落とした物は消した)"
            return $result
        }
        # Invoke-WebRequest は Mark of the Web を付けないが、手で置いた物と同じ扱いにそろえる (sha256 は確かめた)。Unblock-File は Windows だけ
        # (Linux の pwsh にもあるが、-ErrorAction を付けても例外で止まる)
        if ([IO.Path]::DirectorySeparatorChar -eq '\') {
            try { Unblock-File -LiteralPath $tmpExe -ErrorAction Stop } catch { }
        }
        # 置き場に片方だけ残っていた物 (手で exe だけを置いた・消しかけて止まった) は、確かめた物で置き換える。動いていて置き換えられなければ止まる
        foreach ($pair in @(@($tmpExe, $exe), @($tmpSha, $shaFile))) {
            try {
                if (Test-Path -LiteralPath $pair[1]) { Remove-Item -LiteralPath $pair[1] -Force -ErrorAction Stop }
                Move-Item -LiteralPath $pair[0] -Destination $pair[1] -ErrorAction Stop
            } catch {
                $result.Reason = "置き場の $(Split-Path -Leaf $pair[1]) を置き換えられない (動いている exe など。$($_.Exception.Message))"
                return $result
            }
        }
        $result.Ok = $true
        $result
    } finally {
        foreach ($t in @($tmpExe, $tmpSha)) {
            if (Test-Path -LiteralPath $t) { Remove-Item -LiteralPath $t -Force -ErrorAction SilentlyContinue }
        }
    }
}

# 置き場の exe が名乗る key を確かめ、合えば印 (この exe の sha256 と key) を置く。結果は Ok・Kind (起こせない・0 でなく終わったは launch、
# key が合わないは hard)・Reason
function Confirm-DotfilesRunnerExe {
    param([string]$Dir, [string]$Key, [string]$ExeSha)
    $v = Read-DotfilesRunnerVersion -ExePath (Join-Path $Dir $script:DotfilesRunnerExeName)
    if ($v.Error) { return [pscustomobject]@{ Ok = $false; Kind = 'launch'; Reason = $v.Error } }
    if ($v.Key -cne $Key) {
        return [pscustomobject]@{ Ok = $false; Kind = 'hard'; Reason = "exe が名乗る key ($($v.Key)) が clone の key と合わない" }
    }
    Set-Content -LiteralPath (Join-Path $Dir $script:DotfilesRunnerMarkName) -Value "$ExeSha $Key $((Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz'))" -Encoding ascii
    [pscustomobject]@{ Ok = $true; Kind = ''; Reason = '' }
}

# 置き場の古い key のディレクトリを消す (動いていて消せないものは次に回す)
function Remove-DotfilesRunnerStaleDirs {
    param([string]$Root, [string]$Current)
    $dirs = @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue)
    foreach ($name in @(Select-DotfilesRunnerStaleDirs -Dirs $dirs -Current $Current -Keep $script:DotfilesRunnerKeep)) {
        Remove-Item -LiteralPath (Join-Path $Root $name) -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# 止めるときの行を出す
function Write-DotfilesRunnerError {
    param([string]$Text, [string[]]$Hints)
    Write-DotfilesRunnerLine "!! $Text" 'Red'
    foreach ($h in @($Hints)) { Write-DotfilesRunnerLine "  $h" }
}

# 何で runner を起こすかを決める (落とすのもここ)。Kind は exe (Exe にパス)・cargo (Cargo に打つもの。Fallback は配った exe を使えずに cargo へ
# 回ったか)・error。runner は呼び出し元 (末尾) が起こす: ここで起こすと、この関数の戻り値を受けるために PowerShell が runner の出力をパイプで受け、
# runner が端末を見られない
function Resolve-DotfilesRunner {
    param([string]$Clone, [string[]]$Arguments)
    $plan = [pscustomobject]@{ Kind = 'error'; Exe = ''; Cargo = ''; Fallback = $false; CacheDir = '' }
    $runnerDir = [IO.Path]::Combine($Clone, 'win', 'runner')
    if (-not (Test-Path -LiteralPath (Join-Path $runnerDir 'Cargo.toml') -PathType Leaf)) {
        Write-DotfilesRunnerLine "dotfiles の runner がありません: $runnerDir (先に win\bootstrap\Install-Bootstrap.ps1 で clone する)" 'Yellow'
        return $plan
    }
    $mode = Get-DotfilesRunnerMode -Value "$env:DOTFILES_RUNNER"
    if ($null -eq $mode) {
        Write-DotfilesRunnerError "環境変数 DOTFILES_RUNNER の値が分からない: '$env:DOTFILES_RUNNER' (空・exe・cargo のどれか)" @()
        return $plan
    }
    $cargo = Find-DotfilesRunnerCargo
    $git = Find-DotfilesRunnerApplication -Name 'git'
    $key = ''
    $gitMessage = ''
    $dirty = $false
    if (($mode -ne 'cargo') -and $git) {
        $read = Read-DotfilesRunnerCloneKey -Git $git -Clone $Clone
        $key = $read.Key
        $gitMessage = $read.Message
        if ($key) { $dirty = Test-DotfilesRunnerDirty -Git $git -Clone $Clone }
    }
    $dir = ''
    $plan.CacheDir = '%LOCALAPPDATA%\dotfiles\runner\<key>'
    $cached = [pscustomobject]@{ State = 'none'; ExeSha = '' }
    if ($key) {
        if (-not $env:LOCALAPPDATA) {
            Write-DotfilesRunnerError '環境変数 LOCALAPPDATA がありません (runner の exe の置き場を決められない)' @()
            return $plan
        }
        $dir = Get-DotfilesRunnerCacheDir -LocalAppData $env:LOCALAPPDATA -Key $key
        $plan.CacheDir = $dir
        $cached = Test-DotfilesRunnerCached -Dir $dir
    }
    $decision = Get-DotfilesRunnerDecision -Mode $mode -HaveGit ([bool]$git) -Key $key -Dirty $dirty -HaveCargo ([bool]$cargo) -Cached (($cached.State -eq 'ok') -or ($cached.State -eq 'unverified')) -GitMessage $gitMessage
    if (($decision.Action -eq 'cargo') -and (-not $cargo)) {
        Write-DotfilesRunnerError 'cargo が見つからない ($env:DOTFILES_RUNNER が cargo。win\bootstrap\Install-Bootstrap.ps1 -Rust で Build Tools と rustup を入れる)' @()
        return $plan
    }
    foreach ($n in @($decision.Notes)) { Write-DotfilesRunnerLine $n }
    foreach ($w in @($decision.Warn)) { Write-DotfilesRunnerLine $w 'Yellow' }
    if ($decision.Action -eq 'error') {
        Write-DotfilesRunnerError $decision.Error @()
        return $plan
    }
    if ($decision.Action -eq 'cargo') {
        $plan.Kind = 'cargo'
        $plan.Cargo = $cargo
        # 変更があって build するのも、配った exe を使えずに cargo へ回るのと同じく、build できないことがある (Build Tools が無いなど)。
        # 明示の cargo のモードは除く
        $plan.Fallback = ($mode -ne 'cargo')
        return $plan
    }
    $fallback = $null
    if ($cached.State -eq 'bad') {
        $fallback = Get-DotfilesRunnerFallback -Mode $mode -HaveCargo ([bool]$cargo) -Kind 'hard' -Reason "置き場の $($script:DotfilesRunnerExeName) が $($script:DotfilesRunnerShaName) と合わない" -CacheDir $dir
    }
    if (($null -eq $fallback) -and ($decision.Action -eq 'download')) {
        $baseUrl = $script:DotfilesRunnerBaseUrl
        if ($env:DOTFILES_RUNNER_BASE_URL) { $baseUrl = "$env:DOTFILES_RUNNER_BASE_URL" }
        Write-DotfilesRunnerLine "==> runner の exe を落とす: $(Get-DotfilesRunnerTag -Key $key) ($baseUrl)"
        $r = Install-DotfilesRunnerExe -Dir $dir -Key $key -BaseUrl $baseUrl
        if ($r.Ok) {
            # 置いた物を読み直す (落とした物の sha256 は確かめた。印はまだ無いので unverified)
            $cached = Test-DotfilesRunnerCached -Dir $dir
            if ($cached.State -eq 'bad') {
                $fallback = Get-DotfilesRunnerFallback -Mode $mode -HaveCargo ([bool]$cargo) -Kind 'hard' -Reason "置いた $($script:DotfilesRunnerExeName) が $($script:DotfilesRunnerShaName) と合わない" -CacheDir $dir
            }
        } else {
            $fallback = Get-DotfilesRunnerFallback -Mode $mode -HaveCargo ([bool]$cargo) -Kind $r.Kind -Reason $r.Reason -CacheDir $dir
        }
    }
    if (($null -eq $fallback) -and ($cached.State -eq 'unverified')) {
        # 落とした直後と、手で置いた物は、使う前に 1 回だけ version で key を確かめる (起こせなければ、ここで Smart App Control などが分かる)
        $c = Confirm-DotfilesRunnerExe -Dir $dir -Key $key -ExeSha $cached.ExeSha
        if (-not $c.Ok) { $fallback = Get-DotfilesRunnerFallback -Mode $mode -HaveCargo ([bool]$cargo) -Kind $c.Kind -Reason $c.Reason -CacheDir $dir }
    }
    if ($null -ne $fallback) {
        foreach ($n in @($fallback.Notes)) { Write-DotfilesRunnerLine $n }
        if ($fallback.Action -eq 'cargo') {
            $plan.Kind = 'cargo'
            $plan.Cargo = $cargo
            $plan.Fallback = $true
            return $plan
        }
        Write-DotfilesRunnerError $fallback.Error $fallback.Hints
        return $plan
    }
    Remove-DotfilesRunnerStaleDirs -Root (Split-Path -Parent $dir) -Current $key
    $plan.Kind = 'exe'
    $plan.Exe = Join-Path $dir $script:DotfilesRunnerExeName
    $plan
}

# dot-source されたとき (テスト) は関数だけを読み、本体は走らせない。
# runner はここ (script の上の段) で起こす (Resolve-DotfilesRunner の注意)。思わぬ例外は受け止めて終了コード 2 で終える。Ctrl+C で止めると catch を
# 通らずに finally だけが流れるので、止めたことを出して終了コード 1 で終える (今いる場所は下の finally が戻す)
if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    # 外のコマンド (git・cargo・runner) の終了コードは自分で読む (pwsh 7.4 からの $PSNativeCommandUseErrorActionPreference を profile で $true に
    # していても、0 でない終了コードを例外にしない。5.1 には無い変数で、置いても何も起きない)
    $PSNativeCommandUseErrorActionPreference = $false
    Set-StrictMode -Version Latest
    $exitCode = $null
    try {
        $all = @($args | ForEach-Object { "$_" })
        if (($all.Count -lt 1) -or (-not $all[0])) {
            Write-DotfilesRunnerLine '!! 使い方: Invoke-DotfilesRunner.ps1 <clone> [<runner の引数>…]' 'Red'
            $exitCode = 2
        } else {
            $clone = $all[0]
            $runnerArgs = @()
            if ($all.Count -gt 1) { $runnerArgs = @($all[1..($all.Count - 1)]) }
            $plan = Resolve-DotfilesRunner -Clone $clone -Arguments $runnerArgs
            if ($plan.Kind -eq 'exe') {
                $exeArgs = @(Get-DotfilesRunnerArgs -Clone $clone -Arguments $runnerArgs)
                try {
                    & $plan.Exe @exeArgs
                    $exitCode = $LASTEXITCODE
                } catch {
                    $hint = Get-DotfilesRunnerLaunchHint -Message $_.Exception.Message -NativeErrorCode (Get-DotfilesRunnerNativeErrorCode -Exception $_.Exception)
                    Write-DotfilesRunnerLine "!! runner の exe を起こせない: $hint" 'Red'
                    $exitCode = 2
                }
            } elseif ($plan.Kind -eq 'cargo') {
                # cargo は win\runner に入ってから打つ (rustup は rust-toolchain.toml を今のディレクトリから探す)。'--' は引用符で囲む (素の -- は
                # PowerShell が引数の終わりの印として読み、版や呼び先によっては cargo に届かない)
                Push-Location -LiteralPath ([IO.Path]::Combine($clone, 'win', 'runner'))
                try {
                    & $plan.Cargo run --quiet --release --locked '--' @runnerArgs
                    $exitCode = $LASTEXITCODE
                } finally {
                    Pop-Location
                }
                # cargo が自分で落ちたとき (101。build できない (Build Tools が無いなど)。runner の panic も 101) に、配った exe を使えずに cargo へ
                # 回ったのなら、合う exe を得る直し方を出す (runner の終了コードは 0〜3)
                if (($exitCode -eq 101) -and $plan.Fallback) {
                    Write-DotfilesRunnerError 'cargo が終了コード 101 で終わった (build できない (Build Tools が無いなど) か、runner が panic した)' (Get-DotfilesRunnerHints -CacheDir $plan.CacheDir)
                }
            } else {
                $exitCode = 2
            }
        }
    } catch {
        Write-Host "エラーで止まった: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace
        $exitCode = 2
    } finally {
        if ($null -eq $exitCode) {
            Write-Host ''
            Write-Host '⚠️ 途中で止めた (Ctrl+C) ⚠️' -ForegroundColor Yellow
            exit 1
        }
    }
    exit $exitCode
}
