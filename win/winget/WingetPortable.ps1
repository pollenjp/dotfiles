<#
.SYNOPSIS
winget の portable の道具を固定した版に揃える、共通の枠。道具ごとの入口 (win/<道具>/Install-<道具>.ps1) が dot-source する。

.DESCRIPTION
道具ごとの入口は、道具の表 (hashtable。下の「道具の表」) を作って Start-WingetPortable に渡すだけにする。この ps1 は関数を並べるだけで、
打っても何もしない。PowerShell の module (.psm1) にしないのは、試験が dot-source した後に Invoke-Winget などを差し替えて流れを確かめるため
(module の中の呼び出しは module の関数を引き、差し替えが効かない) と、開いたままの PowerShell に古い module を残さないため
(dotfiles.ps1 の Install-* は今の PowerShell の中で ps1 を打つ)。dotfiles-private の docs/adr/122_win_winget_portable_frame_*。

入口は隣 (%USERPROFILE%\.config\powershell の写し。win/manifest.toml が一緒に配る) か、clone の win\winget\ のこの ps1 を読む。

流れ (Invoke-WingetPortable)。() の中は道具が足せる custom の口 (表の Hooks に関数の名前を書く):
  ① 入口:          道具の表を既定の値で埋める (Complete-PortableTool)
  ② 打ってよいか:  見張り (Get-PortableHold)。MSI の道具 (表の Msi)・(Holds)・昇格した会話 (winget 1.30 以降)
  ③ 状態を読む:    置き場所の exe と版・winget の版の一覧と pin・PATH で引かれるもの・動いている exe・winget の版と昇格 (Get-PortableState。
                   ReadState・PathKind)
  ④ することを決める: install / change / relink / none (Get-PortablePlan。Reinstall)・直る差と直らない差 (Drift・Manual)・止める理由
                   (Get-PortableApplyBlocker。Blocker)
  ⑤ winget を打つ: 取得を確かめ (download)、pin を外し、外して入れ、pin を足す (BeforeWinget・AfterWinget)
  ⑥ 表と終了コード: 状態の表 (Format-PortableState。RowsBeforePath・RowsAfterPath・Notes)・締めの行 (Format-PortableVerdict。Verdict)・終了コード

終了コード: 0 揃っている / 1 差がある・止めた / 3 入っていない / 2 確かめられない (winget が無い・思わぬ例外)。見張りに当たれば、入っていなくても
1 (runner が -IfMissing で入れにいかない)。

状態の表の見出し (「<Name> (winget の <PackageId>、…」) と締めの行の字 (「→ <Command> で入れる」「→ <Command> で揃える」「→ ※ の手順で直す」と、
見張りの行) は、Windows の runner (win/runner/src/steps/ps1.rs) と WSL の wrapper (nix/scripts/bootstrap-windows-*.sh) が読む。runner の試験は、
この ps1 の字の $($Tool.Name) と $($Tool.Command) を道具の表の値に替えてから突き合わせるので、その 2 つはこの形のまま書く (変えるときは向こうも直す)。

BOM 付きの UTF-8 で保存すること (Windows PowerShell 5.1 は BOM の無い UTF-8 を CP932 として読む)。Windows PowerShell 5.1 と PowerShell 7 の
両方で動く書き方にする (win/README.md の「dotfiles.ps1 を書くときの注意」)。

道具の表 (Complete-PortableTool が既定の値で埋める。知らない key は止める):
  Name             (必須) 状態の表の見出しと締めの行に出す名前 ('fzf'・'Claude Code')
  Command          (必須) dotfiles.ps1 の関数の名前 ('Install-Fzf')。締めの行と直し方に出し、試験の名前にもなる (<Command>.ps1)
  PackageId        (必須) winget のパッケージ ID。入口の $packageId の行を渡す (版の知らせがその行を読む)
  CommandName      (必須) PATH で引く名前 ('fzf'。<CommandName>.exe・.cmd・.bat・.ps1 を見る)
  Readme           (必須) 直し方に添える win/README.md の節
  VersionPattern   (必須) <exe> --version の出力から版を拾う正規表現 (名前付きの組 v)
  ExePath          置き場所からの exe の相対パス (\ 区切り。manifest の RelativeFilePath)。並べれば前から見る。既定 '<CommandName>.exe'
  ExeSearch        ExePath に無ければ、置き場所の下を深さ 3 まで ExeName で探す (zip の中の形が変わっても読む)。既定 $false
  ExeName          exe の名前。既定は ExePath の 1 つ目の名前
  VersionLabel     版が読めないときの「不明 (… が読めない)」に出す字。既定 '<ExeName> --version'
  InstallerType    winget install・download の --installer-type。既定 'portable' (MSI が足されても winget に選ばせない)。manifest に依存
                   (Dependencies) があり、それを入れる道具は $null にする (winget は --installer-type を依存の解決にも効かせ、burn しか無い
                   VCRedist などに合うインストーラーが無くなって 0x8A150104 で落ちる。--skip-dependencies で依存を入れない道具は名指ししてよい)
  InstallArguments winget install に足す引数。既定 @()
  Msi              machine スコープの MSI の exe (%ProgramFiles% と %ProgramFiles(x86)% からの相対パス)。あれば何も入れずに外し方を出す。既定 $null
  BusyName         「… が N 個動いている」の主語。既定 ExeName
  BusyFix          「入れ替えるには、…」の続き。既定 '動いている <CommandName> を終わらせる'
  PathOtherFix     PATH でほかのものが先に引かれるときの直し方 ({0} はそのディレクトリ、{1} はファイルの名前)
  PathNoneFix      入っているのに PATH で見つからないときの直し方
  PathTexts        PATH の行の字 (links・package と、PathKind の custom の種類。{0} は PATH で引かれるもの)。既定に重ねる
  Synced           揃えた後に「… は揃った」と言う主語。既定 '版と pin'
  Retry            install が落ちたときの「(… でも入る)」。既定 'dotfiles apply'
  Hooks            custom の口 (段ごとに関数の名前)。下の「custom の口」
  PackageDir       置き場所。既定 %LOCALAPPDATA%\Microsoft\WinGet\Packages\<PackageId>_Microsoft.Winget.Source_8wekyb3d8bbwe
  LinksDir         winget が symlink を置く所。既定 %LOCALAPPDATA%\Microsoft\WinGet\Links

custom の口 (Hooks。どれも -Tool と -State を受け取る。PathKind だけ -Tool と -Resolved と -LinkTarget。ReadState と Reinstall が受け取る State の
Plan と Direction はまだ $null (その後に決める)。返す行に $null が混ざっても除く):
  ReadState       ③ 状態に足す値 (hashtable) を返す
  PathKind        ③ PATH で引かれるものの custom の種類 (無ければ $null。links・package・other・none のほかに分けたいとき)。-Resolved は PATH で
                  引かれるもの、-LinkTarget はそれが WinGet\Links の symlink のときの指す先 (ほかは $null)
  Reinstall       ④ 版が揃っていても入れ直す (relink) なら $true
  Holds           ② 道具の見張り (New-PortableHold で作ったもの。無ければ $null)
  Drift           ④ 揃える手順で直る差がほかにあれば $true
  Manual          ④ 揃える手順では直らない差がほかにあれば $true (人が ※ の手順で直す)
  Blocker         ④ 揃える前に止めるなら、出す行を返す (無ければ何も返さない)
  BeforeWinget    ⑤ winget を打つ前にすること
  AfterWinget     ⑤ winget を打った後 (読み直す前) にすること
  RowsBeforePath  ⑥ PATH の行の前に足す行 (@{ Label; Value; Warn })
  RowsAfterPath   ⑥ PATH の行の後に足す行 (同じ形)
  Notes           ⑥ 表の終わりに足す行 (@{ Text; Warn }。Text は ⚠ か ※ で始める)
  Verdict         ⑥ 締めの行に足す行 (入れるときは「入れる」の行の後、ほかは「揃える」の行と PATH の行の間)
#>

# ---------------------------------------------------------------------------
# 副作用の無い関数 (WingetPortable.Tests.ps1 と道具ごとの Install-*.Tests.ps1 で確かめる)
# ---------------------------------------------------------------------------

# 道具の表を既定の値で埋めた写しを返す。必須の key が無い・知らない key があれば止める (StrictMode では、hashtable に無い key を . で読むと
# 例外になるので、どの key も持たせてから使う)
function Complete-PortableTool {
    param([hashtable]$Tool)
    $required = @('Name', 'Command', 'PackageId', 'CommandName', 'Readme', 'VersionPattern')
    $optional = @('ExePath', 'ExeSearch', 'ExeName', 'VersionLabel', 'InstallerType', 'InstallArguments', 'Msi', 'BusyName', 'BusyFix',
        'PathOtherFix', 'PathNoneFix', 'PathTexts', 'Synced', 'Retry', 'Hooks', 'PackageDir', 'LinksDir')
    $hookNames = @('ReadState', 'PathKind', 'Reinstall', 'Holds', 'Drift', 'Manual', 'Blocker', 'BeforeWinget', 'AfterWinget',
        'RowsBeforePath', 'RowsAfterPath', 'Notes', 'Verdict')
    foreach ($key in @($Tool.Keys)) {
        if (($key -notin $required) -and ($key -notin $optional)) { throw "道具の表に知らない key がある: $key" }
    }
    foreach ($key in $required) {
        if (-not $Tool[$key]) { throw "道具の表に $key が無い" }
    }
    $hooks = @{}
    if ($Tool['Hooks']) {
        foreach ($key in @($Tool['Hooks'].Keys)) {
            if ($key -notin $hookNames) { throw "道具の表の Hooks に知らない口がある: $key" }
            $hooks[$key] = $Tool['Hooks'][$key]
        }
    }
    $t = @{}
    foreach ($key in @($Tool.Keys)) { $t[$key] = $Tool[$key] }
    $t.Hooks = $hooks
    $t.ExePath = @($(if ($Tool['ExePath']) { $Tool['ExePath'] } else { "$($Tool.CommandName).exe" }))
    $t.ExeSearch = [bool]$Tool['ExeSearch']
    if (-not $Tool['ExeName']) { $t.ExeName = @($t.ExePath[0] -split '\\')[-1] }
    if (-not $Tool['VersionLabel']) { $t.VersionLabel = "$($t.ExeName) --version" }
    if (-not $Tool.ContainsKey('InstallerType')) { $t.InstallerType = 'portable' }
    $t.InstallArguments = @($Tool['InstallArguments'] | Where-Object { $_ })
    if (-not $Tool['Msi']) { $t.Msi = $null }
    if (-not $Tool['BusyName']) { $t.BusyName = $t.ExeName }
    if (-not $Tool['BusyFix']) { $t.BusyFix = "動いている $($Tool.CommandName) を終わらせる" }
    if (-not $Tool['PathOtherFix']) { $t.PathOtherFix = "{0} の {1} を消すか、{0} をユーザーの PATH から外す (win/README.md の「$($Tool.Readme)」)" }
    if (-not $Tool['PathNoneFix']) { $t.PathNoneFix = "$($Tool.Name) の置き場所がユーザーの PATH に無い。PATH に足すか、winget uninstall --id $($Tool.PackageId) の後に $($Tool.Command) で入れ直す" }
    $texts = @{ links = 'winget の portable のもの (WinGet\Links の symlink)'; package = 'winget の portable のもの (置き場所)' }
    if ($Tool['PathTexts']) { foreach ($key in @($Tool['PathTexts'].Keys)) { $texts[$key] = $Tool['PathTexts'][$key] } }
    $t.PathTexts = $texts
    if (-not $Tool['Synced']) { $t.Synced = '版と pin' }
    if (-not $Tool['Retry']) { $t.Retry = 'dotfiles apply' }
    # portable の置き場所は <Id>_<ソースの識別子>。winget のソースから入れると、どのマシンでも同じ名前になる
    if (-not $Tool['PackageDir']) { $t.PackageDir = Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Packages\$($Tool.PackageId)_Microsoft.Winget.Source_8wekyb3d8bbwe" }
    if (-not $Tool['LinksDir']) { $t.LinksDir = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links' }
    $t
}

# custom の口 (表の Hooks) の関数を呼ぶ。口が無ければ何も返さない。$Parameters を渡さなければ -Tool と -State を渡す。口が返した $null は除く
# (return $null も 1 つの値になり、@() で包むと数に入る。行を返す口の「無い」を $null で書いても、行や止める理由にしない)
function Invoke-PortableHook {
    param($Tool, [string]$Name, $State, [hashtable]$Parameters)
    $command = $Tool.Hooks[$Name]
    if (-not $command) { return }
    if ($null -eq $Parameters) { $Parameters = @{ Tool = $Tool; State = $State } }
    & $command @Parameters | Where-Object { $null -ne $_ }
}

# \ で区切ったパスの親 (\ が無ければ $null)。Split-Path は Linux の pwsh では / で組み直すので、試験でも同じ字になるよう文字列で切る
function Get-PortableParent {
    param([string]$Path)
    $trimmed = $Path.TrimEnd('\')
    $cut = $trimmed.LastIndexOf('\')
    if ($cut -lt 0) { return $null }
    $trimmed.Substring(0, $cut)
}

# $Path が $Root の下か (大文字小文字を区別しない。Windows のパスと同じ)
function Test-PortableUnder {
    param([string]$Path, [string]$Root)
    if ((-not $Path) -or (-not $Root)) { return $false }
    $Path.StartsWith($Root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
}

# $Root の下の、\ で区切った相対パス (manifest の RelativeFilePath)。Join-Path を重ねて組む (\ を書かないので、Linux の pwsh で流す試験でも
# 同じに読む。5.1 には 3 つ以上を渡す Join-Path が無い)
function Join-PortablePath {
    param([string]$Root, [string]$Relative)
    $path = $Root
    foreach ($part in ($Relative -split '\\')) {
        if ($part) { $path = Join-Path $path $part }
    }
    $path
}

# <exe> --version の出力から、$Pattern の名前付きの組 v を拾う。無ければ $null
function Get-PortableVersionFromOutput {
    param([string[]]$Lines, [string]$Pattern)
    foreach ($line in $Lines) {
        if ("$line" -match $Pattern) { return $Matches['v'] }
    }
    $null
}

# winget show --versions の出力から、版の行だけを上から順 (= 新しい順) に拾う。呼ぶ側は @() で包む (1 つも無いと $null にほどける)
function Get-WingetVersionList {
    param([string[]]$Lines)
    foreach ($line in $Lines) {
        if ("$line" -match '^\s*(\d+(\.\d+)+(-[0-9A-Za-z][0-9A-Za-z.-]*)?)\s*$') { $Matches[1] }
    }
}

# winget --version の出力 ("v1.30.310" など。preview は "v1.30.140-preview") から winget 自身の版を拾う。読めなければ $null
function Get-WingetClientVersion {
    param([string[]]$Lines)
    foreach ($line in $Lines) {
        if ("$line" -match '^\s*v?(\d+)\.(\d+)(\.(\d+))?') {
            $build = if ($Matches[4]) { [int]$Matches[4] } else { 0 }
            return [version]::new([int]$Matches[1], [int]$Matches[2], $build)
        }
    }
    $null
}

# winget が、昇格した会話からの user スコープの portable を断り、symlink を作れないときに別名の hardlink を置き場所に作る版 (1.30 以降) か。
# 読めなければ $null (どちらとも決めない)
function Test-WingetModernPortable {
    param($WingetVersion)
    if ($null -eq $WingetVersion) { return $null }
    $WingetVersion -ge [version]'1.30'
}

# winget を打てるか。direct (そのまま打つ) / elevated (昇格した会話で winget が 1.30 以降。winget が user スコープの portable を入れる・外すのを
# 0x8A15007D で断る)。winget の版が読めなければ direct (打ってみる)。昇格した会話の 1.29 以前の winget は断らない
function Get-WingetRoute {
    param([bool]$Elevated, $WingetVersion)
    if ($Elevated -and ((Test-WingetModernPortable -WingetVersion $WingetVersion) -eq $true)) { return 'elevated' }
    'direct'
}

# 入っているか・入っている版・固定した版から、することを決める。exe があるのに版が読めないときも入れ替える (外してから入れ直せば直る)。
# 版が揃っていても、道具が入れ直すと決めた (Hooks.Reinstall。codex の codex と打てる形が無いなど) なら relink (同じ版を入れ直す)
function Get-PortablePlan {
    param([bool]$Exists, [string]$Installed, [string]$Target, [bool]$Reinstall = $false)
    if (-not $Exists) { return 'install' }
    if ($Installed -cne $Target) { return 'change' }
    if ($Reinstall) { return 'relink' }
    'none'
}

# 入れ替えの向き。版の文字列は [version] にならないことがあるので、winget show --versions の並び (新しい順) の位置で比べる
function Get-PortableDirection {
    param([string[]]$Versions, [string]$Installed, [string]$Target)
    $list = @($Versions)
    $i = [array]::IndexOf($list, $Installed)
    $t = [array]::IndexOf($list, $Target)
    if ($i -lt 0 -or $t -lt 0) { return 'unknown' }
    if ($t -lt $i) { return 'up' }
    if ($t -gt $i) { return 'down' }
    'same'
}

# winget pin list の出力に、その Id を列に持つ行があるか。見出しや「pin が無い」の文言は表示言語で変わるので、Id の一致だけを見る
function Test-WingetPinned {
    param([string[]]$Lines, [string]$PackageId)
    foreach ($line in $Lines) {
        if (($line -split '\s+') -ccontains $PackageId) { return $true }
    }
    $false
}

# plan ごとに打つ winget の引数 (配列の配列)。入れ替え・入れ直しは版の上げ下げによらず、外してから入れる (portable の置き場所は版によらず
# 同じで、道具の設定は置き場所の外にある)。install は portable を名指しする (表の InstallerType。付けないと、MSI のある道具では winget が
# MSI を選ぶ)。どれも upgrade を打たない (版を名指しした upgrade は、--include-pinned が無いと自分で足した pin に止められる (0x8A150068)。
# install・uninstall は --include-pinned を受け付けない。入っていない形にしてから入れるので、winget は pin を見ない)
function Get-WingetCommands {
    param($Tool, [string]$Plan, [string]$Version)
    $common = @('--id', $Tool.PackageId, '--exact', '--source', 'winget', '--silent',
        '--accept-source-agreements', '--disable-interactivity')
    $put = $common + @('--version', $Version)
    if ($Tool.InstallerType) { $put += @('--installer-type', $Tool.InstallerType) }
    $put += @($Tool.InstallArguments) + @('--accept-package-agreements')
    switch ($Plan) {
        'install' { , (@('install') + $put) }
        { $_ -in @('change', 'relink') } {
            , (@('uninstall') + $common)
            , (@('install') + $put)
        }
    }
}

# 入れ替え・入れ直しの前に、固定した版の取得とハッシュだけを確かめる winget download の引数 (入れるものと同じ installer を名指しする)
function Get-WingetDownloadArguments {
    param($Tool, [string]$Version, [string]$Directory)
    $arguments = @('download', '--id', $Tool.PackageId, '--exact', '--source', 'winget', '--version', $Version)
    if ($Tool.InstallerType) { $arguments += @('--installer-type', $Tool.InstallerType) }
    $arguments + @('--download-directory', $Directory, '--skip-dependencies', '--accept-package-agreements',
        '--accept-source-agreements', '--disable-interactivity')
}

# winget の失敗の終了コードに添える行。無ければ $null。
#   0x8A15007D (APPINSTALLER_CLI_ERROR_ADMIN_CONTEXT_ACTION_PROHIBITED): 昇格した会話から user スコープの portable を扱うのを winget が断った
#     (会話の昇格を見誤ったとき・pin を足す・外すのも断ったとき。入れる・入れ替えるのは見張り (Get-PortableHold) が先に止める)
#   0x8A150104 (APPINSTALLER_CLI_ERROR_INSTALL_MISSING_DEPENDENCY): manifest の依存 (VCRedist など) を入れられなかった。依存を先に入れておけば
#     winget は依存を入れにいかない (表の InstallerType が依存の解決にも効いて落ちたときも、これで入る)
function Get-WingetFailureHint {
    param($Tool, [int]$ExitCode)
    if ($ExitCode -eq -1978335107) {
        return "昇格した会話から user スコープの portable を扱うのを winget が断った (0x8A15007D)。昇格していない PowerShell で $($Tool.Command) を打ち直す"
    }
    if ($ExitCode -eq -1978334972) {
        return "winget が $($Tool.Name) の依存のパッケージ (上の winget の行に出た VCRedist など) を入れられなかった (0x8A150104)。PowerShell で winget install --id <依存の ID> --exact を打って先に入れてから、$($Tool.Command) を打ち直す (win/README.md の「$($Tool.Readme)」)"
    }
    $null
}

# PATH (; 区切り) を前から見て、$Names のどれかが最初に見つかったパスを返す。無ければ $null。
# PowerShell は PATH のディレクトリの順に、.exe だけでなく .cmd・.bat・.ps1 も引く (npm の global は <名前>.cmd を置く) ので、
# ディレクトリごとに名前を並べて見る。$Exists はファイルがあるかを答える scriptblock (試験では偽物を渡す)。
# 区切りは \ で組む (Linux の pwsh で流す試験でも同じ文字列になるよう、Join-Path は使わない)
function Resolve-PortableOnPath {
    param([string]$PathValue, [string[]]$Names, [scriptblock]$Exists)
    foreach ($entry in ($PathValue -split ';')) {
        $dir = [Environment]::ExpandEnvironmentVariables($entry.Trim().Trim('"')).TrimEnd('\')
        if (-not $dir) { continue }
        foreach ($name in $Names) {
            $candidate = "$dir\$name"
            if (& $Exists $candidate) { return $candidate }
        }
    }
    $null
}

# PATH で引かれるものがどこのものか。links (winget が symlink を置く WinGet\Links。開発者モードが on のときなど) / package (置き場所の exe の
# ディレクトリ。winget が symlink を作れずに、置き場所を PATH に足した形。manifest に ArchiveBinariesDependOnPath: true がある道具 (herdr) は、
# 開発者モードでも symlink を作らずにこの形になる) / $Custom (道具の custom の種類。Hooks.PathKind) / other / none。
# WinGet\Links のものでも、symlink の指す先 ($LinkTarget) がこの道具の置き場所 ($PackageDir) の外なら links にしない (ほかのパッケージの同じ名前の
# symlink。herdr の Herdr.Herdr.Preview など)。指す先が読めなければ links のまま。-eq は大文字小文字を区別しない (Windows のパスと同じ)
function Get-PortablePathKind {
    param([string]$Resolved, [string]$ExeDir, [string]$LinksDir, [string]$Custom, [string]$LinkTarget, [string]$PackageDir)
    if (-not $Resolved) { return 'none' }
    $dir = Get-PortableParent -Path $Resolved
    if ($null -eq $dir) { return 'other' }
    if ($LinksDir -and ($dir -eq $LinksDir.TrimEnd('\'))) {
        if ((-not $LinkTarget) -or (-not $PackageDir) -or (Test-PortableUnder -Path $LinkTarget -Root $PackageDir)) { return 'links' }
    } elseif ($ExeDir -and ($dir -eq $ExeDir.TrimEnd('\'))) {
        return 'package'
    }
    if ($Custom) { return $Custom }
    'other'
}

# PATH のずれ (ほかのものが先に引かれる・入っているのに見つからない) があるか。揃える手順では直らないので、※ の行で直し方を添える。入れる・
# 入れ直す前 (winget が PATH の形を作り直す) に見つからないのは当たり前なので数えない。custom の種類 (PathKind) は数えない (道具が Manual で数える)
function Test-PortablePathDrift {
    param($State)
    ($State.PathKind -eq 'other') -or (($State.PathKind -eq 'none') -and ($State.Plan -notin @('install', 'relink')))
}

# 揃える手順で直る差 (版・pin と、道具の Drift) があるか
function Test-PortableDrift {
    param($Tool, $State)
    if (($State.Plan -ne 'none') -or (-not $State.Pinned)) { return $true }
    [bool](Invoke-PortableHook -Tool $Tool -Name 'Drift' -State $State)
}

# 揃える手順では直らない差 (PATH のずれと、道具の Manual) があるか
function Test-PortableManual {
    param($Tool, $State)
    if (Test-PortablePathDrift -State $State) { return $true }
    [bool](Invoke-PortableHook -Tool $Tool -Name 'Manual' -State $State)
}

# 見張り (winget を打たずに止めること) の形。Rows は表に足す行 (@{ Text; Warn }。Text は ⚠ か ※ で始める)、Verdict は締めの行 (これだけを出す)、
# Message は揃える流れで止めるときの 1 行。KeepPathFix が $false なら、PATH のずれの ※ の行を出さない (見張りの直し方で PATH も直るとき)
function New-PortableHold {
    param([string]$Name, [object[]]$Rows, [string]$Verdict, [string]$Message, [bool]$KeepPathFix = $true)
    # 条件つきの行 (if が何も返さない・$null を返す) を並べても、$null は行にしない
    [pscustomobject]@{ Name = $Name; Rows = @($Rows | Where-Object { $null -ne $_ }); Verdict = $Verdict; Message = $Message; KeepPathFix = $KeepPathFix }
}

# MSI の道具 (machine スコープ。winget の既定の installer) が入っている。portable と二重になり、winget の install・pin がどちらを指すか決まらない
# (PATH ではマシンの MSI が先に引かれる)。外すのは人 (UAC が要る)
function New-PortableMsiHold {
    param($Tool, $State)
    New-PortableHold -Name 'msi' -KeepPathFix $false -Rows @(
        @{ Text = "⚠ MSI の $($Tool.Name) (machine スコープ。winget の既定の installer) が入っている: $($State.MsiExe)"; Warn = $true }
        @{ Text = "※ portable と二重にしないため、MSI があるうちは $($Tool.Command) は何も入れない。PowerShell で winget uninstall --id $($Tool.PackageId) --exact --scope machine を打って MSI を外し (UAC の確認が出る)、$($Tool.Command) を打ち直す (win/README.md の「$($Tool.Readme)」)"; Warn = $false }
    ) -Verdict "⚠️ MSI の $($Tool.Name) (machine スコープ) が入っている → ※ の手順で直す ⚠️" -Message "MSI の $($Tool.Name) が入っているので、portable を入れずに止める。上の ※ の行の手順で MSI を外してから打ち直す"
}

# 昇格した会話 (UAC で昇格した token) で、winget が 1.30 以降。winget が user スコープの portable を入れる・外すのを 0x8A15007D で断る
function New-PortableElevatedHold {
    param($Tool, $State)
    $winget = if ($State.WingetVersion) { "winget $($State.WingetVersion)" } else { 'winget' }
    New-PortableHold -Name 'elevated' -Rows @(
        @{ Text = "⚠ 昇格した PowerShell では winget が $($Tool.Name) を入れない ($winget は、昇格した会話から user スコープの portable を入れる・外すのを断る)。$($Tool.Command) は winget を打たない"; Warn = $true }
        @{ Text = "※ 昇格していない PowerShell (デスクトップの普通の端末) で $($Tool.Command) を打ち直す (win/README.md の「winget の portable の道具」)"; Warn = $false }
    ) -Verdict "⚠️ 昇格した PowerShell では winget が $($Tool.Name) を入れない (winget 1.30 から) → ※ の手順で直す ⚠️" -Message "昇格した PowerShell では winget が $($Tool.Name) を入れないので、何も変えずに止める。昇格していない PowerShell で $($Tool.Command) を打ち直す"
}

# 見張り。揃える前に winget を打たずに止めることのうち、最初に当たった 1 つ ($null は無い)。当たれば終了コードは入っていなくても 1、締めの行は
# その 1 行だけ。順に:
#   msi:      MSI の道具が入っている (表の Msi)。入れるかによらず当たる
#   (custom): 道具の見張り (Hooks.Holds。codex の、開発者モードが off で 1.29 以前の winget など)
#   elevated: 入れる・入れ替える・入れ直すのに、昇格した会話で winget が 1.30 以降。pin を足す・外すだけなら止めない
function Get-PortableHold {
    param($Tool, $State)
    if ($State.MsiExe) { return New-PortableMsiHold -Tool $Tool -State $State }
    $custom = Invoke-PortableHook -Tool $Tool -Name 'Holds' -State $State
    if ($custom) { return $custom }
    if (($State.Route -eq 'elevated') -and ($State.Plan -in @('install', 'change', 'relink'))) {
        return New-PortableElevatedHold -Tool $Tool -State $State
    }
    $null
}

# 終了コード。見張りに当たれば 1 (入っていなくても 3 にしない。runner が -IfMissing で入れにいかないように)、入っていなければ 3、直る差も
# 直らない差も無ければ 0、ほかは 1
function Get-PortableExitCode {
    param($Tool, $State)
    if (Get-PortableHold -Tool $Tool -State $State) { return 1 }
    if ($State.Plan -eq 'install') { return 3 }
    if ((Test-PortableDrift -Tool $Tool -State $State) -or (Test-PortableManual -Tool $Tool -State $State)) { return 1 }
    0
}

# 見張りを通った後に、揃える前に止める理由。無ければ $null
#   not-listed: 入れる・入れ替える・入れ直すのに、固定した版が winget に無い (版の一覧が読めたときだけ判断する)
#   custom:     道具の止める理由 (Hooks.Blocker が行を返した。herdr の Preview など)
#   busy:       入れ替える・入れ直すのに、置き場所の exe が動いている (置き換えられない)
function Get-PortableApplyBlocker {
    param($Tool, $State, [string]$Target)
    $known = @($State.Versions | Where-Object { $_ })
    if (($State.Plan -ne 'none') -and ($known.Count -gt 0) -and ($known -cnotcontains $Target)) { return 'not-listed' }
    if (@(Invoke-PortableHook -Tool $Tool -Name 'Blocker' -State $State).Count -gt 0) { return 'custom' }
    if (($State.Plan -in @('change', 'relink')) -and ($State.BusyCount -gt 0)) { return 'busy' }
    $null
}

# 表の行の見出し (「入っている版    : 」)。字の幅 (ASCII は 1、ほかは 2) で 16 桁にそろえて「: 」を続ける
function Format-PortableLabel {
    param([string]$Label)
    $width = 0
    foreach ($c in $Label.ToCharArray()) {
        $width += $(if ([int]$c -gt 0x7F) { 2 } else { 1 })
    }
    $Label + (' ' * [Math]::Max(0, 16 - $width)) + ': '
}

# 状態の表の行 (Text と、直すことがあるかの Warn)。直すことがある行だけ先頭に ⚠ を付け、ほかは 2 字下げる。ずれではないこと (新しい版がある・
# 動いている exe がある) は ※ で添える
function Format-PortableState {
    param($Tool, $State, [string]$Target)
    $direction = if ($State.Direction -eq 'up') { ' (上げる)' } elseif ($State.Direction -eq 'down') { ' (下げる)' } else { '' }
    $planText = switch ($State.Plan) {
        'install' { '入れる' }
        'change' { "入れ替える$direction" }
        default { 'そのまま' }
    }
    $installedText = if ($State.Plan -eq 'install') { '入っていない' } elseif ($State.Installed) { $State.Installed } else { "不明 ($($Tool.VersionLabel) が読めない)" }
    $latestText = if ($State.Latest) { $State.Latest } else { '不明 (winget show が失敗)' }
    $pinText = if ($State.Pinned) { 'あり' } else { '無し → 足す' }
    # WinGet\Links の symlink がほかを指すとき (links でないとき) は、指す先も出す
    $shown = if ($State.PathLinkTarget -and ($State.PathKind -ne 'links')) { "$($State.PathResolved) → $($State.PathLinkTarget)" } else { "$($State.PathResolved)" }
    $pathText = switch ($State.PathKind) {
        'other' { "$shown (winget の portable のものではない)" }
        'none' { '見つからない' }
        default {
            if ($Tool.PathTexts[$State.PathKind]) { $Tool.PathTexts[$State.PathKind] -f $shown } else { $shown }
        }
    }
    # custom の種類 (PathKind) は、入れる前なら当たり前なので ⚠ にしない
    $custom = $State.PathKind -notin @('links', 'package', 'other', 'none')
    $pathWarn = (Test-PortablePathDrift -State $State) -or ($custom -and ($State.Plan -ne 'install'))
    $rows = @(
        @{ Label = '入っている版'; Value = $installedText; Warn = $false }
        @{ Label = '固定した版'; Value = "$Target → $planText"; Warn = ($State.Plan -in @('install', 'change')) }
        @{ Label = 'winget の最新版'; Value = $latestText; Warn = $false }
        @{ Label = 'winget pin'; Value = $pinText; Warn = (-not $State.Pinned) }
    )
    $rows += @(Invoke-PortableHook -Tool $Tool -Name 'RowsBeforePath' -State $State)
    $rows += @(@{ Label = "PATH の $($Tool.CommandName)"; Value = $pathText; Warn = $pathWarn })
    $rows += @(Invoke-PortableHook -Tool $Tool -Name 'RowsAfterPath' -State $State)
    [pscustomobject]@{ Text = "$($Tool.Name) (winget の $($Tool.PackageId)、$($Tool.PackageDir))"; Warn = $false }
    # 行は hashtable (custom の口が返す行も)。添字で読む (StrictMode では、hashtable に無い key を . で読むと例外になる)
    foreach ($row in $rows) {
        $prefix = if ($row['Warn']) { '⚠ ' } else { '  ' }
        [pscustomobject]@{ Text = "$prefix$(Format-PortableLabel -Label $row['Label'])$($row['Value'])"; Warn = [bool]$row['Warn'] }
    }
    $versions = @($State.Versions | Where-Object { $_ })
    if (($versions.Count -gt 0) -and ($versions -cnotcontains $Target)) {
        if ($State.Plan -in @('none', 'relink')) {
            [pscustomobject]@{ Text = '※ 固定した版が winget から消えている。新しいマシンには入れられないので、-Version を winget にある版へ変える'; Warn = $false }
        } else {
            [pscustomobject]@{ Text = '⚠ 固定した版が winget show --versions に無い (書き間違いか、winget から消えた) ので入れられない'; Warn = $true }
        }
    } elseif (($versions.Count -gt 0) -and ($versions[0] -cne $Target)) {
        [pscustomobject]@{ Text = "※ winget に固定した版より新しい $($versions[0]) がある。上げるなら $($Tool.Command).ps1 の -Version の既定値を変える"; Warn = $false }
    }
    $hold = Get-PortableHold -Tool $Tool -State $State
    if ($hold) {
        foreach ($row in $hold.Rows) { [pscustomobject]@{ Text = $row['Text']; Warn = [bool]$row['Warn'] } }
    }
    # PATH のずれは揃える手順では直らないので、直し方を添える (見張りの直し方で PATH も直るときは出さない)
    if ((-not $hold) -or $hold.KeepPathFix) {
        if ($State.PathKind -eq 'other') {
            $cut = $State.PathResolved.LastIndexOf('\')
            $dir = if ($cut -ge 0) { $State.PathResolved.Substring(0, $cut) } else { $State.PathResolved }
            $leaf = $State.PathResolved.Substring($cut + 1)
            # WinGet\Links の、ほかのパッケージの symlink。WinGet\Links を PATH から外すと winget の portable のどれもが引けなくなるので、表の
            # PathOtherFix を使わない
            $fix = if ($State.PathLinkTarget) { "$dir の $leaf は $($State.PathLinkTarget) を指す (ほかのパッケージの symlink)。指す先を入れたパッケージを winget uninstall で外すか、その symlink を消す (win/README.md の「$($Tool.Readme)」)" } else { $Tool.PathOtherFix -f $dir, $leaf }
            [pscustomobject]@{ Text = "※ PATH のずれは $($Tool.Command) では直らない。$fix"; Warn = $false }
        } elseif (($State.PathKind -eq 'none') -and ($State.Plan -notin @('install', 'relink'))) {
            [pscustomobject]@{ Text = "※ $($Tool.PathNoneFix)"; Warn = $false }
        }
    }
    if (($State.Plan -in @('change', 'relink')) -and ($State.BusyCount -gt 0)) {
        [pscustomobject]@{ Text = "※ $($Tool.BusyName) が $($State.BusyCount) 個動いている。入れ替えるには、$($Tool.BusyFix)"; Warn = $false }
    }
    foreach ($row in @(Invoke-PortableHook -Tool $Tool -Name 'Notes' -State $State)) {
        [pscustomobject]@{ Text = $row['Text']; Warn = [bool]$row['Warn'] }
    }
}

# 締めの行 (-Check の最後と、揃えた後の最後)。揃っていれば何も返さない。直すことごとに ⚠️ で始まる行を返す。Windows の runner
# (win/runner/src/steps/ps1.rs) と WSL の wrapper (nix/scripts/bootstrap-windows-*.sh) は「→ <Command> で入れる」「→ <Command> で揃える」
# 「→ ※ の手順で直す」の字で、入れるか・揃えるか・知らせるだけかを決め、見張りの行 (MSI・昇格・道具の見張り) の字で直し方を選ぶ (字を変えるときは
# 向こうも直す)。見張りに当たれば、その 1 行だけ
function Format-PortableVerdict {
    param($Tool, $State)
    $hold = Get-PortableHold -Tool $Tool -State $State
    if ($hold) {
        $hold.Verdict
        return
    }
    if ($State.Plan -eq 'install') {
        "⚠️ $($Tool.Name) が入っていない → $($Tool.Command) で入れる ⚠️"
        Invoke-PortableHook -Tool $Tool -Name 'Verdict' -State $State
        return
    }
    if (($State.Plan -eq 'change') -or (-not $State.Pinned)) { "⚠️ 固定した版と揃っていない → $($Tool.Command) で揃える ⚠️" }
    Invoke-PortableHook -Tool $Tool -Name 'Verdict' -State $State
    if (Test-PortablePathDrift -State $State) { "⚠️ PATH の $($Tool.CommandName) が winget の portable のものではない → ※ の手順で直す ⚠️" }
}

# ---------------------------------------------------------------------------
# Windows に触る関数 (実機で -Check と本番を打って確かめる)
# ---------------------------------------------------------------------------

# winget を打ち、出力の行 (進み具合の表示は除く) と終了コードを返す。winget は管へ UTF-8 で書くので、コンソールの文字コードが UTF-8 でなければ
# 打つ間だけ UTF-8 にする (日本語の Windows の既定は CP932。手で打った窓・UAC で昇格し直した子の窓。そのまま読むと進み具合の帯と日本語の
# メッセージが化ける。runner と WSL の wrapper は UTF-8 にしてから流すので替えない)。本文は Install-OpenSSH.ps1 の Invoke-Winget と同じ
# (Install-OpenSSH.Tests.ps1 が突き合わせる)
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

# 置き場所の exe を探す。表の ExePath (manifest の RelativeFilePath) を前から見て、無ければ (ExeSearch なら) 置き場所の下を深さ 3 まで探す。
# 無ければ $null
function Find-PortableExe {
    param($Tool)
    foreach ($relative in @($Tool.ExePath)) {
        $path = Join-PortablePath -Root $Tool.PackageDir -Relative $relative
        if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
    }
    if (-not $Tool.ExeSearch) { return $null }
    if (-not (Test-Path -LiteralPath $Tool.PackageDir -PathType Container)) { return $null }
    $found = @(Get-ChildItem -LiteralPath $Tool.PackageDir -Filter $Tool.ExeName -File -Recurse -Depth 3 -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($found.Count -gt 0) { return $found[0].FullName }
    $null
}

# MSI の道具の exe (manifest の DefaultInstallLocation の下。x64・arm64 は %ProgramFiles%、x86 は %ProgramFiles(x86)%)。$ProgramFiles に並べた順に
# 見て、最初に見つかったもの。無ければ $null
function Find-PortableMsiExe {
    param([string[]]$ProgramFiles, [string]$Relative)
    foreach ($root in @($ProgramFiles | Where-Object { $_ })) {
        $exe = Join-PortablePath -Root $root -Relative $Relative
        if (Test-Path -LiteralPath $exe -PathType Leaf) { return $exe }
    }
    $null
}

# exe に版を聞く。読めなければ $null
function Get-PortableInstalledVersion {
    param([string]$Exe, [string]$Pattern)
    $ErrorActionPreference = 'Continue'
    try {
        $out = @(& $Exe --version 2>&1 | ForEach-Object { "$_" })
    } catch {
        # 起動できない (壊れた・0 バイト・方針で止められた) ときも、版が読めないとして入れ替えの対象にする
        return $null
    }
    Get-PortableVersionFromOutput -Lines $out -Pattern $Pattern
}

# symlink の指す先 (絶対パス)。symlink でない・読めなければ $null。5.1 の Target は文字列の並び、7 は文字列なので、@() で包んで 1 つ目を取る
function Get-PortableLinkTarget {
    param([string]$Path)
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    } catch {
        return $null
    }
    if ("$($item.LinkType)" -ne 'SymbolicLink') { return $null }
    $target = @($item.Target | Where-Object { $_ }) | Select-Object -First 1
    if (-not $target) { return $null }
    $target = "$target" -replace '^\\\\\?\\', '' -replace '^\\\?\?\\', ''
    if (-not [IO.Path]::IsPathRooted($target)) { $target = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $Path) $target)) }
    $target
}

# これから開く PowerShell が使う PATH (マシン → ユーザーの順)。今のプロセスの PATH は古いことがある
function Get-PortablePathValue {
    @([Environment]::GetEnvironmentVariable('Path', 'Machine'), [Environment]::GetEnvironmentVariable('Path', 'User')) -join ';'
}

# 置き場所の下の exe か、WinGet\Links の symlink から起動して動いているプロセス
function Get-PortableBusyProcess {
    param($Tool)
    $prefix = $Tool.PackageDir.TrimEnd('\') + '\'
    $link = "$($Tool.LinksDir.TrimEnd('\'))\$($Tool.CommandName).exe"
    @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $path = $null
            try { $path = $_.Path } catch { $path = $null }
            $path -and ($path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or $path.Equals($link, [StringComparison]::OrdinalIgnoreCase))
        })
}

# 今の PowerShell が UAC で昇格した token (TokenElevationTypeFull) で動いているか。winget 1.30 が user スコープの portable を断るのと同じ見方
# (winget の Runtime::IsRunningWithNonDefaultFullToken)。UAC の分かれていない管理者 (Administrator・UAC が off) は Default なので当たらない。
# token を読めなければ (Add-Type が方針で止められたなど) 昇格していないとして winget を打つ。管理者のロールで代えると、UAC が off の管理者を
# 昇格したと見誤り、winget が断らないのに入れられなくなる。見誤って打っても、winget が断れば終了コード 0x8A15007D に直し方を添える
# (Get-WingetFailureHint)
function Test-WingetElevated {
    try {
        if (-not ('DotfilesWinget.TokenInfo' -as [type])) {
            Add-Type -Namespace DotfilesWinget -Name TokenInfo -MemberDefinition @'
[DllImport("advapi32.dll", SetLastError = true)]
public static extern bool GetTokenInformation(IntPtr token, int infoClass, out int info, int length, out int returnLength);
'@
        }
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $type = 0
        $returned = 0
        # 18 は TokenElevationType。1 = Default、2 = Full (UAC で昇格した)、3 = Limited
        if ([DotfilesWinget.TokenInfo]::GetTokenInformation($identity.Token, 18, [ref]$type, 4, [ref]$returned)) { return ($type -eq 2) }
    } catch {
    }
    $false
}

# 開発者モード (設定 > システム > 開発者向け) が on か。on なら、昇格していない winget も WinGet\Links に symlink を作れる
function Test-DeveloperMode {
    $key = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' -Name 'AllowDevelopmentWithoutDevLicense' -ErrorAction SilentlyContinue
    [bool]($key -and ($key.AllowDevelopmentWithoutDevLicense -eq 1))
}

# 今の状態を読む (何も変えない。管理者は要らない)。道具の custom の値 (Hooks.ReadState) を足してから、することを決める
function Get-PortableState {
    param($Tool, [string]$Target)
    $exe = Find-PortableExe -Tool $Tool
    $exists = [bool]$exe
    $installed = $null
    if ($exists) { $installed = Get-PortableInstalledVersion -Exe $exe -Pattern $Tool.VersionPattern }
    # 入っていなければ、winget が足すはずのディレクトリ (manifest の RelativeFilePath の親) で PATH を見る
    $exeDir = if ($exe) { Get-PortableParent -Path $exe } else { Get-PortableParent -Path "$($Tool.PackageDir.TrimEnd('\'))\$($Tool.ExePath[0])" }
    $wingetVersion = Get-WingetClientVersion -Lines (Invoke-Winget -Arguments @('--version')).Lines
    $pins = Invoke-Winget -Arguments @('pin', 'list', '--id', $Tool.PackageId, '--exact', '--accept-source-agreements', '--disable-interactivity')
    $show = Invoke-Winget -Arguments @('show', '--id', $Tool.PackageId, '--exact', '--versions', '--source', 'winget', '--accept-source-agreements', '--disable-interactivity')
    # @() で包む。関数が返す空の配列は呼び出し側で $null にほどける (Install-OpenSSH.ps1 で踏んだ)
    $versions = @(Get-WingetVersionList -Lines $show.Lines)
    $latest = $null
    if ($versions.Count -gt 0) { $latest = $versions[0] }
    $names = @(@('exe', 'cmd', 'bat', 'ps1') | ForEach-Object { "$($Tool.CommandName).$_" })
    $resolved = Resolve-PortableOnPath -PathValue (Get-PortablePathValue) -Names $names -Exists { param($p) Test-Path -LiteralPath $p -PathType Leaf }
    # WinGet\Links のものなら、symlink の指す先 (この道具の置き場所か、ほかのパッケージか)
    $linkTarget = $null
    if ($resolved -and ((Get-PortableParent -Path $resolved) -eq $Tool.LinksDir.TrimEnd('\'))) { $linkTarget = Get-PortableLinkTarget -Path $resolved }
    $custom = Invoke-PortableHook -Tool $Tool -Name 'PathKind' -Parameters @{ Tool = $Tool; Resolved = $resolved; LinkTarget = $linkTarget }
    $msi = $null
    if ($Tool.Msi) { $msi = Find-PortableMsiExe -ProgramFiles @($env:ProgramFiles, ${env:ProgramFiles(x86)}) -Relative $Tool.Msi }
    $elevated = Test-WingetElevated
    $state = [ordered]@{
        Exists         = $exists
        Installed      = $installed
        Exe            = $exe
        Plan           = $null
        Direction      = $null
        Pinned         = Test-WingetPinned -Lines $pins.Lines -PackageId $Tool.PackageId
        Versions       = $versions
        Latest         = $latest
        PathResolved   = $resolved
        PathLinkTarget = $linkTarget
        PathKind       = Get-PortablePathKind -Resolved $resolved -ExeDir $exeDir -LinksDir $Tool.LinksDir -Custom $custom -LinkTarget $linkTarget -PackageDir $Tool.PackageDir
        BusyCount      = @(Get-PortableBusyProcess -Tool $Tool).Count
        MsiExe         = $msi
        WingetVersion  = $wingetVersion
        Elevated       = $elevated
        Route          = Get-WingetRoute -Elevated $elevated -WingetVersion $wingetVersion
    }
    $extra = Invoke-PortableHook -Tool $Tool -Name 'ReadState' -State ([pscustomobject]$state)
    if ($extra) {
        foreach ($key in @($extra.Keys)) { $state[$key] = $extra[$key] }
    }
    $reinstall = [bool](Invoke-PortableHook -Tool $Tool -Name 'Reinstall' -State ([pscustomobject]$state))
    $state.Plan = Get-PortablePlan -Exists $exists -Installed $installed -Target $Target -Reinstall $reinstall
    $state.Direction = Get-PortableDirection -Versions $versions -Installed $installed -Target $Target
    [pscustomobject]$state
}

# 状態の表を出す。直すことがある行 (⚠) は黄色にする
function Write-PortableState {
    param($Tool, $State, [string]$Target)
    foreach ($row in (Format-PortableState -Tool $Tool -State $State -Target $Target)) {
        if ($row.Warn) { Write-Host $row.Text -ForegroundColor Yellow } else { Write-Host $row.Text }
    }
}

# 締めの行 (直すこと) を黄色で出す。揃っていれば何も出さない
function Write-PortableVerdict {
    param($Tool, $State)
    foreach ($line in (Format-PortableVerdict -Tool $Tool -State $State)) {
        Write-Host $line -ForegroundColor Yellow
    }
}

# 揃える流れ (頭の「流れ」の ①〜⑥)。終了コードを返す。-Check は何も変えない。-IfMissing は入っていないときだけ入れ、入っていれば -Check と同じ
function Invoke-WingetPortable {
    param([hashtable]$Tool, [string]$Version, [switch]$Check, [switch]$IfMissing)
    # ① 入口
    $Tool = Complete-PortableTool -Tool $Tool
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host 'winget が見つからない。PowerShell で Install-WinGet を打って入れる (win/README.md の「winget」)'
        return 2
    }

    # ③ 状態を読む・④ することを決める
    $state = Get-PortableState -Tool $Tool -Target $Version
    Write-PortableState -Tool $Tool -State $state -Target $Version
    $code = Get-PortableExitCode -Tool $Tool -State $state

    if ($Check -or ($IfMissing -and ($state.Plan -ne 'install'))) {
        if ($code -eq 0) { Write-Host '揃っている' }
        Write-PortableVerdict -Tool $Tool -State $state
        return $code
    }
    if ($code -eq 0) {
        Write-Host '揃っている。何もしない'
        return 0
    }
    # ② 打ってよいか
    $hold = Get-PortableHold -Tool $Tool -State $state
    if ($hold) {
        Write-Host $hold.Message
        Write-PortableVerdict -Tool $Tool -State $state
        return 1
    }
    # 揃える手順で直す差が無く、残っているのは人が直すこと (PATH のずれなど) だけ
    if (-not (Test-PortableDrift -Tool $Tool -State $state)) {
        Write-Host "$($Tool.Synced) は揃っている。残りの差は $($Tool.Command) では直らない (※ の行・締めの行の手順で直す)"
        Write-PortableVerdict -Tool $Tool -State $state
        return 1
    }

    $blocker = Get-PortableApplyBlocker -Tool $Tool -State $state -Target $Version
    if ($blocker -eq 'not-listed') {
        Write-Host "固定した版 $Version が winget に無いので入れられない。-Version を winget show --id $($Tool.PackageId) --versions にある版へ変える"
        return 1
    }
    if ($blocker -eq 'custom') {
        foreach ($line in @(Invoke-PortableHook -Tool $Tool -Name 'Blocker' -State $state)) { Write-Host $line }
        return 1
    }
    if ($blocker -eq 'busy') {
        Write-Host "$($Tool.BusyName) が動いていて置き換えられない。上の ※ の行のとおり止めてから打ち直す:"
        foreach ($p in @(Get-PortableBusyProcess -Tool $Tool)) {
            $commandLine = (Get-CimInstance Win32_Process -Filter "ProcessId=$($p.Id)").CommandLine
            Write-Host "  $($p.Id)  $commandLine"
        }
        return 1
    }

    # ⑤ winget を打つ。入れ替え・入れ直しは外してから入れるので、取得が落ちると道具が消えたまま終わる。
    # 外す前に、固定した版を取得してハッシュまで確かめる (落ちたら何も変えずに止める)
    if ($state.Plan -in @('change', 'relink')) {
        $downloadDir = Join-Path ([IO.Path]::GetTempPath()) "winget-portable-$($Tool.CommandName)-$PID"
        $arguments = @(Get-WingetDownloadArguments -Tool $Tool -Version $Version -Directory $downloadDir)
        Write-Host "winget $($arguments -join ' ')"
        $download = Invoke-Winget -Arguments $arguments
        Remove-Item -LiteralPath $downloadDir -Recurse -Force -ErrorAction SilentlyContinue
        if ($download.ExitCode -ne 0) {
            $download.Lines | Select-Object -Last 5 | ForEach-Object { Write-Host "  $_" }
            Write-Host ('固定した版を取得できなかった (終了コード 0x{0:X8})。何も変えていない。ネットワークを確かめて打ち直す' -f $download.ExitCode)
            return 1
        }
    }

    # 入れ替える・入れ直すときは、古い版の pin を残さないよう先に外す (入れた後に足し直す)
    if (($state.Plan -in @('change', 'relink')) -and $state.Pinned) {
        $unpin = Invoke-Winget -Arguments @('pin', 'remove', '--id', $Tool.PackageId, '--exact', '--accept-source-agreements', '--disable-interactivity')
        if ($unpin.ExitCode -ne 0) {
            Write-Host ('winget pin remove が失敗した (終了コード 0x{0:X8})' -f $unpin.ExitCode)
            $hint = Get-WingetFailureHint -Tool $Tool -ExitCode $unpin.ExitCode
            if ($hint) { Write-Host $hint }
        }
    }
    $null = Invoke-PortableHook -Tool $Tool -Name 'BeforeWinget' -State $state
    foreach ($arguments in @(Get-WingetCommands -Tool $Tool -Plan $state.Plan -Version $Version)) {
        Write-Host "winget $($arguments -join ' ')"
        $result = Invoke-Winget -Arguments $arguments
        $result.Lines | Select-Object -Last 5 | ForEach-Object { Write-Host "  $_" }
        if ($result.ExitCode -ne 0) {
            Write-Host ('winget が失敗した (終了コード 0x{0:X8})' -f $result.ExitCode)
            $hint = Get-WingetFailureHint -Tool $Tool -ExitCode $result.ExitCode
            if ($hint) { Write-Host $hint }
            if ($arguments[0] -eq 'install') {
                Write-Host "install が落ちたので、$($Tool.Name) が入っていないことがある。ネットワークを確かめて $($Tool.Command) を打ち直す ($($Tool.Retry) でも入る)"
            }
            break
        }
    }
    # 入っていれば pin を足す (入れ替えた後は、上で外したので足し直しになる)
    $pins = Invoke-Winget -Arguments @('pin', 'list', '--id', $Tool.PackageId, '--exact', '--accept-source-agreements', '--disable-interactivity')
    if ((Find-PortableExe -Tool $Tool) -and -not (Test-WingetPinned -Lines $pins.Lines -PackageId $Tool.PackageId)) {
        $pin = Invoke-Winget -Arguments @('pin', 'add', '--id', $Tool.PackageId, '--exact', '--accept-source-agreements', '--disable-interactivity')
        if ($pin.ExitCode -eq 0) { Write-Host 'winget pin を足した (winget upgrade --all から外れる)' }
        else {
            Write-Host ('winget pin add が失敗した (終了コード 0x{0:X8})' -f $pin.ExitCode)
            # 昇格した会話でも pin を足すだけなら見張りは止めない。winget が断ったら直し方を添える
            $hint = Get-WingetFailureHint -Tool $Tool -ExitCode $pin.ExitCode
            if ($hint) { Write-Host $hint }
        }
    }
    $null = Invoke-PortableHook -Tool $Tool -Name 'AfterWinget' -State $state

    # ⑥ 揃ったかを読み直して確かめる
    Write-Host ''
    $after = Get-PortableState -Tool $Tool -Target $Version
    Write-PortableState -Tool $Tool -State $after -Target $Version
    if ((Get-PortableExitCode -Tool $Tool -State $after) -eq 0) {
        Write-Host '揃った'
        return 0
    }
    # 揃える手順で直す差は揃い、残っているのは人が直すことだけ
    if (-not (Test-PortableDrift -Tool $Tool -State $after)) { Write-Host "$($Tool.Synced) は揃った" }
    Write-PortableVerdict -Tool $Tool -State $after
    return 1
}

# 入口 (Install-<道具>.ps1) の本体。思わぬ例外は受け止めて終了コード 2 を返す。受け止めないと exit まで届かず、-Command から呼んだとき
# 外側の exit $LASTEXITCODE が中の winget の 0 を返して成功に見える
function Start-WingetPortable {
    param([hashtable]$Tool, [string]$Version, [switch]$Check, [switch]$IfMissing)
    try {
        return (Invoke-WingetPortable -Tool $Tool -Version $Version -Check:$Check -IfMissing:$IfMissing)
    } catch {
        Write-Host "エラーで止まった: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace
        return 2
    }
}
