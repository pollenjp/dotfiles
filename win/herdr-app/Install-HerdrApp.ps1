<#
.SYNOPSIS
Windows の herdr-app (herdr の desktop app) と herdr-core を、dotfiles が固定した版で、公式の install.ps1 と同じ置き場所に
入れる・外す。app と core の自己更新の取得元は dotfiles が書く手元のフィードに替え、固定した版にだけ上がるようにする。

.DESCRIPTION
dotfiles の win/herdr-app/Install-HerdrApp.ps1 を %USERPROFILE%\.config\powershell\ へ配り、
PowerShell では dotfiles.ps1 の Install-HerdrApp から呼ぶ (win/README.md の「herdr-app」)。

herdr-app は winget に無く、公式の入れ方は irm https://releases.herdr.dev/app/install.ps1 | iex だけ。遠くの script は流さず、
公式の install.ps1 (app と、それが呼ぶ core の install.ps1) と同じ置き場所・手順で入れる (写した中身の sha256 は
win/herdr-app/upstream-installers.txt。公式が変わると週 1 回の CI が知らせる)。

版は dotfiles が決める。版と sha256 は隣の herdr-releases.json (repo の nix/pkgs/herdr-core/releases.json を win/manifest.toml が
配る。Linux の home-manager が入れる herdr-core と、CI の check-herdr-app-version.sh も同じファイルを読む)。公開から 7 日たった
版を PR で上げる:

- 入れる: 固定した版を公式の版つき URL (releases.herdr.dev/app/<版>/…) から落とし、dotfiles の sha256 と、exe の Authenticode
  (Valid で、発行先が CN=herdr, O=herdr, L=Wilmington, S=Delaware, C=US、発行元が Microsoft ID Verified CS の CA) を確かめてから
  置く。入っている exe の署名が合わなければ、版によらず入れ直す (合わない exe は動かさない)
- 上がる先: release の app は 1 時間ごとに自分で新しい版を落とし、再起動か終了のときに差し替え、core も hc update で上げる
  (止める設定は無い)。どちらも取得元を環境変数 HERDR_RELEASES_URL から読むので、%LOCALAPPDATA%\dotfiles\herdr-releases に
  固定した版だけを載せたフィード (app/latest.json・core/latest.json・core/<版>/manifest.json。sha256 は dotfiles の値) を書き、
  ユーザーの環境変数を file:/// の URL でそこへ向ける。app と core はフィードに載った版にだけ上がり、sha256 が合わなければ断る。
  core の manifest には、Windows のほかに Linux (x86_64・aarch64) の target も載せる (herdr-app・hc が SSH の先の Linux の
  machine に core を入れるとき、同じ版のその target の build を取得元から落とすため)。
  フィードに install.ps1 は置かない (app の「core を入れ直す」は失敗し、core は dotfiles が入れる)
- 受け取った更新: 変数を置く前に開いた app は、公式から落とした版を置き場所の隣 (.new と受け取りの .new.json) に待たせ、閉じるか
  開き直すときに差し替える (変数も署名も見ない)。揃えるときは、固定した版で署名の合うもの、のほかは消す
- HERDR_RELEASES_URL は、公式の install.ps1 が「(tests)」と書くテスト用の変数で、将来読まれなくなりうる。そうなると app は
  公式の最新へ上がるので、-Check が「入っている版が固定と違う」で知らせる。版を上げる前には、新しい版のソースがこの変数を
  読むかを CI が確かめる

管理者は要らず、アプリと機能 (ARP) には載らない。下げはしない (入っている版が固定より新しいか版が読めず、署名は合うなら、
⚠ で知らせるだけ)。

公式と違えるところ: 版は latest.json ではなく固定した版で、sha256 は dotfiles の値。exe の署名を見る。HERDR_RELEASES_URL は
フィードに向ける (HC_VERSION・HC_INSTALL_DIR は読まない)。core を入れられなかったときは、app は入れたまま終了コード 1 で
知らせる。PATH の行は %VAR% を展開してから置き場所と比べる。curl.exe は、つながらない・転送が止まったときに打ち切る。

BOM 付きの UTF-8 で保存すること (Windows PowerShell 5.1 は BOM の無い UTF-8 を CP932 として読む)。

.PARAMETER Check
今の状態と固定どおりかを出すだけで、何も変えない (署名の合わない exe には --version も打たない)。揃っていれば終了コード 0、
揃っていないものがあれば 1、app が入っていなければ 3、確かめられない (引数や固定した版の書き方の誤り・思わぬ例外) なら 2。

.PARAMETER IfMissing
付けなくても同じ (揃える)。setup --update の bootstrap-windows-herdr-app.sh が、herdr と同じ形で呼ぶために受け取る。
揃えるときは、フィードと環境変数を固定どおりに書き、公式から受け取った更新を消し、入っていなければ入れ、固定より古いか署名が
合わなければ入れ直し (下げない)、足りない Herdr.lnk・PATH の行を足す。

.PARAMETER Uninstall
置いたもの (app と、その自己更新が隣に作るもの・Herdr.lnk・PATH の 2 行・core の置き場所・フィード・環境変数) を外す。設定
(~/.config/herdr-app) と core の状態・設定は残し、公式と違う置き場所 (winget など) のものには触らない。app か core が動いて
いれば、何も外さずに止める (core を止めると terminal も終わるので、止めるのは人)。人が打つときだけ使う (setup は打たない)。

.PARAMETER ReleasesFile
固定した版と sha256 を書いたファイル。既定は script の隣の herdr-releases.json (win/manifest.toml が repo の
nix/pkgs/herdr-core/releases.json を配る)。形は repo のファイルのとおり (app の版と windows-x86_64 の sha256、core の版・
generation と linux-aarch64・linux-x86_64・windows-x86_64 の sha256)。上げ方は win/README.md の「固定した版を上げる」。
#>
[CmdletBinding()]
param(
    [switch]$Check,
    [switch]$IfMissing,
    [switch]$Uninstall,
    [string]$ReleasesFile = ''
)

# ---------------------------------------------------------------------------
# 副作用の無い関数 (Install-HerdrApp.Tests.ps1 で確かめる)
# ---------------------------------------------------------------------------

# 公式と同じく、32 bit の PowerShell から呼ばれても OS の arch を見る (PROCESSOR_ARCHITEW6432 が先)
function Get-HerdrAppArchitecture {
    param([string]$Architecture, [string]$Architecture6432)
    if ($Architecture6432) { return $Architecture6432 }
    $Architecture
}

# core の target (フィードの core の manifest に載せる順。公式の manifest と同じく名前の順)。Windows のほかに Linux の 2 つを
# 載せるのは、herdr-app・hc が SSH の先の Linux の machine に core を入れるとき、同じ版のその target の build を落とすため
$HerdrAppCoreTargets = @('linux-aarch64', 'linux-x86_64', 'windows-x86_64')

# 固定した版のファイル (herdr-releases.json) の中身を、流れが使う形 (AppVersion・AppSha256・CoreVersion・CoreGeneration・
# CoreTargets (target → sha256。Windows の core は CoreTargets['windows-x86_64'])) にする。書き方の誤りは Test-HerdrAppPins が
# 見る。JSON でなければ例外
function ConvertFrom-HerdrAppReleases {
    param([string]$Text)
    $json = $Text | ConvertFrom-Json -ErrorAction Stop
    $get = {
        param($Object, [string]$Name)
        if ($null -eq $Object) { return $null }
        $prop = $Object.PSObject.Properties[$Name]
        if ($null -eq $prop) { return $null }
        $prop.Value
    }
    $app = & $get $json 'app'
    $core = & $get $json 'core'
    $coreSha = & $get $core 'sha256'
    $targets = [ordered]@{}
    foreach ($target in $HerdrAppCoreTargets) { $targets[$target] = & $get $coreSha $target }
    [pscustomobject]@{
        AppVersion     = & $get $app 'version'
        AppSha256      = & $get (& $get $app 'sha256') 'windows-x86_64'
        CoreVersion    = & $get $core 'version'
        CoreGeneration = & $get $core 'generation'
        CoreTargets    = $targets
    }
}

# 固定した版と sha256 の書き方が正しいか。誤りがあれば理由、無ければ $null (フィードの JSON にそのまま書くので、形を絞る。
# \A・\z と [0-9] にするのは、$ が末尾の改行の前でも合い、\d が全角などの数字にも合うため)
function Test-HerdrAppPins {
    param($Pins)
    foreach ($name in @('AppVersion', 'CoreVersion')) {
        if ("$($Pins.$name)" -cnotmatch '\A[0-9]+\.[0-9]+\.[0-9]+\z') { return "$name が版の形 (例 0.1.12) でない: $($Pins.$name)" }
    }
    if ("$($Pins.AppSha256)" -cnotmatch '\A[0-9a-f]{64}\z') { return "AppSha256 が 64 桁の小文字の hex でない: $($Pins.AppSha256)" }
    foreach ($target in $HerdrAppCoreTargets) {
        $sha = $Pins.CoreTargets[$target]
        if ("$sha" -cnotmatch '\A[0-9a-f]{64}\z') { return "CoreSha256 ($target) が 64 桁の小文字の hex でない: $sha" }
    }
    $generation = $Pins.CoreGeneration
    if (-not (($generation -is [int]) -or ($generation -is [long])) -or ($generation -lt 1)) { return "CoreGeneration が 1 以上の整数でない: $generation" }
    $null
}

# 公式の版つきの成果物の URL。app は windows-x86_64 の tar.gz。core は target ごと (Windows は zip、Linux は tar.gz)
function Get-HerdrAppArtifactUrl {
    param([string]$Releases, [string]$Kind, [string]$Version, [string]$Target = 'windows-x86_64')
    if ($Kind -eq 'app') { return "$Releases/app/$Version/herdr-app-windows-x86_64.tar.gz" }
    if ($Target -eq 'windows-x86_64') { return "$Releases/core/$Version/herdr-core-windows-x86_64.zip" }
    "$Releases/core/$Version/herdr-core-$Target.tar.gz"
}

# 公式と同じく、releases の素の URL (? も # も無い) にだけ ?src= を付ける (release の server のダウンロードの数の印。中身は同じ)
function Get-HerdrAppDownloadUrl {
    param([string]$Url, [string]$Releases, [string]$Src)
    $plain = $Url.StartsWith("$Releases/", [StringComparison]::Ordinal) -and ($Url.IndexOfAny([char[]]'?#') -lt 0)
    if ($plain) { return "$($Url)?src=$Src" }
    $Url
}

# 手元のフィードに置くファイル (Path はフィードからの相対パス、Text は中身)。app と core は、ここに載った版にだけ上がる。
# 中身は公式の manifest と同じ形で、成果物の URL は公式の版つき URL、sha256 は dotfiles の値。改行は LF、末尾に改行を 1 つ。
# core の targets は $HerdrAppCoreTargets の順 (Linux の machine に core を入れるときの target も載せる)
function Get-HerdrAppFeedFiles {
    param($Pins, [string]$Releases)
    $appUrl = Get-HerdrAppArtifactUrl -Releases $Releases -Kind 'app' -Version $Pins.AppVersion
    $app = @(
        '{'
        "  `"version`": `"$($Pins.AppVersion)`","
        '  "targets": {'
        '    "windows-x86_64": {'
        "      `"url`": `"$appUrl`","
        "      `"sha256`": `"$($Pins.AppSha256)`""
        '    }'
        '  }'
        '}'
        ''
    ) -join "`n"
    $coreTargets = @(
        for ($i = 0; $i -lt $HerdrAppCoreTargets.Count; $i++) {
            $target = $HerdrAppCoreTargets[$i]
            $url = Get-HerdrAppArtifactUrl -Releases $Releases -Kind 'core' -Version $Pins.CoreVersion -Target $target
            $close = if ($i -lt ($HerdrAppCoreTargets.Count - 1)) { '    },' } else { '    }' }
            "    `"$target`": {"
            "      `"url`": `"$url`","
            "      `"sha256`": `"$($Pins.CoreTargets[$target])`""
            $close
        }
    )
    $core = @(
        '{'
        "  `"version`": `"$($Pins.CoreVersion)`","
        "  `"generation`": $($Pins.CoreGeneration),"
        '  "targets": {'
        $coreTargets
        '  }'
        '}'
        ''
    ) -join "`n"
    [pscustomobject]@{ Path = 'app\latest.json'; Text = $app }
    [pscustomobject]@{ Path = 'core\latest.json'; Text = $core }
    # app を上げた後に app が打つ hc update --version <版> は、この版つきの manifest を読む
    [pscustomobject]@{ Path = "core\$($Pins.CoreVersion)\manifest.json"; Text = $core }
}

# フィードのディレクトリを指す file:/// の URL (空白や日本語は %XX にする。curl.exe が読む)
function Get-HerdrAppFeedUrl {
    param([string]$FeedDir)
    ([Uri]$FeedDir.TrimEnd('\')).AbsoluteUri
}

# 版を比べる (A が新しければ 1、同じなら 0、古ければ -1)。どちらかが版の形でなければ $null
function Compare-HerdrAppVersion {
    param([string]$A, [string]$B)
    $va = $null
    $vb = $null
    if (-not [version]::TryParse("$A", [ref]$va) -or -not [version]::TryParse("$B", [ref]$vb)) { return $null }
    [Math]::Sign($va.CompareTo($vb))
}

# herdr の exe の署名の発行先 (2026-11-10 に app 0.1.12〜0.1.14・core 0.1.17〜0.1.19 で見たもの)。変わったら入れずに止まる
# (win/README.md の「固定した版を上げる」)
$HerdrAppPublisher = 'CN=herdr, O=herdr, L=Wilmington, S=Delaware, C=US'

# exe の署名 (Status・Subject・Issuer) が herdr の正しい署名か。違えば理由、合えば $null。証明書は版ごとに替わる (期間は 3 日)
# ので指紋ではなく、発行先の全体 (上の値) と、発行元の形 (Microsoft ID Verified CS <3 字> CA <2 桁>。Azure Artifact Signing の
# 中間 CA。番号は版によって 03・04) で照らす。名前の一部だけを見ると、CN の重なり (CN=herdr, CN=evil) や、所在地の違う
# 同じ名前の組織の証明書を通してしまう
function Test-HerdrAppSignature {
    param($Signature)
    if ($null -eq $Signature) { return '署名を確かめられない (Get-AuthenticodeSignature が使えない)' }
    if ("$($Signature.Status)" -ne 'Valid') { return "署名が Valid でない ($($Signature.Status))" }
    if ("$($Signature.Subject)" -cne $HerdrAppPublisher) { return "発行先が herdr ($HerdrAppPublisher) でない ($($Signature.Subject))" }
    if ("$($Signature.Issuer)" -cnotmatch '\ACN=Microsoft ID Verified CS [A-Z]{3} CA [0-9]{2}, O=Microsoft Corporation, C=US\z') {
        return "発行元が Microsoft ID Verified CS の CA でない ($($Signature.Issuer))"
    }
    $null
}

# 署名を読めて、しかも合わないか (読めないだけなら $false)。合わない exe は動かさず (--version も打たない)、版によらず入れ直す
function Test-HerdrAppSignatureRejected {
    param($Signature)
    ($null -ne $Signature) -and [bool](Test-HerdrAppSignature -Signature $Signature)
}

# 自己更新の受け取り (<置き場所>.new.json。{"version":"0.1.13"}) の版。読めなければ $null
function Get-HerdrAppStagedVersion {
    param([string]$Text)
    if (-not $Text) { return $null }
    try {
        $json = $Text | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return $null
    }
    if ($null -eq $json) { return $null }
    $prop = $json.PSObject.Properties['version']
    if (($null -eq $prop) -or ($prop.Value -isnot [string])) { return $null }
    $prop.Value
}

# PATH の 1 つの要素が置き場所を指すか。前後の空白と " を落とし、%VAR% を展開し、末尾の \ を落としてから、
# 大文字小文字を区別せずに比べる
function Test-HerdrAppPathEntry {
    param([string]$Entry, [string]$Dir)
    $value = [Environment]::ExpandEnvironmentVariables($Entry.Trim().Trim('"')).TrimEnd('\')
    if (-not $value) { return $false }
    $value -ieq $Dir.TrimEnd('\')
}

# PATH の生の値 (; 区切り) に、置き場所を指す要素があるか
function Test-HerdrAppPathListed {
    param([string]$Raw, [string]$Dir)
    foreach ($entry in ($Raw -split ';')) {
        if (Test-HerdrAppPathEntry -Entry $entry -Dir $Dir) { return $true }
    }
    $false
}

# 置き場所を末尾に足した PATH の生の値 (公式と同じ形: 末尾の ; を落として ;<置き場所>)。既にあれば変えない
function Get-PathValueWithEntry {
    param([string]$Raw, [string]$Dir)
    if (Test-HerdrAppPathListed -Raw $Raw -Dir $Dir) { return $Raw }
    if ($Raw) { return "$($Raw.TrimEnd(';'));$Dir" }
    $Dir
}

# 置き場所を指す要素を外した PATH の生の値。ほかの要素 (%VAR% の書き方・空の要素・末尾の ;) はそのまま残す
function Get-PathValueWithoutEntry {
    param([string]$Raw, [string[]]$Dirs)
    $kept = foreach ($entry in ($Raw -split ';')) {
        $ours = $false
        foreach ($dir in $Dirs) {
            if (Test-HerdrAppPathEntry -Entry $entry -Dir $dir) { $ours = $true }
        }
        if (-not $ours) { $entry }
    }
    @($kept) -join ';'
}

# <名前> --version の出力 ("herdr-app 0.1.14"・"hc 0.1.19") から版を拾う。v 付き・後ろに続きのある形
# ("herdr-app v0.1.20 (abc123)") も版だけを拾う。無ければ $null
function Get-HerdrAppVersionFromOutput {
    param([string[]]$Lines, [string]$Name)
    foreach ($line in $Lines) {
        if ("$line" -match ('^\s*' + [regex]::Escape($Name) + '\s+v?([0-9]+\.[0-9]+\.[0-9]+)(?![0-9.])')) { return $Matches[1] }
    }
    $null
}

# app の置き場所と、自己更新が隣に作るもの (落として展開する .download・待っている .new と受け取りの .new.json・
# 入れ替えた古い .old)。-Uninstall はこれを外す
function Get-HerdrAppInstallPaths {
    param([string]$AppDir)
    $dir = $AppDir.TrimEnd('\')
    @($dir, "$dir.old", "$dir.new", "$dir.new.json", "$dir.download")
}

# 自己更新が受け取って待たせているもの (.new と受け取りの .new.json と、落とす途中の .download)。app は起動のときと終わる
# ときに、受け取りの版が動いている版より新しければ .new を置き場所と差し替える (取得元の変数も署名も見ない)
function Get-HerdrAppStagedPaths {
    param([string]$AppDir)
    $dir = $AppDir.TrimEnd('\')
    @("$dir.new", "$dir.new.json", "$dir.download")
}

# 動いているかを見るディレクトリ (app の置き場所と隣のディレクトリ、core の置き場所)
function Get-HerdrAppWatchDirs {
    param([string]$AppDir, [string]$CoreDir)
    $dir = $AppDir.TrimEnd('\')
    @($dir, "$dir.old", "$dir.new", "$dir.download", $CoreDir.TrimEnd('\'))
}

# プロセスの実行ファイルが、どれかのディレクトリの下にあるか (大文字小文字を区別しない)
function Test-HerdrAppProcessPath {
    param([string]$Path, [string[]]$Dirs)
    if (-not $Path) { return $false }
    foreach ($dir in $Dirs) {
        if ($Path.StartsWith($dir.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    $false
}

# ファイルの sha256 (小文字の hex)。公式と同じく .NET で求める (Get-FileHash は PowerShell 7 から 5.1 を起こすと落ちる)
function Get-HerdrAppFileSha256 {
    param([string]$Path)
    $stream = [IO.File]::OpenRead($Path)
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            -join ($sha.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') })
        } finally {
            $sha.Dispose()
        }
    } finally {
        $stream.Close()
    }
}

# Herdr.lnk が app を指すか。ours (TargetPath が置き場所の herdr-app.exe) / other (別の場所・読めない) / missing
function Get-HerdrAppLnkKind {
    param([bool]$Exists, [string]$Target, [string]$Exe)
    if (-not $Exists) { return 'missing' }
    if ($Target -and ($Target -ieq $Exe)) { return 'ours' }
    'other'
}

# PATH (; 区切り) を前から見て、$Name が最初に見つかったパスを返す。無ければ $null。
# $Exists はファイルがあるかを答える scriptblock (テストでは偽物を渡す)。
# 区切りは \ で組む (Linux の pwsh で流すテストでも同じ文字列になるよう、Join-Path は使わない)
function Resolve-HerdrAppOnPath {
    param([string]$PathValue, [string]$Name, [scriptblock]$Exists)
    foreach ($entry in ($PathValue -split ';')) {
        $dir = [Environment]::ExpandEnvironmentVariables($entry.Trim().Trim('"')).TrimEnd('\')
        if (-not $dir) { continue }
        $candidate = "$dir\$Name"
        if (& $Exists $candidate) { return $candidate }
    }
    $null
}

# 揃えるときにすること。App・Core は install (無い) / repair (署名が合わない。版によらない: 版は確かめていない exe が名乗る
# もので、herdr の署名の無い exe は下げない理由 (新しい版が書いた設定を守る) に当たらない) / upgrade (固定より古い) /
# newer (固定より新しい。下げない) / unknown (署名は合うか読めないが、版が読めない。新しい版かもしれないので入れ替えない) /
# none、Core はほかに elsewhere (公式と違う置き場所。触らない)。Staged は、受け取った更新 (.new) が固定した版で herdr の
# 署名を持つもの、のほかなら消すか。ほかは足す・書くか
function Get-HerdrAppInstallPlan {
    param($State, $Pins)
    $app = 'none'
    if (-not $State.AppExe) { $app = 'install' }
    elseif (Test-HerdrAppSignatureRejected -Signature $State.AppSignature) { $app = 'repair' }
    else {
        $cmp = Compare-HerdrAppVersion -A $State.AppVersion -B $Pins.AppVersion
        if ($null -eq $cmp) { $app = 'unknown' }
        elseif ($cmp -lt 0) { $app = 'upgrade' }
        elseif ($cmp -gt 0) { $app = 'newer' }
    }
    $core = 'none'
    if ($State.CoreExe) {
        if (Test-HerdrAppSignatureRejected -Signature $State.CoreSignature) { $core = 'repair' }
        else {
            $cmp = Compare-HerdrAppVersion -A $State.CoreVersion -B $Pins.CoreVersion
            if ($null -eq $cmp) { $core = 'unknown' }
            elseif ($cmp -lt 0) { $core = 'upgrade' }
        }
    } elseif ($State.CoreElsewhere) { $core = 'elsewhere' }
    else { $core = 'install' }
    $staged = @(@($State.StagedPaths) | Where-Object { $_ -and -not $_.EndsWith('.download', [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
    $stagedOk = ($State.StagedVersion -ceq $Pins.AppVersion) -and -not (Test-HerdrAppSignature -Signature $State.StagedSignature)
    [pscustomobject]@{
        App      = $app
        Core     = $core
        Staged   = ($staged -and -not $stagedOk)
        Lnk      = ($State.LnkKind -ne 'ours')
        AppPath  = (-not $State.AppPathListed)
        CorePath = ($State.CoreExe -and -not $State.CorePathListed)
        Feed     = (@($State.FeedDiff).Count -gt 0)
        Env      = ($State.EnvValue -cne $State.FeedUrl)
    }
}

# 揃っていないもの (無ければ空)。-Check の終了コードと状態の表が使う
function Get-HerdrAppProblems {
    param($State, $Pins)
    if (-not $State.AppExe) { return @('app') }
    $plan = Get-HerdrAppInstallPlan -State $State -Pins $Pins
    if ($plan.App -in @('upgrade', 'newer', 'unknown')) { 'app-version' }
    # 署名が合わない (repair) ときも、確かめられない (Get-AuthenticodeSignature が使えない) ときも揃っていないとする
    if (Test-HerdrAppSignature -Signature $State.AppSignature) { 'app-signature' }
    if ($plan.Staged) { 'staged' }
    if ($plan.Lnk) { 'lnk' }
    if ($plan.AppPath) { 'app-path' }
    if ($plan.Core -in @('install', 'upgrade')) { 'core' }
    if ($plan.Core -eq 'unknown') { 'core-version' }
    if ($State.CoreExe -and (Test-HerdrAppSignature -Signature $State.CoreSignature)) { 'core-signature' }
    if ($plan.CorePath) { 'core-path' }
    if ($plan.Feed) { 'feed' }
    if ($plan.Env) { 'env' }
}

# 終了コード。app が無ければ 3、揃っていれば 0、ほかは 1
function Get-HerdrAppExitCode {
    param($State, $Pins)
    if (-not $State.AppExe) { return 3 }
    if (@(Get-HerdrAppProblems -State $State -Pins $Pins).Count -eq 0) { return 0 }
    1
}

# 状態の表の 1 行。ラベルは全角 2 桁・半角 1 桁で数えて 16 桁にそろえる
function New-HerdrAppRow {
    param([string]$Key, [string]$Value, [bool]$Warn)
    $label = switch ($Key) {
        'Dir' { '置き場所        ' }
        'Version' { '入っている版    ' }
        'Signature' { '署名            ' }
        'Staged' { '受け取った更新  ' }
        'Menu' { 'スタートメニュー' }
        'Feed' { 'フィード        ' }
        'Env' { '環境変数        ' }
        default { 'ユーザーの PATH ' }
    }
    $prefix = if ($Warn) { '⚠ ' } else { '  ' }
    [pscustomobject]@{ Text = "$prefix$label : $Value"; Warn = $Warn }
}

# 署名の行の値 (発行元の CN を添える)
function Format-HerdrAppSignatureText {
    param($Signature)
    $reason = Test-HerdrAppSignature -Signature $Signature
    if ($reason) { return $reason }
    $issuer = if ("$($Signature.Issuer)" -cmatch '\ACN=([^,]+),') { $Matches[1] } else { $Signature.Issuer }
    "Valid (CN=herdr, O=herdr。発行元 $issuer)"
}

# 状態の表の行 (Text と、直すことがあるかの Warn)。直すことがある行だけ先頭に ⚠ を付け、ほかは 2 字下げる。
# app が無いときの Herdr.lnk・PATH・フィード・環境変数の行は ⚠ にしない (入れるときに作る)
function Format-HerdrAppState {
    param($State, $Pins, [string]$AppDir, [string]$CoreDir, [string]$FeedDir)
    $plan = Get-HerdrAppInstallPlan -State $State -Pins $Pins
    $appMissing = -not $State.AppExe
    $fix = -not $appMissing
    [pscustomobject]@{ Text = "herdr-app (公式と同じ置き場所。版は dotfiles が決める: $($Pins.AppVersion))"; Warn = $false }
    if ($appMissing) {
        New-HerdrAppRow -Key 'Dir' -Value "$AppDir → 入っていない ($($Pins.AppVersion) を入れる)" -Warn $true
    } else {
        New-HerdrAppRow -Key 'Dir' -Value $AppDir -Warn $false
        switch ($plan.App) {
            'upgrade' { New-HerdrAppRow -Key 'Version' -Value "$($State.AppVersion) → $($Pins.AppVersion) に上げる" -Warn $true }
            'newer' { New-HerdrAppRow -Key 'Version' -Value "$($State.AppVersion) (固定した版 $($Pins.AppVersion) より新しい。下げはしない)" -Warn $true }
            'unknown' { New-HerdrAppRow -Key 'Version' -Value '不明 (herdr-app.exe --version が読めない。入れ替えない)' -Warn $true }
            'repair' { New-HerdrAppRow -Key 'Version' -Value '確かめていない (署名の合わない exe は動かさない)' -Warn $false }
            default { New-HerdrAppRow -Key 'Version' -Value "$($State.AppVersion) (固定した版)" -Warn $false }
        }
        $sigText = Format-HerdrAppSignatureText -Signature $State.AppSignature
        $sigBad = [bool](Test-HerdrAppSignature -Signature $State.AppSignature)
        if ($plan.App -eq 'repair') { $sigText += " → $($Pins.AppVersion) を入れ直す" }
        New-HerdrAppRow -Key 'Signature' -Value $sigText -Warn $sigBad
    }
    if ($plan.Staged) {
        $staged = if ($State.StagedVersion) { $State.StagedVersion } else { '不明 (受け取りが読めない)' }
        $why = if ($State.StagedVersion -cne $Pins.AppVersion) { '固定した版でない' } else { Test-HerdrAppSignature -Signature $State.StagedSignature }
        New-HerdrAppRow -Key 'Staged' -Value "$staged ($why。app を閉じるか開き直すと、これに差し替わる) → 消す" -Warn $true
    }
    switch ($State.LnkKind) {
        'ours' { New-HerdrAppRow -Key 'Menu' -Value 'Herdr.lnk' -Warn $false }
        'other' {
            $target = if ($State.LnkTarget) { $State.LnkTarget } else { '読めない' }
            $tail = if ($fix) { ' → 作り直す' } else { '' }
            New-HerdrAppRow -Key 'Menu' -Value "Herdr.lnk が別の場所を指している ($target)$tail" -Warn $fix
        }
        default {
            $tail = if ($fix) { ' → 作る' } else { '' }
            New-HerdrAppRow -Key 'Menu' -Value "Herdr.lnk が無い$tail" -Warn $fix
        }
    }
    $appPath = if ($State.AppPathListed) { 'あり' } elseif ($fix) { '無し → 足す' } else { '無し' }
    New-HerdrAppRow -Key 'Path' -Value $appPath -Warn ($fix -and -not $State.AppPathListed)

    [pscustomobject]@{ Text = "herdr-core (無ければ入れる。版は dotfiles が決めた $($Pins.CoreVersion) 以上)"; Warn = $false }
    if ($State.CoreExe) {
        New-HerdrAppRow -Key 'Dir' -Value $CoreDir -Warn $false
        switch ($plan.Core) {
            'upgrade' { New-HerdrAppRow -Key 'Version' -Value "$($State.CoreVersion) → $($Pins.CoreVersion) に上げる" -Warn $true }
            'unknown' { New-HerdrAppRow -Key 'Version' -Value '不明 (herdr-core.exe --version が読めない。入れ替えない)' -Warn $true }
            'repair' { New-HerdrAppRow -Key 'Version' -Value '確かめていない (署名の合わない exe は動かさない)' -Warn $false }
            default { New-HerdrAppRow -Key 'Version' -Value "$($State.CoreVersion) (固定した版 $($Pins.CoreVersion) 以上)" -Warn $false }
        }
        $sigText = Format-HerdrAppSignatureText -Signature $State.CoreSignature
        if ($plan.Core -eq 'repair') { $sigText += " → $($Pins.CoreVersion) を入れ直す" }
        New-HerdrAppRow -Key 'Signature' -Value $sigText -Warn ([bool](Test-HerdrAppSignature -Signature $State.CoreSignature))
        $corePath = if ($State.CorePathListed) { 'あり' } else { '無し → 足す' }
        New-HerdrAppRow -Key 'Path' -Value $corePath -Warn (-not $State.CorePathListed)
    } elseif ($State.CoreElsewhere) {
        New-HerdrAppRow -Key 'Dir' -Value "公式の置き場所には無い。PATH の $($State.CoreElsewhere) を使う" -Warn $false
    } else {
        New-HerdrAppRow -Key 'Dir' -Value "$CoreDir → 入っていない ($($Pins.CoreVersion) を入れる)" -Warn $true
    }

    [pscustomobject]@{ Text = '更新の取得元 (HERDR_RELEASES_URL。app と core は、ここに載った版にだけ上がる)'; Warn = $false }
    if ($plan.Feed) {
        $tail = if ($fix) { ' → 書く' } else { '' }
        New-HerdrAppRow -Key 'Feed' -Value "$FeedDir (無い・固定と違う: $(@($State.FeedDiff) -join '・'))$tail" -Warn $fix
    } else {
        New-HerdrAppRow -Key 'Feed' -Value "$FeedDir (app $($Pins.AppVersion)・core $($Pins.CoreVersion))" -Warn $false
    }
    if (-not $plan.Env) {
        New-HerdrAppRow -Key 'Env' -Value $State.FeedUrl -Warn $false
    } else {
        $now = if ($State.EnvValue) { "$($State.EnvValue) (フィードを指していない)" } else { '無し (公式の releases.herdr.dev から上がる)' }
        $tail = if ($fix) { " → $($State.FeedUrl) にする" } else { '' }
        New-HerdrAppRow -Key 'Env' -Value "$now$tail" -Warn $fix
    }

    if ($plan.App -eq 'newer') {
        [pscustomobject]@{ Text = '※ 入っている app は固定した版より新しい (署名は herdr のもの)。取得元の変数を置く前に上がったか、変数が効いていない (公式から上がった)。dotfiles は下げない。固定した版が追いつくのを待つか (7 日たった版を CI が知らせる)、Install-HerdrApp -Uninstall の後に入れ直す'; Warn = $false }
    }
    if (($plan.App -eq 'unknown') -or ($plan.Core -eq 'unknown')) {
        [pscustomobject]@{ Text = '※ 版が読めない exe は、新しい版かもしれないので入れ替えない (下げないため)。直すなら、app の窓を閉じて herdr-core.exe server stop を打ち、Install-HerdrApp -Uninstall の後に入れ直す'; Warn = $false }
    }
    if ($plan.Staged) {
        [pscustomobject]@{ Text = '※ 受け取った更新は、取得元の変数を置く前に開いた app が公式から落としたもの (変数が効いていなければ、置いた後でも)。揃えると消すので、消してから app を閉じて開き直す (消す前に閉じると差し替わる)'; Warn = $false }
    }
    if ((-not $State.CoreExe) -and $State.CoreElsewhere) {
        [pscustomobject]@{ Text = '※ herdr-core は公式と違う置き場所にある (winget など)。dotfiles は入れず、-Uninstall も触らない'; Warn = $false }
    }
}

# -Uninstall で外すもの (Kind = remove: ファイルかディレクトリを消す / path: ユーザーの PATH の行を外す / env: ユーザーの
# 環境変数 HERDR_RELEASES_URL を消す)。Herdr.lnk は app を指すときだけ、core は公式の置き場所にあるときだけ、環境変数は
# フィードを指すときだけ。公式と違う置き場所のものは入れない
function Get-HerdrAppUninstallPlan {
    param($State, [string]$AppDir, [string]$CoreDir, [string]$Menu, [string]$FeedDir)
    foreach ($path in @($State.AppPathsPresent)) {
        if ($path) { [pscustomobject]@{ Kind = 'remove'; Target = $path } }
    }
    if ($State.LnkKind -eq 'ours') { [pscustomobject]@{ Kind = 'remove'; Target = $Menu } }
    if ($State.AppPathListed) { [pscustomobject]@{ Kind = 'path'; Target = $AppDir } }
    if ($State.CoreDirExists) { [pscustomobject]@{ Kind = 'remove'; Target = $CoreDir } }
    if ($State.CorePathListed) { [pscustomobject]@{ Kind = 'path'; Target = $CoreDir } }
    if ($State.FeedDirExists) { [pscustomobject]@{ Kind = 'remove'; Target = $FeedDir } }
    if ($State.EnvValue -and ($State.EnvValue -ieq $State.FeedUrl)) { [pscustomobject]@{ Kind = 'env'; Target = 'HERDR_RELEASES_URL' } }
}

# -Uninstall が残したもの (あるものだけ)。$Exists はあるかを答える scriptblock (テストでは偽物を渡す)
function Format-HerdrAppKept {
    param($State, $Locations, [scriptblock]$Exists)
    if (& $Exists $Locations.AppHome) { "残した: $($Locations.AppHome) (設定と mod)" }
    if (& $Exists $Locations.CoreState) { "残した: $($Locations.CoreState) (herdr-core の状態)" }
    if (& $Exists $Locations.CoreConfig) { "残した: $($Locations.CoreConfig) (herdr-core の設定)" }
    if ($State.LnkKind -eq 'other') {
        $target = if ($State.LnkTarget) { $State.LnkTarget } else { '読めない場所' }
        "残した: $($Locations.Menu) ($target を指している)"
    }
    if ((-not $State.CoreExe) -and $State.CoreElsewhere) { "残した: $($State.CoreElsewhere) (公式と違う置き場所の herdr-core)" }
    if ($State.EnvValue -and ($State.EnvValue -ine $State.FeedUrl)) { "残した: ユーザーの環境変数 HERDR_RELEASES_URL = $($State.EnvValue) (dotfiles のフィードを指していない)" }
}

# 動いているプロセスの行と、止め方。core を止めると、その中の terminal も終わる
function Format-HerdrAppBusy {
    param([object[]]$Processes, [string]$CoreDir)
    $list = @($Processes)
    # パスが読めないものは名前で分ける (Test-HerdrAppBusyEntry と同じ)
    $core = @($list | Where-Object {
            if ($_.Path) { Test-HerdrAppProcessPath -Path $_.Path -Dirs @($CoreDir) } else { $_.Name -in @('herdr-core.exe', 'hc.exe') }
        })
    "herdr-app か herdr-core が動いている ($($list.Count) 個) ので、何も外していない。止めてから打ち直す:"
    if ($core.Count -lt $list.Count) { '  app: 窓を閉じる' }
    if ($core.Count -gt 0) {
        "  core: & '$($CoreDir.TrimEnd('\'))\herdr-core.exe' server stop を打つ (core の中の terminal と、そこで動いているものも終わる)"
    }
    foreach ($p in $list) {
        $path = if ($p.Path) { $p.Path } else { "$($p.Name) (パスが読めないので名前で数えた。管理者で動いているなど)" }
        "  $($p.Id)  $path  $($p.CommandLine)"
    }
}

# 動いているプロセスに数えるか。実行ファイルのパスが読めれば置き場所の下か、読めなければ (管理者で動いている、など)
# 名前が herdr-app・herdr-core・hc か (大文字小文字を区別しない)。OpenConsole.exe は Windows Terminal も持つので名前では数えない
function Test-HerdrAppBusyEntry {
    param([string]$Path, [string]$Name, [string[]]$Dirs)
    if ($Path) { return (Test-HerdrAppProcessPath -Path $Path -Dirs $Dirs) }
    $Name -in @('herdr-app.exe', 'herdr-core.exe', 'hc.exe')
}

# ---------------------------------------------------------------------------
# Windows に触る関数 (実機で -Check・本番・-Uninstall を打って確かめる)
# ---------------------------------------------------------------------------

# 置き場所 (app と core は公式と同じ。フィードは dotfiles の置き場所)。データの置き場所は、-Uninstall で「残した」と出す
# ためだけに使う
function Get-HerdrAppLocations {
    $programs = Join-Path $env:LOCALAPPDATA 'Programs'
    $appHome = if ($env:HERDR_APP_HOME) { $env:HERDR_APP_HOME }
    elseif ($env:XDG_CONFIG_HOME) { Join-Path $env:XDG_CONFIG_HOME 'herdr-app' }
    else { Join-Path $env:USERPROFILE '.config\herdr-app' }
    $stateHome = if ($env:XDG_STATE_HOME) { $env:XDG_STATE_HOME } else { $env:LOCALAPPDATA }
    $configHome = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { $env:APPDATA }
    [pscustomobject]@{
        AppDir     = Join-Path $programs 'herdr-app'
        CoreDir    = Join-Path $programs 'herdr-core'
        Menu       = Join-Path ([Environment]::GetFolderPath('Programs')) 'Herdr.lnk'
        FeedDir    = Join-Path $env:LOCALAPPDATA 'dotfiles\herdr-releases'
        AppHome    = $appHome
        CoreState  = Join-Path $stateHome 'herdr-core'
        CoreConfig = Join-Path $configHome 'herdr-core'
    }
}

# 外部コマンドを打ち、出力の行と終了コードを返す。5.1 では Stop のままだと、外部コマンドの stderr の 1 行目で止まる
function Invoke-HerdrAppNative {
    param([string]$FilePath, [string[]]$Arguments)
    $ErrorActionPreference = 'Continue'
    $lines = @(& $FilePath @Arguments 2>&1 | ForEach-Object { "$_" })
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Lines = $lines }
}

# <exe> --version を打って版を読む。窓を開く版の app にあたっても止まらないよう打ち切る。読めなければ $null
function Get-HerdrAppExeVersion {
    param([string]$Exe, [string]$Name, [int]$TimeoutMs = 10000)
    if (-not (Test-Path -LiteralPath $Exe -PathType Leaf)) { return $null }
    try {
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = $Exe
        $info.Arguments = '--version'
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $process = [Diagnostics.Process]::Start($info)
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $null = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMs)) {
            try { $process.Kill() } catch { $null = $_ }
            return $null
        }
        Get-HerdrAppVersionFromOutput -Lines ($stdout.Result -split "`r?`n") -Name $Name
    } catch {
        $null
    }
}

# exe の Authenticode の署名 (Status・Subject・Issuer)。読めなければ $null。PowerShell 7 から起こした Windows PowerShell 5.1 など
# で、PSModulePath が 7 の場所を指していると Get-AuthenticodeSignature のモジュールを読めないので、5.1 の場所から読み直す
function Get-HerdrAppSignature {
    param([string]$Path)
    $sig = $null
    try {
        $sig = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
    } catch {
        try {
            Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Security\Microsoft.PowerShell.Security.psd1') -ErrorAction Stop
            $sig = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
        } catch {
            return $null
        }
    }
    $cert = $sig.SignerCertificate
    $subject = if ($cert) { $cert.Subject } else { $null }
    $issuer = if ($cert) { $cert.Issuer } else { $null }
    [pscustomobject]@{ Status = "$($sig.Status)"; Subject = $subject; Issuer = $issuer }
}

# ユーザーの PATH の生の値 (%VAR% を展開しない)。無ければ ''
function Get-HerdrAppUserPathRaw {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $false)
    if ($null -eq $key) { return '' }
    try {
        [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    } finally {
        $key.Close()
    }
}

# ユーザーの PATH を書き直す (公式と同じく、値の型 (REG_EXPAND_SZ など) を保つ)。$Flag の user 変数を書いて消し、
# 動いているプログラムに環境変数が変わったことを知らせる
function Set-HerdrAppUserPathRaw {
    param([string]$Value, [string]$Flag)
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    try {
        $kind = if ($key.GetValueNames() -contains 'Path') { $key.GetValueKind('Path') } else { [Microsoft.Win32.RegistryValueKind]::ExpandString }
        $key.SetValue('Path', $Value, $kind)
    } finally {
        $key.Close()
    }
    [Environment]::SetEnvironmentVariable($Flag, '1', 'User')
    [Environment]::SetEnvironmentVariable($Flag, $null, 'User')
}

# 置き場所をユーザーの PATH の末尾に足す (無いときだけ)。今のプロセスの PATH にも足す (公式と同じ。打った PowerShell で
# すぐ引ける)
function Add-HerdrAppUserPath {
    param([string]$Dir, [string]$Flag)
    $raw = Get-HerdrAppUserPathRaw
    if (-not (Test-HerdrAppPathListed -Raw $raw -Dir $Dir)) {
        Set-HerdrAppUserPathRaw -Value (Get-PathValueWithEntry -Raw $raw -Dir $Dir) -Flag $Flag
        Write-Host "ユーザーの PATH に $Dir を足した (新しく開くシェルから効く)"
    }
    if (-not (Test-HerdrAppPathListed -Raw $env:Path -Dir $Dir)) { $env:Path = Get-PathValueWithEntry -Raw $env:Path -Dir $Dir }
}

# 置き場所を指す行をユーザーの PATH から外す。今のプロセスの PATH からも外す
function Remove-HerdrAppUserPath {
    param([string[]]$Dirs)
    $raw = Get-HerdrAppUserPathRaw
    $new = Get-PathValueWithoutEntry -Raw $raw -Dirs $Dirs
    if ($new -cne $raw) { Set-HerdrAppUserPathRaw -Value $new -Flag 'HERDR_INSTALLING' }
    $env:Path = Get-PathValueWithoutEntry -Raw $env:Path -Dirs $Dirs
}

# ユーザーの環境変数 HERDR_RELEASES_URL。無ければ $null
function Get-HerdrAppEnvValue {
    [Environment]::GetEnvironmentVariable('HERDR_RELEASES_URL', 'User')
}

# ユーザーの環境変数 HERDR_RELEASES_URL を置く (動いている窓に知らせる)。今のプロセスにも置く (この後に打つ
# herdr-core.exe update が立て直す core が受け継ぐ)。置く前に開いた app は、閉じて開き直すまで公式の取得元を見る
function Set-HerdrAppEnvValue {
    param([string]$Value)
    [Environment]::SetEnvironmentVariable('HERDR_RELEASES_URL', $Value, 'User')
    $env:HERDR_RELEASES_URL = $Value
    Write-Host "ユーザーの環境変数 HERDR_RELEASES_URL を $Value にした (このあと開く app と core から効く。開いている app は閉じて開き直す)"
}

# ユーザーの環境変数 HERDR_RELEASES_URL を消す。今のプロセスからも消す
function Remove-HerdrAppEnvValue {
    [Environment]::SetEnvironmentVariable('HERDR_RELEASES_URL', $null, 'User')
    Remove-Item -LiteralPath 'Env:HERDR_RELEASES_URL' -ErrorAction SilentlyContinue
}

# フィードのファイルが固定どおりか。無い・中身が違うファイルと、固定に無いファイル (前の版の manifest など) を、フィードからの
# 相対パス (区切りは \) で返す。揃っていれば空。中身はバイトで比べる (BOM や CRLF が付いても違うとする)
function Get-HerdrAppFeedDiff {
    param([string]$FeedDir, $Pins, [string]$Releases)
    $expected = @(Get-HerdrAppFeedFiles -Pins $Pins -Releases $Releases)
    $utf8 = New-Object Text.UTF8Encoding $false
    foreach ($file in $expected) {
        $path = Join-Path $FeedDir $file.Path
        $have = $null
        if (Test-Path -LiteralPath $path -PathType Leaf) { $have = [Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) }
        if ($have -cne [Convert]::ToBase64String($utf8.GetBytes($file.Text))) { $file.Path }
    }
    if (-not (Test-Path -LiteralPath $FeedDir -PathType Container)) { return }
    $root = (Get-Item -LiteralPath $FeedDir -Force).FullName.TrimEnd('\', '/')
    $names = @($expected | ForEach-Object { $_.Path })
    foreach ($item in @(Get-ChildItem -LiteralPath $FeedDir -Recurse -File -Force)) {
        # Linux の pwsh (テスト) では区切りが / になるので \ にそろえる
        $rel = $item.FullName.Substring($root.Length + 1).Replace('/', '\')
        if ($rel -notin $names) { $rel }
    }
}

# フィードを固定どおりに書く。固定に無いファイル (前の版の manifest など) は消す。BOM の無い UTF-8 で書く
function Sync-HerdrAppFeed {
    param([string]$FeedDir, $Pins, [string]$Releases)
    $files = @(Get-HerdrAppFeedFiles -Pins $Pins -Releases $Releases)
    $utf8 = New-Object Text.UTF8Encoding $false
    $keep = @{}
    foreach ($file in $files) {
        $path = Join-Path $FeedDir $file.Path
        New-Item -ItemType Directory -Force (Split-Path $path) | Out-Null
        [IO.File]::WriteAllText($path, $file.Text, $utf8)
        $keep[$path.ToLowerInvariant()] = $true
    }
    foreach ($item in @(Get-ChildItem -LiteralPath $FeedDir -Recurse -File -Force)) {
        if (-not $keep.ContainsKey($item.FullName.ToLowerInvariant())) { Remove-Item -LiteralPath $item.FullName -Force }
    }
    foreach ($dir in @(Get-ChildItem -LiteralPath $FeedDir -Recurse -Directory -Force | Sort-Object { $_.FullName.Length } -Descending)) {
        if (-not (Get-ChildItem -LiteralPath $dir.FullName -Force)) { Remove-Item -LiteralPath $dir.FullName -Force }
    }
    Write-Host "フィード $FeedDir を固定どおりに書いた (app $($Pins.AppVersion)・core $($Pins.CoreVersion))"
}

# Herdr.lnk の TargetPath。無ければ $null、読めなければ ''
function Get-HerdrAppShortcutTarget {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        [string](New-Object -ComObject WScript.Shell).CreateShortcut($Path).TargetPath
    } catch {
        ''
    }
}

# スタートメニューに Herdr.lnk を作る (公式と同じ中身。あれば上書きする)
function New-HerdrAppShortcut {
    param([string]$Path, [string]$Exe)
    $link = (New-Object -ComObject WScript.Shell).CreateShortcut($Path)
    $link.TargetPath = $Exe
    $link.WorkingDirectory = $env:USERPROFILE
    $link.Description = 'Terminals and coding agents that keep running'
    $link.Save()
    Write-Host "スタートメニューに $Path を作った"
}

# これから開くシェルが使う PATH (マシン → ユーザーの順)。今のプロセスの PATH は古いことがある
function Get-HerdrAppMachineUserPath {
    @([Environment]::GetEnvironmentVariable('Path', 'Machine'), [Environment]::GetEnvironmentVariable('Path', 'User')) -join ';'
}

# 今の状態を読む (何も変えない。ネットワークも使わない。管理者は要らない)
function Get-HerdrAppState {
    param($Locations, $Pins, [string]$Releases)
    $appExePath = Join-Path $Locations.AppDir 'herdr-app.exe'
    $coreExePath = Join-Path $Locations.CoreDir 'herdr-core.exe'
    $appExe = Test-Path -LiteralPath $appExePath -PathType Leaf
    $coreExe = Test-Path -LiteralPath $coreExePath -PathType Leaf
    $lnkTarget = Get-HerdrAppShortcutTarget -Path $Locations.Menu
    $raw = Get-HerdrAppUserPathRaw
    $elsewhere = $null
    if (-not $coreExe) {
        $found = Resolve-HerdrAppOnPath -PathValue (Get-HerdrAppMachineUserPath) -Name 'herdr-core.exe' -Exists { param($p) Test-Path -LiteralPath $p -PathType Leaf }
        if ($found -and -not (Test-HerdrAppProcessPath -Path $found -Dirs @($Locations.CoreDir))) { $elsewhere = $found }
    }
    # 署名を先に見て、合わない exe には --version を打たない (確かめていない exe を動かさない)
    $appSig = if ($appExe) { Get-HerdrAppSignature -Path $appExePath } else { $null }
    $coreSig = if ($coreExe) { Get-HerdrAppSignature -Path $coreExePath } else { $null }
    $appDir = $Locations.AppDir.TrimEnd('\')
    $stagedExe = "$appDir.new\herdr-app.exe"
    $receipt = "$appDir.new.json"
    [pscustomobject]@{
        AppExe          = $appExe
        AppVersion      = $(if ($appExe -and -not (Test-HerdrAppSignatureRejected -Signature $appSig)) { Get-HerdrAppExeVersion -Exe $appExePath -Name 'herdr-app' } else { $null })
        AppSignature    = $appSig
        AppPathsPresent = @(Get-HerdrAppInstallPaths -AppDir $Locations.AppDir | Where-Object { Test-Path -LiteralPath $_ })
        StagedPaths     = @(Get-HerdrAppStagedPaths -AppDir $Locations.AppDir | Where-Object { Test-Path -LiteralPath $_ })
        StagedVersion   = $(if (Test-Path -LiteralPath $receipt -PathType Leaf) { Get-HerdrAppStagedVersion -Text ([IO.File]::ReadAllText($receipt)) } else { $null })
        StagedSignature = $(if (Test-Path -LiteralPath $stagedExe -PathType Leaf) { Get-HerdrAppSignature -Path $stagedExe } else { $null })
        LnkKind         = Get-HerdrAppLnkKind -Exists ($null -ne $lnkTarget) -Target $lnkTarget -Exe $appExePath
        LnkTarget       = $lnkTarget
        AppPathListed   = Test-HerdrAppPathListed -Raw $raw -Dir $Locations.AppDir
        CoreExe         = $coreExe
        CoreDirExists   = Test-Path -LiteralPath $Locations.CoreDir -PathType Container
        CoreVersion     = $(if ($coreExe -and -not (Test-HerdrAppSignatureRejected -Signature $coreSig)) { Get-HerdrAppExeVersion -Exe $coreExePath -Name 'hc' } else { $null })
        CoreSignature   = $coreSig
        CorePathListed  = Test-HerdrAppPathListed -Raw $raw -Dir $Locations.CoreDir
        CoreElsewhere   = $elsewhere
        FeedDirExists   = Test-Path -LiteralPath $Locations.FeedDir -PathType Container
        FeedDiff        = @(Get-HerdrAppFeedDiff -FeedDir $Locations.FeedDir -Pins $Pins -Releases $Releases)
        FeedUrl         = Get-HerdrAppFeedUrl -FeedDir $Locations.FeedDir
        EnvValue        = Get-HerdrAppEnvValue
    }
}

# 状態の表を出す。直すことがある行 (⚠) は黄色にする
function Write-HerdrAppState {
    param($State, $Pins, $Locations)
    foreach ($row in (Format-HerdrAppState -State $State -Pins $Pins -AppDir $Locations.AppDir -CoreDir $Locations.CoreDir -FeedDir $Locations.FeedDir)) {
        if ($row.Warn) { Write-Host $row.Text -ForegroundColor Yellow } else { Write-Host $row.Text }
    }
}

# 置き場所の下から起動して動いているプロセス (app・core・core の conpty の OpenConsole.exe) と、実行ファイルのパスが
# 読めない herdr-app・herdr-core・hc。Win32_Process で見る (Process.Path は、32 bit の PowerShell から見た 64 bit の
# プロセスや、管理者で動くプロセスでは読めない)。読めなければ例外 (何も外さずに止まる)
function Get-HerdrAppBusyProcess {
    param([string[]]$Dirs)
    foreach ($p in @(Get-CimInstance Win32_Process -ErrorAction Stop)) {
        if (Test-HerdrAppBusyEntry -Path $p.ExecutablePath -Name $p.Name -Dirs $Dirs) {
            [pscustomobject]@{ Id = $p.ProcessId; Name = $p.Name; Path = $p.ExecutablePath; CommandLine = $p.CommandLine }
        }
    }
}

# ファイルかディレクトリを中身ごと消す。リンク (junction・symlink) はリンクだけを消し、先はたどらない
# (Remove-Item -Recurse がリンクの先をたどるかは PowerShell の版で違い、古い版は先の中身まで消す。公式の置き場所の外を
# 消さないよう、たどらないことをここで決める)。読み取り専用のファイルも消す
function Remove-HerdrAppTree {
    param([IO.FileSystemInfo]$Item)
    $isLink = [bool]($Item.Attributes -band [IO.FileAttributes]::ReparsePoint)
    if (($Item -is [IO.DirectoryInfo]) -and -not $isLink) {
        foreach ($child in @($Item.EnumerateFileSystemInfos())) { Remove-HerdrAppTree -Item $child }
    }
    if ($Item.Attributes -band [IO.FileAttributes]::ReadOnly) {
        $Item.Attributes = $Item.Attributes -band (-bnot [IO.FileAttributes]::ReadOnly)
    }
    $Item.Delete()
}

# ファイルかディレクトリを消す (リンクの先はたどらない)。消せなければ理由を出して $false
function Remove-HerdrAppItem {
    param([string]$Path)
    try {
        Remove-HerdrAppTree -Item (Get-Item -LiteralPath $Path -Force -ErrorAction Stop)
        $true
    } catch {
        Write-Host "  $($_.Exception.Message)"
        $false
    }
}

# フィードの親 (%LOCALAPPDATA%\dotfiles) が空になっていれば消す
function Remove-HerdrAppEmptyParent {
    param([string]$Dir)
    $parent = Split-Path $Dir
    if ((Test-Path -LiteralPath $parent -PathType Container) -and -not (Get-ChildItem -LiteralPath $parent -Force)) {
        Remove-Item -LiteralPath $parent -Force -ErrorAction SilentlyContinue
    }
}

# 落として入れられるか (公式と同じ条件: x64・curl.exe・System32\tar.exe)。入れられなければ理由、入れられれば $null
function Get-HerdrAppDownloadBlocker {
    param([string]$Tar)
    $arch = Get-HerdrAppArchitecture -Architecture $env:PROCESSOR_ARCHITECTURE -Architecture6432 $env:PROCESSOR_ARCHITEW6432
    if ($arch -ne 'AMD64') { return "herdr-app と herdr-core の Windows 版は x64 だけ ($arch の版は無い)" }
    if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue) -or -not (Test-Path -LiteralPath $Tar -PathType Leaf)) {
        return 'curl.exe と System32\tar.exe が要る (Windows 10 1803 以降)'
    }
    $null
}

# 公式と同じく curl.exe で落とす。落とせなければ例外。公式と違い、つながらない (30 秒)・転送が止まった (60 秒のあいだ
# 1 KB/s を下回る) ときは打ち切る (setup の中で、bootstrap の打ち切りの 600 秒まで止まらないよう)
function Save-HerdrAppDownload {
    param([string]$Url, [string]$OutFile)
    $result = Invoke-HerdrAppNative -FilePath 'curl.exe' -Arguments @('-fsSL', '--connect-timeout', '30', '--speed-limit', '1024', '--speed-time', '60', $Url, '-o', $OutFile)
    if ($result.ExitCode -ne 0) { throw "$Url を落とせない (curl.exe の終了コード $($result.ExitCode)) $($result.Lines -join ' ')" }
}

# 落としたファイルの sha256 を dotfiles の値と比べる。違えば例外
function Assert-HerdrAppSha256 {
    param([string]$Path, [string]$Expected)
    $got = Get-HerdrAppFileSha256 -Path $Path
    if ($got -ne $Expected) { throw "落としたファイルの sha256 が $got で、dotfiles の値 $Expected と違う。入れない (取得元で差し替えられたかもしれない)" }
}

# 落とした exe が、herdr の署名と固定した版を持つか。違えば例外
function Assert-HerdrAppExe {
    param([string]$Exe, [string]$Name, [string]$Version)
    $reason = Test-HerdrAppSignature -Signature (Get-HerdrAppSignature -Path $Exe)
    if ($reason) { throw "落とした $(Split-Path $Exe -Leaf) の $reason。入れない" }
    $got = Get-HerdrAppExeVersion -Exe $Exe -Name $Name
    if ($got -cne $Version) { throw "落とした $(Split-Path $Exe -Leaf) の版が $got で、固定した版 $Version と違う。入れない" }
}

# app を固定した版で入れる (上げる・入れ直すも同じ): 版つき URL の tar.gz を落とす → dotfiles の sha256 → System32\tar.exe で
# 展開 → 署名と版を確かめる → .old を経て置く (公式と同じ。動いている app のフォルダは rename できるが消せない)
function Install-HerdrAppPackage {
    param($Pins, [string]$AppDir, [string]$Releases, [string]$Tar)
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "install-herdr-app-$PID"
    New-Item -ItemType Directory -Force $tmp | Out-Null
    try {
        $url = Get-HerdrAppArtifactUrl -Releases $Releases -Kind 'app' -Version $Pins.AppVersion
        Write-Host "herdr-app $($Pins.AppVersion) を落とす: $url"
        $archive = Join-Path $tmp 'app.tar.gz'
        $src = if (Test-Path -LiteralPath $AppDir) { 'reinstall' } else { 'install' }
        Save-HerdrAppDownload -Url (Get-HerdrAppDownloadUrl -Url $url -Releases $Releases -Src $src) -OutFile $archive
        Assert-HerdrAppSha256 -Path $archive -Expected $Pins.AppSha256
        $untar = Invoke-HerdrAppNative -FilePath $Tar -Arguments @('-xzf', $archive, '-C', $tmp)
        $unpacked = Join-Path $tmp 'herdr-app'
        $exe = Join-Path $unpacked 'herdr-app.exe'
        if (($untar.ExitCode -ne 0) -or -not (Test-Path -LiteralPath $exe -PathType Leaf)) {
            throw "落とした tar.gz に herdr-app\herdr-app.exe が無い (tar.exe の終了コード $($untar.ExitCode))"
        }
        Assert-HerdrAppExe -Exe $exe -Name 'herdr-app' -Version $Pins.AppVersion
        New-Item -ItemType Directory -Force (Split-Path $AppDir) | Out-Null
        Remove-Item -LiteralPath "$AppDir.old" -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $AppDir) { Rename-Item -LiteralPath $AppDir -NewName "$(Split-Path $AppDir -Leaf).old" }
        Move-Item -LiteralPath $unpacked -Destination $AppDir
        Remove-Item -LiteralPath "$AppDir.old" -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "herdr-app $($Pins.AppVersion) を $AppDir に置いた (署名と sha256 を確かめた)"
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# core を固定した版で入れる: 版つき URL の zip を落とす → dotfiles の sha256 → System32\tar.exe で展開 → conpty と署名と版を
# 確かめる → 無ければ置き、hc が無ければ hc.exe を hard link で作る。あれば公式と同じく herdr-core.exe update --from で
# 差し替える (terminal は動いたまま)。-Repair (入っている core の署名が合わない) では、入っている exe を動かさない
# (update --from も server stop も打たない)。動いていれば止めてもらい、止まっていれば置き場所を消してから置き直す
function Install-HerdrCorePackage {
    param($Pins, [string]$CoreDir, [string]$Releases, [string]$Tar, [switch]$Repair)
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "install-herdr-core-$PID"
    New-Item -ItemType Directory -Force $tmp | Out-Null
    try {
        $url = Get-HerdrAppArtifactUrl -Releases $Releases -Kind 'core' -Version $Pins.CoreVersion
        Write-Host "herdr-core $($Pins.CoreVersion) を落とす: $url"
        $archive = Join-Path $tmp 'hc.zip'
        $exe = Join-Path $CoreDir 'herdr-core.exe'
        $src = if (Test-Path -LiteralPath $exe) { 'update' } else { 'install' }
        Save-HerdrAppDownload -Url (Get-HerdrAppDownloadUrl -Url $url -Releases $Releases -Src $src) -OutFile $archive
        Assert-HerdrAppSha256 -Path $archive -Expected $Pins.CoreTargets['windows-x86_64']
        $unpacked = Join-Path $tmp 'hc'
        New-Item -ItemType Directory -Force $unpacked | Out-Null
        $unzip = Invoke-HerdrAppNative -FilePath $Tar -Arguments @('-xf', $archive, '-C', $unpacked)
        if (($unzip.ExitCode -ne 0) -or -not (Test-Path -LiteralPath (Join-Path $unpacked 'conpty\conpty.dll') -PathType Leaf)) {
            throw "落とした zip に conpty\conpty.dll が無い (tar.exe の終了コード $($unzip.ExitCode))"
        }
        $new = Join-Path $unpacked 'herdr-core.exe'
        Assert-HerdrAppExe -Exe $new -Name 'hc' -Version $Pins.CoreVersion
        if ($Repair) {
            $busy = @(Get-HerdrAppBusyProcess -Dirs @($CoreDir))
            if ($busy.Count -gt 0) {
                throw "署名の合わない herdr-core が動いている ($(@($busy | ForEach-Object { "PID $($_.Id)" }) -join '・'))。それを動かさないよう server stop は使わず、タスク マネージャーなどで止めてから Install-HerdrApp を打ち直す (core の中の terminal も終わる)"
            }
            if (-not (Remove-HerdrAppItem -Path $CoreDir)) { throw "署名の合わない herdr-core の置き場所 $CoreDir を消せない" }
            Write-Host "署名の合わない herdr-core の置き場所 $CoreDir を消した"
        }
        if (Test-Path -LiteralPath $exe -PathType Leaf) {
            $update = Invoke-HerdrAppNative -FilePath $exe -Arguments @('update', '--from', $new)
            if ($update.ExitCode -ne 0) { throw "herdr-core.exe update --from が失敗した (終了コード $($update.ExitCode)) $($update.Lines -join ' ')" }
            Write-Host "herdr-core を $($Pins.CoreVersion) に差し替えた (terminal は動いたまま。署名と sha256 を確かめた)"
        } else {
            New-Item -ItemType Directory -Force $CoreDir | Out-Null
            Copy-Item -LiteralPath $new, (Join-Path $unpacked 'conpty') -Destination $CoreDir -Recurse -Force
            $hc = Join-Path $CoreDir 'hc.exe'
            if (-not (Get-Command hc -ErrorAction SilentlyContinue) -and -not (Test-Path -LiteralPath $hc)) {
                New-Item -ItemType HardLink -Path $hc -Target $exe | Out-Null
                Write-Host 'hc.exe を herdr-core.exe への hard link で作った'
            }
            Write-Host "herdr-core $($Pins.CoreVersion) を $CoreDir に置いた (署名と sha256 を確かめた)"
        }
        Copy-Item -LiteralPath (Join-Path $unpacked 'THIRD-PARTY-NOTICES') -Destination $CoreDir -Recurse -Force -ErrorAction SilentlyContinue
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# -Uninstall の本体。外すものがあれば、動いているかを見て、止まっていれば外す。外した後に読み直し、外すものが残って
# いなければ 0
function Invoke-UninstallHerdrApp {
    param($State, $Pins, $Locations, [string]$Releases)
    $plan = @(Get-HerdrAppUninstallPlan -State $State -AppDir $Locations.AppDir -CoreDir $Locations.CoreDir -Menu $Locations.Menu -FeedDir $Locations.FeedDir)
    Write-Host 'herdr-app と herdr-core を外す (公式の install.ps1 と同じ置き場所のものと、dotfiles のフィード・環境変数だけ。設定は残す)'
    if ($plan.Count -eq 0) {
        Write-Host '  外すもの (app・Herdr.lnk・PATH の行・core・フィード・環境変数) は無い。何もしない'
        foreach ($line in @(Format-HerdrAppKept -State $State -Locations $Locations -Exists { param($p) Test-Path -LiteralPath $p })) { Write-Host "  $line" }
        return 0
    }
    $busy = @(Get-HerdrAppBusyProcess -Dirs (Get-HerdrAppWatchDirs -AppDir $Locations.AppDir -CoreDir $Locations.CoreDir))
    if ($busy.Count -gt 0) {
        foreach ($line in @(Format-HerdrAppBusy -Processes $busy -CoreDir $Locations.CoreDir)) { Write-Host $line -ForegroundColor Yellow }
        return 1
    }
    $failed = $false
    $pathDirs = @()
    foreach ($step in $plan) {
        if ($step.Kind -eq 'path') {
            $pathDirs += $step.Target
            continue
        }
        if ($step.Kind -eq 'env') {
            Remove-HerdrAppEnvValue
            Write-Host '  外した: ユーザーの環境変数 HERDR_RELEASES_URL'
            continue
        }
        if (Remove-HerdrAppItem -Path $step.Target) {
            Write-Host "  外した: $($step.Target)"
            if ($step.Target -eq $Locations.FeedDir) { Remove-HerdrAppEmptyParent -Dir $Locations.FeedDir }
        } else {
            Write-Host "  外せなかった: $($step.Target)" -ForegroundColor Yellow
            $failed = $true
        }
    }
    if ($pathDirs.Count -gt 0) {
        Remove-HerdrAppUserPath -Dirs $pathDirs
        foreach ($dir in $pathDirs) { Write-Host "  外した: ユーザーの PATH の $dir" }
    }
    foreach ($line in @(Format-HerdrAppKept -State $State -Locations $Locations -Exists { param($p) Test-Path -LiteralPath $p })) { Write-Host "  $line" }

    # 外しきれたかを読み直して確かめる
    $after = Get-HerdrAppState -Locations $Locations -Pins $Pins -Releases $Releases
    $left = @(Get-HerdrAppUninstallPlan -State $after -AppDir $Locations.AppDir -CoreDir $Locations.CoreDir -Menu $Locations.Menu -FeedDir $Locations.FeedDir)
    if (($left.Count -eq 0) -and -not $failed) {
        Write-Host '外した'
        Write-Host '※ dotfiles が管理する間は、次の setup --update が入れ直す (winget に移るときは win/README.md の「winget に載ったら」の順で)'
        return 0
    }
    foreach ($step in $left) {
        $text = switch ($step.Kind) {
            'path' { "ユーザーの PATH の $($step.Target)" }
            'env' { 'ユーザーの環境変数 HERDR_RELEASES_URL' }
            default { $step.Target }
        }
        Write-Host "  残っている: $text" -ForegroundColor Yellow
    }
    Write-Host '⚠️ 外しきれなかった。上の理由を見て直し、Install-HerdrApp -Uninstall を打ち直す ⚠️' -ForegroundColor Yellow
    return 1
}

function Invoke-InstallHerdrApp {
    param([switch]$Check, [switch]$IfMissing, [switch]$Uninstall, $Pins)
    if ($Uninstall -and ($Check -or $IfMissing)) {
        Write-Host '-Uninstall は -Check・-IfMissing と一緒に使えない'
        return 2
    }
    $bad = Test-HerdrAppPins -Pins $Pins
    if ($bad) {
        Write-Host "固定した版の書き方が誤っている: $bad"
        return 2
    }
    $releases = 'https://releases.herdr.dev'
    $locations = Get-HerdrAppLocations
    $state = Get-HerdrAppState -Locations $locations -Pins $Pins -Releases $releases
    if ($Uninstall) { return (Invoke-UninstallHerdrApp -State $state -Pins $Pins -Locations $locations -Releases $releases) }

    Write-HerdrAppState -State $state -Pins $Pins -Locations $locations
    $code = Get-HerdrAppExitCode -State $state -Pins $Pins
    if ($Check) {
        switch ($code) {
            0 { Write-Host '入っている (固定した版・フィード・環境変数も揃っている)' }
            3 { Write-Host '⚠️ herdr-app が入っていない → Install-HerdrApp で入れる ⚠️' -ForegroundColor Yellow }
            default { Write-Host '⚠️ herdr-app に揃っていないものがある → Install-HerdrApp で揃える ⚠️' -ForegroundColor Yellow }
        }
        return $code
    }
    if ($code -eq 0) {
        Write-Host '揃っている。何もしない'
        return 0
    }

    # 揃える。フィードと環境変数を先に書く (このあと入れる app と core が、最初からフィードの版にだけ上がるよう)
    $plan = Get-HerdrAppInstallPlan -State $state -Pins $Pins
    if ($plan.Feed) { Sync-HerdrAppFeed -FeedDir $locations.FeedDir -Pins $Pins -Releases $releases }
    if ($plan.Env) { Set-HerdrAppEnvValue -Value $state.FeedUrl }
    # 今のプロセスにはいつも置く (このあと打つ herdr-core.exe update が立て直す core が受け継ぐ。WSL から起こした pwsh.exe には、
    # ユーザーの環境変数を置いた後でも無いことがある)
    $env:HERDR_RELEASES_URL = $state.FeedUrl
    # 公式から受け取った更新を消す (固定した版を入れても、残っていれば app を閉じるか開き直すと差し替わる)
    if ($plan.Staged) {
        foreach ($path in @($state.StagedPaths)) {
            if (Remove-HerdrAppItem -Path $path) { Write-Host "受け取っていた更新 $path を消した" }
            else { Write-Host "受け取っていた更新 $path を消せなかった" -ForegroundColor Yellow }
        }
        Write-Host '開いている app は、すぐ閉じて開き直す (取得元の変数を置く前に開いた app は、また公式から受け取りうる)'
    }

    $getApp = $plan.App -in @('install', 'upgrade', 'repair')
    $getCore = $plan.Core -in @('install', 'upgrade', 'repair')
    # ここのパスは Join-Path で組まない (C: も SystemRoot も無い Linux の pwsh で流すテストでも組めるように)
    $tar = "$env:SystemRoot\System32\tar.exe"
    if ($getApp -or $getCore) {
        $blocker = Get-HerdrAppDownloadBlocker -Tar $tar
        if ($blocker) {
            Write-Host "入れられない: $blocker"
            return 1
        }
    }
    if ($getApp) {
        try {
            Install-HerdrAppPackage -Pins $Pins -AppDir $locations.AppDir -Releases $releases -Tar $tar
        } catch {
            Write-Host "herdr-app を入れられなかった: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host 'ネットワークを確かめて Install-HerdrApp を打ち直す (setup --update でも、もう一度入れにいく)'
            return 1
        }
    }
    if ($plan.Lnk) { New-HerdrAppShortcut -Path $locations.Menu -Exe "$($locations.AppDir)\herdr-app.exe" }
    if ($plan.AppPath) { Add-HerdrAppUserPath -Dir $locations.AppDir -Flag 'HERDR_INSTALLING' }
    if ($getCore) {
        $coreInstalled = $false
        try {
            Install-HerdrCorePackage -Pins $Pins -CoreDir $locations.CoreDir -Releases $releases -Tar $tar -Repair:($plan.Core -eq 'repair')
            $coreInstalled = $true
        } catch {
            Write-Host "herdr-core を入れられなかった: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host 'Install-HerdrApp を打ち直す'
        }
        # PATH に足すのは入れられたときだけ (足すときの失敗は、入れられなかったことと分けて出す)
        if ($coreInstalled) { Add-HerdrAppUserPath -Dir $locations.CoreDir -Flag 'HC_INSTALLING' }
    } elseif ($plan.CorePath) {
        Add-HerdrAppUserPath -Dir $locations.CoreDir -Flag 'HC_INSTALLING'
    }

    # 揃ったかを読み直して確かめる
    Write-Host ''
    $after = Get-HerdrAppState -Locations $locations -Pins $Pins -Releases $releases
    Write-HerdrAppState -State $after -Pins $Pins -Locations $locations
    if ((Get-HerdrAppExitCode -State $after -Pins $Pins) -eq 0) {
        Write-Host '揃った'
        return 0
    }
    Write-Host '⚠️ まだ揃っていないものがある (上の ⚠ の行) ⚠️' -ForegroundColor Yellow
    return 1
}

# dot-source されたとき (テスト) は関数だけを読み、本体は走らせない。
# 思わぬ例外は受け止めて終了コード 2 で終える。受け止めないと exit まで届かず、
# -Command から呼んだとき外側の exit $LASTEXITCODE が中の curl.exe などの 0 を返して成功に見える
if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest
    try {
        $file = if ($ReleasesFile) { $ReleasesFile } else { Join-Path $PSScriptRoot 'herdr-releases.json' }
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            Write-Host "固定した版のファイル $file が無い (setup --update で配る。repo では nix/pkgs/herdr-core/releases.json)" -ForegroundColor Red
            exit 2
        }
        # 相対パスは PowerShell の今の場所で解く (.NET の ReadAllText はプロセスの作業ディレクトリで解くので、cd の後にずれる)
        $file = Convert-Path -LiteralPath $file
        $pins = ConvertFrom-HerdrAppReleases -Text ([IO.File]::ReadAllText($file))
        exit (Invoke-InstallHerdrApp -Check:$Check -IfMissing:$IfMissing -Uninstall:$Uninstall -Pins $pins)
    } catch {
        Write-Host "エラーで止まった: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace
        exit 2
    }
}
