<#
.SYNOPSIS
Win32-OpenSSH (winget の Microsoft.OpenSSH.Preview) を、決めた版に揃える。

.DESCRIPTION
dotfiles の win/openssh/Install-OpenSSH.ps1 を %USERPROFILE%\.config\powershell\ へ配り、
PowerShell では dotfiles.ps1 の Install-OpenSSH から呼ぶ (win/README.md の「OpenSSH」)。

MSI の更新は ssh-agent サービスを「自動・実行中」で作り直し、1Password の SSH agent と
\\.\pipe\openssh-ssh-agent を取り合う (Win32-OpenSSH の issue #2057)。揃えた後に
ssh-agent を停止・無効へ戻し、winget pin で winget upgrade --all から外す。固定した版へ上げる
winget upgrade には --include-pinned を付けて、その pin を越える (付けないと pin に止められる)。

sshd (MSI の Server の機能) は入れない (ADDLOCAL=Client)。ただし Install-Sshd.ps1 が Server を足したマシン (sshd.exe がある) では、
上げる・下げるときも ADDLOCAL=Client,Server にして Server を残す (ADDLOCAL を渡すと MSI は前の版の機能を引き継がないので、
Client だけで上げると sshd が消える)。上げ直した MSI は 22 番の受信の許可を有効に戻すので、続けて Install-Sshd で揃える。

管理者が要るのは winget と ssh-agent を直す段だけで、そのときだけ UAC で自分を
起動し直す。-Check は何も変えない。起動し直す host は今の pwsh だが、今の pwsh が MSIX (WindowsApps の下) なら MSI の pwsh を使い、MSI の
pwsh も無く普段のアカウントが管理者でなければ、UAC を出さずに止める (管理者でない PC は UAC で別の管理者のアカウントに昇格し、その側では
使う人ごとに登録される MSIX の pwsh を起こせない。bootstrap を流し直すと MSI が入る)。昇格した側で winget が見つからない (そのアカウントに
App Installer が登録されていない) ときは、わけと登録の手を書いて止まる (登録はしない)。

BOM 付きの UTF-8 で保存すること (Windows PowerShell 5.1 は BOM の無い UTF-8 を CP932 として読む)。

.PARAMETER Version
固定する版。winget show --id Microsoft.OpenSSH.Preview --versions に出る値。版を変えるときはここの既定値を変える。

.PARAMETER Check
今の状態と固定した版との差を出すだけで、何も変えない。揃っていれば終了コード 0、入っていなければ 3、ほかの差があれば 1。

.PARAMETER IfMissing
入っていなければ固定した版を入れ (UAC が 1 回出る)、ssh-agent を止めて無効にし、winget pin を足す。入っていれば -Check と
同じ (何も変えない)。新しい PC で setup (bootstrap-windows-openssh.sh) が呼ぶ。入れたあとの成否は版・ssh-agent・pin で決め、
1Password の鍵が ssh-add -l で見えるかは数えない (新しい PC では 1Password をまだ入れていない)。

.PARAMETER Force
ssh.exe などが動いていても入れ替える (使用中のファイルは再起動まで置き換わらないことがある)。

.PARAMETER NoOnePassword
1Password の SSH agent を使わないホストで付ける (dotfiles の runner は、ホストの値の道具の switch onePassword が off なら、手順 openssh で渡す)。
入れた・揃えた後に ssh-add -l で 1Password の鍵を見ず、1Password の案内も出さない。引数なしで揃えたときの「揃った」も、鍵が見えるかで決めない。

.PARAMETER LogPath
内部用。管理者で起動し直した子が、結果をこのファイルへ書いて親へ渡す。
#>
[CmdletBinding()]
param(
    [string]$Version = '10.4.0.0',
    [switch]$Check,
    [switch]$IfMissing,
    [switch]$Force,
    [switch]$NoOnePassword,
    [string]$LogPath
)

# ---------------------------------------------------------------------------
# 副作用の無い関数 (Install-OpenSSH.Tests.ps1 で確かめる)
# ---------------------------------------------------------------------------

# 入っている版 (無ければ $null) と固定した版から、することを決める
function Get-OpenSshPlan {
    param([version]$Installed, [version]$Target)
    if ($null -eq $Installed) { return 'install' }
    if ($Installed -lt $Target) { return 'upgrade' }
    if ($Installed -gt $Target) { return 'downgrade' }
    'none'
}

# winget show --versions の出力から、最新版 (版だけの行の先頭) を拾う。無ければ $null
function Get-WingetLatestVersion {
    param([string[]]$Lines)
    foreach ($line in $Lines) {
        if ($line -match '^\s*(\d+(\.\d+){1,3})\s*$') { return [version]$Matches[1] }
    }
    $null
}

# winget pin list の出力に、その Id を列に持つ行があるか。
# 見出しや「pin が無い」の文言は表示言語で変わるので、Id の一致だけを見る
function Test-WingetPinned {
    param([string[]]$Lines, [string]$PackageId)
    foreach ($line in $Lines) {
        if (($line -split '\s+') -ccontains $PackageId) { return $true }
    }
    $false
}

# plan ごとに打つ winget の引数 (配列の配列)。下げるときは、新しい版が入っていると
# MSI が止める (LaunchCondition) ので、先に外してから入れる。
# 上げる upgrade には --include-pinned を付ける。版を名指しした upgrade は、付けないとこの script が足した pin (Pinning) に
# 止められる (0x8A150068。2026-11-16 に example-host で 10.4.0.0 へ上げるときに落ちた)。install と uninstall は --include-pinned を
# 受け付けないので付けない (下げるときの install は、uninstall で入っていない形にしてからなので pin を見ない)
function Get-WingetCommands {
    param([string]$Plan, [string]$PackageId, [string]$Version, [switch]$Server)
    $common = @('--id', $PackageId, '--exact', '--source', 'winget', '--silent',
        '--accept-source-agreements', '--disable-interactivity')
    # ADDLOCAL=Client で sshd を入れない (ssh-agent はクライアント側の部品でもあるので入る)。Install-Sshd.ps1 が Server を足した
    # マシン (-Server) では Client,Server にして残す (ADDLOCAL を渡すと MSI は前の版の機能を引き継がず、Client だけだと sshd が消える)
    $features = if ($Server) { 'ADDLOCAL=Client,Server' } else { 'ADDLOCAL=Client' }
    $put = $common + @('--version', $Version, '--custom', $features, '--accept-package-agreements')
    switch ($Plan) {
        'install' { , (@('install') + $put) }
        'upgrade' { , (@('upgrade') + $put + @('--include-pinned')) }
        'downgrade' {
            , (@('uninstall') + $common)
            , (@('install') + $put)
        }
    }
}

# winget が pin に止められて落ちた (0x8A150068 = APPINSTALLER_CLI_ERROR_PACKAGE_IS_PINNED) ときに添える行。ほかの終了コードなら
# 何も返さない。この script が足す pin (Pinning) は upgrade の --include-pinned で越えるので、出るのは pin を Blocking・Gating に
# 替えたときか、入っていると winget が見ているのに install を打ったとき (install は --include-pinned を受け付けない)
function Get-WingetPinnedHint {
    param([int]$ExitCode, [string]$PackageId)
    if ($ExitCode -ne -1978335128) { return }
    "※ winget の pin に止められた。winget pin list --id $PackageId --exact で pin を確かめ、winget pin remove --id $PackageId --exact で外してから打ち直す (打ち直すと、揃えた後に pin を足し直す)"
}

# ssh-agent が停止・無効か。サービスが無ければ 1Password とぶつからないので問題なし
function Test-SshAgentDisabled {
    param($Status, $StartType)
    if ($null -eq $Status) { return $true }
    ("$Status" -eq 'Stopped') -and ("$StartType" -eq 'Disabled')
}

# 状態の表の行 (Text と、直すことがあるかの Warn)。直すことがある行だけ先頭に ⚠ を付け、
# ほかは 2 字下げる。winget に新しい版があるのはずれではないので、⚠ ではなく ※ で知らせる
function Format-OpenSshState {
    param($State, [version]$Target, [string]$InstallDir)
    $planText = @{ install = '入れる'; upgrade = '上げる'; downgrade = '下げる (外してから入れる)'; none = 'そのまま' }[$State.Plan]
    $installedText = if ($State.Installed) { "$($State.Installed)" } else { '入っていない' }
    $latestText = if ($State.Latest) { "$($State.Latest)" } else { '不明 (winget show が失敗)' }
    $agentText = if ($null -eq $State.AgentStatus) { 'サービス無し' } else { "$($State.AgentStatus) / $($State.AgentStartType)" }
    $agentTo = if ($State.AgentDisabled) { 'そのまま' } else { '停止・無効にする' }
    $pinText = if ($State.Pinned) { 'あり' } else { '無し → 足す' }
    $rows = @(
        @{ Text = "OpenSSH (winget の Microsoft.OpenSSH.Preview、$InstallDir)"; Warn = $false; Indent = $false }
        @{ Text = "入っている版    : $installedText"; Warn = $false; Indent = $true }
        @{ Text = "固定した版      : $Target → $planText"; Warn = ($State.Plan -ne 'none'); Indent = $true }
        @{ Text = "winget の最新版 : $latestText"; Warn = $false; Indent = $true }
        @{ Text = "ssh-agent       : $agentText → $agentTo"; Warn = (-not $State.AgentDisabled); Indent = $true }
        @{ Text = "winget pin      : $pinText"; Warn = (-not $State.Pinned); Indent = $true }
    )
    foreach ($row in $rows) {
        $prefix = if (-not $row.Indent) { '' } elseif ($row.Warn) { '⚠ ' } else { '  ' }
        [pscustomobject]@{ Text = "$prefix$($row.Text)"; Warn = [bool]$row.Warn }
    }
    if ($State.Latest -and $State.Latest -gt $Target) {
        [pscustomobject]@{ Text = "※ winget に固定した版より新しい $($State.Latest) がある。上げるなら Install-OpenSSH.ps1 の -Version の既定値を変える"; Warn = $false }
    }
    if ($State.Inbox) {
        [pscustomobject]@{ Text = '※ Windows の機能の OpenSSH (System32\OpenSSH) も入っている。PATH では Program Files が先なので使われないが、ssh-agent サービスの名前がぶつかる'; Warn = $false }
    }
    if ($State.Server -and ($State.Plan -ne 'none')) {
        [pscustomobject]@{ Text = '※ sshd (Server の機能) も入っている。上げる・下げるときは Server も一緒に入れ直し、終わったら Install-Sshd で揃える (MSI が 22 番の受信の許可を有効に戻す)'; Warn = $false }
    }
}

# -Check の終了コード。入っていなければ 3、版・ssh-agent・pin が揃っていれば 0、ほかは 1
# (Install-GoogleJapaneseInput.ps1 の Get-GoogleImeExitCode と同じ形)
function Get-OpenSshExitCode {
    param($State)
    if ($State.Plan -eq 'install') { return 3 }
    if (($State.Plan -eq 'none') -and $State.AgentDisabled -and $State.Pinned) { return 0 }
    1
}

# 動いている ssh.exe などを見てから進むか。置き換えるファイルがあるとき (上げる・下げる) だけ見る。入れるときは
# 置き換えるファイルが無い (Windows の機能の OpenSSH (System32\OpenSSH) の ssh.exe が動いていても入れられる)
function Test-OpenSshNeedsIdle {
    param([string]$Plan)
    @('upgrade', 'downgrade') -contains $Plan
}

# -Check の締めの 1 行。揃っていれば「揃っている」、ほかは ⚠️ で囲んで直し方を出す
function Get-OpenSshCheckMessage {
    param($State)
    switch (Get-OpenSshExitCode -State $State) {
        0 { '揃っている' }
        3 { '⚠️ OpenSSH が入っていない → Install-OpenSSH -IfMissing で入れる (UAC が 1 回出る) ⚠️' }
        default { '⚠️ 固定した版と揃っていない → Install-OpenSSH で揃える (差があれば UAC が 1 回出る) ⚠️' }
    }
}

# -IfMissing で入れたあとの締めの 1 行 ($Code は Get-OpenSshExitCode)。入れ直しも -IfMissing で打たせる
# (付けないで打つと、入れたあと 1Password の鍵が見えないのを失敗と数える。新しい PC ではまだ 1Password が無い)
function Get-OpenSshIfMissingMessage {
    param([int]$Code)
    if ($Code -eq 0) { return '入れた' }
    '入れられなかった。上の出力を確かめ、Install-OpenSSH -IfMissing を打ち直す (UAC で「いいえ」を押したなら、打ち直して「はい」を押す)'
}

# 入れた・揃えた後に出す ssh-add -l の行 ($Keys は見えた鍵の本数。見えなければ $null)。1Password の SSH agent を使わないホスト
# (-NoOnePassword) は何も返さない (鍵を見ず、1Password の案内も出さない)。見えないときは、入れたばかり (-IfMissing。新しい PC ではまだ
# 1Password が無い) なら SSH agent を有効にした後の確かめ方、それ以外は 1Password を起動し直す手
function Format-AgentKeyLine {
    param($Keys, [switch]$IfMissing, [switch]$NoOnePassword)
    if ($NoOnePassword) { return }
    if ($null -ne $Keys) { return "  ssh-add -l      : 鍵 $Keys 本" }
    if ($IfMissing) { return '  ssh-add -l      : 鍵が見えない → 1Password の SSH agent を有効にしたら、Install-OpenSSH -Check で確かめる' }
    '  ssh-add -l      : 鍵が見えない → 1Password をトレイから終了して起動し直し、もう一度 -Check で確かめる'
}

# 引数なしで揃えた後に「揃った」とするか: 版・ssh-agent・pin が揃い、1Password の鍵が見える ($Keys が $null でない)。1Password の SSH agent を
# 使わないホスト (-NoOnePassword) は鍵を数えない
function Test-OpenSshSynced {
    param($State, $Keys, [switch]$NoOnePassword)
    ($State.Plan -eq 'none') -and $State.AgentDisabled -and $State.Pinned -and ($NoOnePassword -or ($null -ne $Keys))
}

# トークンのグループの SID (Install-Bootstrap.ps1 と同じ)。WindowsIdentity の Claims のうち、種類が有効なグループ (groupsid) か deny-only の
# グループ (denyonlysid) のものの値。種類の名前空間は種類ごとに違うので、最後の語で見る。WindowsIdentity.Groups は deny-only のグループを除く
# (UAC で権限を落とした管理者の BUILTIN\Administrators が入らない) ので使わない
function Select-TokenGroupSids {
    param([object[]]$Claims)
    foreach ($claim in @($Claims | Where-Object { $null -ne $_ })) {
        if ("$($claim.Type)" -match '/(groupsid|denyonlysid)$') { "$($claim.Value)" }
    }
}

# 普段のアカウントが管理者か (Install-Bootstrap.ps1 と同じ)。トークンのグループの SID の並びに BUILTIN\Administrators (S-1-5-32-544) があれば
# 管理者 (UAC で権限を落とした管理者のトークンでも deny-only のグループで入る)
function Test-AdministratorsSid {
    param([string[]]$Sids)
    @($Sids) -contains 'S-1-5-32-544'
}

# 自分を管理者で起動し直すときの host。今の pwsh が MSIX (WindowsApps の下) なら、MSI の pwsh があればそれを使う (MSIX は使う人ごとに登録
# されるので、UAC で別の管理者のアカウントの資格情報を入れると、昇格した側で起こせない)。MSI の pwsh が無く、普段のアカウントが管理者でなければ
# 空を返す (UAC を出さずに止める。管理者でない PC は UAC で別の管理者のアカウントに昇格する)。ほか (管理者の PC の MSIX・MSI・
# Windows PowerShell 5.1・ほかの pwsh) は今の host
function Select-ElevationHost {
    param([string]$CurrentHost, [string]$MsiPwsh, [bool]$MsiPwshExists, [bool]$AccountAdmin)
    if ("$CurrentHost" -notmatch '\\WindowsApps\\') { return $CurrentHost }
    if ($MsiPwshExists) { return $MsiPwsh }
    if ($AccountAdmin) { return $CurrentHost }
    ''
}

# 昇格し直さずに止めるとき (Select-ElevationHost が空) の行。管理者でない PC には、bootstrap が MSI の PowerShell 7 を入れる
function Format-ElevationStopNote {
    param([string]$CurrentHost, [string]$MsiPwsh)
    "UAC は出さずに止めた (この pwsh は MSIX: $CurrentHost)"
    "※ 普段のアカウントが管理者でない PC では、UAC で別の管理者のアカウントの資格情報を入れて昇格する。MSIX の PowerShell 7 は使う人ごとに登録されるので、昇格した側 (そのアカウント) では起こせない。MSI の PowerShell 7 ($MsiPwsh) も無い。bootstrap (dotfiles の clone の win\bootstrap\Install-Bootstrap.ps1) を普通の PowerShell で流し直すと、管理者でない PC には MSI の PowerShell 7 が入る (UAC で管理者の資格情報を入れる。bootstrap を流さない PC は、win/README.md の「PowerShell 7 の MSIX の限り」の winget のコマンドで MSI を足す)。入ったら、新しい窓で打ち直す"
}

# 管理者で起動し直した側で winget が見つからないときの行。UAC で別の管理者のアカウントの資格情報を入れて昇格すると、そのアカウントには
# App Installer (winget) が登録されていないことがある (winget は Windows にサインインしたときに使う人ごとに登録される。その PC に一度も
# サインインしていないアカウントには無い)。登録はこちらではしない (別のアカウントの状態を変えるため)。手は Microsoft の winget の文書
# (https://learn.microsoft.com/windows/package-manager/winget/) のもの
function Format-WingetMissingNote {
    param([string]$Account)
    "winget が見つからない (昇格した側のアカウント: $Account)"
    '※ UAC で別の管理者のアカウントの資格情報を入れたなら、そのアカウントには winget (App Installer) が登録されていないことがある (winget は Windows にサインインしたときに使う人ごとに登録され、この PC に一度もサインインしていないアカウントには無い)。そのアカウントでこの PC に一度サインインするか、そのアカウントの管理者の PowerShell (Windows PowerShell を「管理者として実行」で開き、UAC でそのアカウントの資格情報を入れる) で Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe を打ってから、流し直す。普段のアカウントのまま昇格したなら、Microsoft Store の「アプリ インストーラー」を入れる (更新する)'
}

# ---------------------------------------------------------------------------
# Windows に触る関数 (実機で -Check と本番を打って確かめる)
# ---------------------------------------------------------------------------

# 画面に出す。管理者で起動し直した子では、親が読めるようにファイルへも書く
function Write-Step {
    param([string]$Message)
    Write-Host $Message
    if ($script:StepLog) { Add-Content -LiteralPath $script:StepLog -Value $Message -Encoding utf8 }
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# 普段のアカウントが管理者か (Install-Bootstrap.ps1 と同じ)。今のトークンのグループの SID (WindowsIdentity の Claims) から決める
# (Test-AdministratorsSid)。読めなければ (Windows でない・例外) 管理者でないとみなす
function Test-AccountAdmin {
    $sids = @()
    try {
        $sids = @(Select-TokenGroupSids -Claims @([Security.Principal.WindowsIdentity]::GetCurrent().Claims))
    } catch {
        $sids = @()
    }
    Test-AdministratorsSid -Sids $sids
}

# winget を打ち、出力の行 (進み具合の表示は除く) と終了コードを返す。winget は管へ UTF-8 で書くので、コンソールの文字コードが UTF-8 でなければ
# 打つ間だけ UTF-8 にする (日本語の Windows の既定は CP932。UAC で昇格し直した子の窓・手で打った窓がそうで、そのまま読むと進み具合の帯 (█▒) が
# 「笆遺毎」に化けて除けず、日本語のメッセージも化ける)。runner と WSL の wrapper は UTF-8 にしてから流すので替えない。コンソールの無い host で
# 替えられなければ、替えずに読む。本文は winget を打つほかの ps1 の Invoke-Winget と同じ (Install-OpenSSH.Tests.ps1 が突き合わせる)
function Invoke-Winget {
    param([string[]]$Arguments)
    # 5.1 では Stop のままだと、外部コマンドの stderr の 1 行目で止まる
    $ErrorActionPreference = 'Continue'
    $saved = $null
    try {
        if ([Console]::OutputEncoding.CodePage -ne 65001) {
            $current = [Console]::OutputEncoding
            [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
            $saved = $current
        }
    } catch {
        $saved = $null
    }
    try {
        $lines = & winget @Arguments 2>&1 | ForEach-Object { "$_" } |
            Where-Object { $_ -notmatch '^\s*[-\\|/]?\s*$' -and $_ -notmatch '[\u2588\u2592]' }
        $code = $LASTEXITCODE
    } finally {
        if ($null -ne $saved) {
            try { [Console]::OutputEncoding = $saved } catch { }
        }
    }
    [pscustomobject]@{ ExitCode = $code; Lines = @($lines) }
}

# 今の状態を読む (管理者は要らない)
function Get-OpenSshState {
    param([string]$PackageId, [string]$InstallDir, [version]$Target)
    $sshExe = Join-Path $InstallDir 'ssh.exe'
    $installed = $null
    if (Test-Path -LiteralPath $sshExe) {
        $fileVersion = (Get-Item -LiteralPath $sshExe).VersionInfo.FileVersion
        if ($fileVersion) { $installed = [version]$fileVersion }
    }
    $agent = Get-Service -Name ssh-agent -ErrorAction SilentlyContinue
    $agentStatus = $null
    $agentStartType = $null
    if ($agent) {
        $agentStatus = "$($agent.Status)"
        $agentStartType = "$($agent.StartType)"
    }
    $pins = Invoke-Winget -Arguments @('pin', 'list', '--id', $PackageId, '--exact', '--accept-source-agreements', '--disable-interactivity')
    $show = Invoke-Winget -Arguments @('show', '--id', $PackageId, '--exact', '--versions', '--source', 'winget', '--accept-source-agreements', '--disable-interactivity')
    [pscustomobject]@{
        Installed      = $installed
        Plan           = Get-OpenSshPlan -Installed $installed -Target $Target
        AgentStatus    = $agentStatus
        AgentStartType = $agentStartType
        AgentDisabled  = Test-SshAgentDisabled -Status $agentStatus -StartType $agentStartType
        Pinned         = Test-WingetPinned -Lines $pins.Lines -PackageId $PackageId
        Latest         = Get-WingetLatestVersion -Lines $show.Lines
        Inbox          = Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32\OpenSSH\ssh.exe')
        # Install-Sshd.ps1 が MSI に Server の機能を足したか (上げる・下げるときに Server も残す)
        Server         = Test-Path -LiteralPath (Join-Path $InstallDir 'sshd.exe')
    }
}

# 状態の表を出す。直すことがある行 (⚠) は黄色にする
function Write-OpenSshState {
    param($State, [version]$Target, [string]$InstallDir)
    foreach ($row in (Format-OpenSshState -State $State -Target $Target -InstallDir $InstallDir)) {
        if ($row.Warn) { Write-Host $row.Text -ForegroundColor Yellow } else { Write-Host $row.Text }
    }
}

# 入れ替えの邪魔になる、動いている ssh.exe などを返す。sshd-session は sshd (Server の機能) の SSH の会話 (入れ替えると切れる。
# Install-Sshd.ps1 が Server を足したマシンだけにある)
function Get-BusyOpenSshProcess {
    @(Get-Process -Name ssh, ssh-add, scp, sftp, sshd-session -ErrorAction SilentlyContinue)
}

# 管理者で行う段: winget で版を揃え、ssh-agent を停止・無効にする。成功なら $true
function Invoke-OpenSshFix {
    param([string]$Plan, [string]$PackageId, [string]$Version, [switch]$Server)
    $ok = $true
    $commands = @(Get-WingetCommands -Plan $Plan -PackageId $PackageId -Version $Version -Server:$Server)
    # 昇格した側 (UAC で資格情報を入れた別の管理者のアカウント) に winget が登録されていなければ、winget を打たずにわけと手を書いて失敗にする
    # (登録はしない。親は winget を確かめてから昇格するので、同じアカウントのまま昇格したときはここに来ない)
    if (($commands.Count -gt 0) -and (-not (Get-Command winget -ErrorAction SilentlyContinue))) {
        foreach ($line in @(Format-WingetMissingNote -Account $env:USERNAME)) { Write-Step $line }
        $commands = @()
        $ok = $false
    }
    foreach ($arguments in $commands) {
        Write-Step "winget $($arguments -join ' ')"
        $result = Invoke-Winget -Arguments $arguments
        $result.Lines | Select-Object -Last 5 | ForEach-Object { Write-Step "  $_" }
        if ($result.ExitCode -ne 0) {
            Write-Step ('winget が失敗した (終了コード 0x{0:X8})' -f $result.ExitCode)
            Get-WingetPinnedHint -ExitCode $result.ExitCode -PackageId $PackageId | ForEach-Object { Write-Step $_ }
            $ok = $false
            break
        }
    }
    # winget が途中で失敗しても、MSI が ssh-agent を起動していることがあるので、後始末は必ずする
    $agent = Get-Service -Name ssh-agent -ErrorAction SilentlyContinue
    if ($agent) {
        if ($agent.Status -ne 'Stopped') {
            Stop-Service -Name ssh-agent -Force
            Write-Step 'ssh-agent を止めた'
        }
        if ($agent.StartType -ne 'Disabled') {
            Set-Service -Name ssh-agent -StartupType Disabled
            Write-Step 'ssh-agent を無効にした'
        }
    }
    $ok
}

# 自分を管理者で起動し直して終わるのを待ち、子が書いたログを出す。成功なら $true。起動し直す host は Select-ElevationHost で選ぶ (今の pwsh が
# MSIX なら MSI の pwsh を使い、それも無い管理者でない PC では UAC を出さずに止める。win/README.md の「PowerShell 7 の MSIX の限り」)
function Invoke-Elevated {
    param([string]$Version, [switch]$Force)
    $current = (Get-Process -Id $PID).Path
    # MSI の既定の置き場所 (字でつなぐ。Join-Path は、テストを流す Linux の pwsh で ProgramFiles が無いと落ちる)
    $msiPwsh = "$env:ProgramFiles\PowerShell\7\pwsh.exe"
    $hostExe = Select-ElevationHost -CurrentHost $current -MsiPwsh $msiPwsh -MsiPwshExists (Test-Path -LiteralPath $msiPwsh -PathType Leaf) -AccountAdmin (Test-AccountAdmin)
    if (-not $hostExe) {
        foreach ($line in @(Format-ElevationStopNote -CurrentHost $current -MsiPwsh $msiPwsh)) { Write-Host $line }
        return $false
    }
    $log = Join-Path $env:LOCALAPPDATA 'dotfiles\Install-OpenSSH.log'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $log) | Out-Null
    Remove-Item -LiteralPath $log -ErrorAction SilentlyContinue
    # Start-Process は配列を空白でつなぐだけなので、パスは自分で "" で囲む
    $argumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath),
        '-Version', $Version, '-LogPath', ('"{0}"' -f $log))
    if ($Force) { $argumentList += '-Force' }
    if ($hostExe -ne $current) {
        Write-Host "昇格した側は MSI の PowerShell 7 ($hostExe) で動かす (今の pwsh は MSIX で、UAC で別の管理者のアカウントに昇格すると起こせない)"
    }
    Write-Host 'UAC で管理者の PowerShell を起動する (終わると閉じる)'
    try {
        $process = Start-Process -FilePath $hostExe -ArgumentList $argumentList -Verb RunAs -Wait -PassThru
    } catch {
        Write-Host "管理者で起動できなかった (UAC で断った?): $($_.Exception.Message)"
        return $false
    }
    if (Test-Path -LiteralPath $log) {
        Get-Content -LiteralPath $log -Encoding utf8 | ForEach-Object { Write-Host "  [管理者] $_" }
    } elseif ($process.ExitCode -ne 0) {
        # 子がログを書く前に落ちた
        Write-Host ('管理者の PowerShell がログを書く前に終わった (終了コード 0x{0:X8})' -f $process.ExitCode)
    }
    $process.ExitCode -eq 0
}

# 1Password の鍵が ssh-add から見えるか。見えれば本数、見えなければ $null
function Get-AgentKeyCount {
    param([string]$SshAddExe)
    if (-not (Test-Path -LiteralPath $SshAddExe)) { return $null }
    $ErrorActionPreference = 'Continue'
    $out = @(& $SshAddExe -l 2>&1)
    if ($LASTEXITCODE -ne 0) { return $null }
    $out.Count
}

function Invoke-InstallOpenSsh {
    param([string]$Version, [switch]$Check, [switch]$IfMissing, [switch]$Force, [switch]$NoOnePassword, [string]$LogPath)
    $packageId = 'Microsoft.OpenSSH.Preview'
    $installDir = Join-Path $env:ProgramFiles 'OpenSSH'
    $target = [version]$Version
    # Write-Step が読む。ログのファイルにも書くのは、管理者で起動し直した子 (-LogPath) だけ。本体は StrictMode で走り、代入していない変数を
    # 読むと例外になるので、どの道でも先に代入する (管理者の窓から直に打つと Invoke-OpenSshFix を直に呼び、その Write-Step で止まっていた)
    $script:StepLog = $null

    if ($LogPath) {
        # 管理者で起動し直された子: 揃える段だけをして、結果を $LogPath に書く
        $script:StepLog = $LogPath
        $installed = $null
        $sshExe = Join-Path $installDir 'ssh.exe'
        if (Test-Path -LiteralPath $sshExe) { $installed = [version](Get-Item -LiteralPath $sshExe).VersionInfo.FileVersion }
        $plan = Get-OpenSshPlan -Installed $installed -Target $target
        $server = Test-Path -LiteralPath (Join-Path $installDir 'sshd.exe')
        if (Invoke-OpenSshFix -Plan $plan -PackageId $packageId -Version $Version -Server:$server) { return 0 }
        return 1
    }

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host 'winget が見つからない。Microsoft Store の「アプリ インストーラー」を入れる'
        return 1
    }

    $state = Get-OpenSshState -PackageId $packageId -InstallDir $installDir -Target $target
    Write-OpenSshState -State $state -Target $target -InstallDir $installDir
    $code = Get-OpenSshExitCode -State $state
    # -Check は何も変えない。-IfMissing は入っていないときだけ入れ、入っていれば -Check と同じ
    if ($Check -or ($IfMissing -and ($state.Plan -ne 'install'))) {
        $message = Get-OpenSshCheckMessage -State $state
        if ($code -eq 0) { Write-Host $message } else { Write-Host $message -ForegroundColor Yellow }
        return $code
    }
    if ($code -eq 0) {
        Write-Host '揃っている。何もしない'
        return 0
    }

    if (Test-OpenSshNeedsIdle -Plan $state.Plan) {
        # @() で包む。関数が返す空の配列は呼び出し側で $null にほどけ、StrictMode では
        # $null.Count が例外になる (2026-10-06 の本番で、ssh.exe が 0 本のときにここで止まった)
        $busy = @(Get-BusyOpenSshProcess)
        if ($busy.Count -gt 0 -and -not $Force) {
            Write-Host '入れ替える ssh.exe など (sshd の SSH の会話の sshd-session も) が動いている。閉じてから打ち直す (-Force で進む):'
            foreach ($p in $busy) {
                $commandLine = (Get-CimInstance Win32_Process -Filter "ProcessId=$($p.Id)").CommandLine
                Write-Host "  $($p.Id)  $commandLine"
            }
            return 1
        }
    }

    if (($state.Plan -ne 'none') -or -not $state.AgentDisabled) {
        if (Test-IsAdmin) {
            [void](Invoke-OpenSshFix -Plan $state.Plan -PackageId $packageId -Version $Version -Server:$state.Server)
        } else {
            [void](Invoke-Elevated -Version $Version -Force:$Force)
        }
    }

    if (-not $state.Pinned) {
        $pin = Invoke-Winget -Arguments @('pin', 'add', '--id', $packageId, '--exact', '--accept-source-agreements', '--disable-interactivity')
        if ($pin.ExitCode -eq 0) { Write-Host 'winget pin を足した (winget upgrade --all から外れる)' }
        else { Write-Host ('winget pin add が失敗した (終了コード 0x{0:X8})' -f $pin.ExitCode) }
    }

    # 揃ったかを読み直して確かめる
    Write-Host ''
    $after = Get-OpenSshState -PackageId $packageId -InstallDir $installDir -Target $target
    Write-OpenSshState -State $after -Target $target -InstallDir $installDir
    if ($after.Server -and ($state.Plan -ne 'none')) {
        Write-Host '  sshd            : Server の機能も入れ直した → Install-Sshd で揃える (上げ直した MSI が 22 番の受信の許可を有効に戻す)'
    }
    # 1Password の SSH agent を使わないホスト (-NoOnePassword) は、ssh-add -l を打たず、行も出さない
    $keys = $null
    if (-not $NoOnePassword) { $keys = Get-AgentKeyCount -SshAddExe (Join-Path $installDir 'ssh-add.exe') }
    $keyLine = Format-AgentKeyLine -Keys $keys -IfMissing:$IfMissing -NoOnePassword:$NoOnePassword
    if ($keyLine) { Write-Host $keyLine }
    # -IfMissing (新しい PC) の成否は版・ssh-agent・pin で決める。1Password をまだ入れていないので鍵は数えない
    if ($IfMissing) {
        $code = Get-OpenSshExitCode -State $after
        Write-Host (Get-OpenSshIfMissingMessage -Code $code)
        if ($code -eq 0) { return 0 }
        return 1
    }
    if (Test-OpenSshSynced -State $after -Keys $keys -NoOnePassword:$NoOnePassword) {
        Write-Host '揃った'
        return 0
    }
    if ($after.Plan -ne 'none') {
        Write-Host '版が揃っていない。ssh.exe が使用中で再起動待ちになったなら、再起動してからもう一度打つ'
    }
    return 1
}

# dot-source されたとき (テスト) は関数だけを読み、本体は走らせない
# 思わぬ例外は受け止めて終了コード 2 で終える。受け止めないと exit まで届かず、
# -Command から呼んだとき外側の exit $LASTEXITCODE が中の winget の 0 を返して成功に見える
if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest
    try {
        exit (Invoke-InstallOpenSsh -Version $Version -Check:$Check -IfMissing:$IfMissing -Force:$Force -NoOnePassword:$NoOnePassword -LogPath $LogPath)
    } catch {
        Write-Host "エラーで止まった: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace
        exit 2
    }
}
