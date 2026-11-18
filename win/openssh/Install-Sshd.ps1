<#
.SYNOPSIS
dotfiles が winget で固定した Win32-OpenSSH (C:\Program Files\OpenSSH) に sshd (OpenSSH Server) を足し、Tailscale (tailnet) と
localhost からだけ、鍵でだけ SSH で入れるようにする。

.DESCRIPTION
dotfiles の win/openssh/Install-Sshd.ps1 を %USERPROFILE%\.config\powershell\ へ配り、PowerShell では dotfiles.ps1 の Install-Sshd
から呼ぶ (win/README.md の「sshd」)。setup (bootstrap-windows-sshd.sh・runner の sshd) が流すのは、道具の switch windowsSshd
(dotfiles.wsl.windowsFiles.sshd.enable) が on のマシンだけ。iPhone の Herdr のアプリや hc が、この PC の herdr-core に SSH で
つなぐのに使う (dotfiles-private の ADR 078)。

揃えるもの:

1. server: Install-OpenSSH.ps1 が winget (Microsoft.OpenSSH.Preview) で入れた MSI に、Server の機能を足す。入っている版と同じ
   版の MSI を winget download で取り直し (winget が manifest の sha256 と照らす)、msiexec /i <MSI> ADDLOCAL=Client,Server で流す
   (同じ ProductCode なので保守の install になり、Server が足される)。Windows Installer の手元の写しは cab が抜かれているので、
   ProductCode だけでは足せない。winget の install と pin には触らない。Windows の機能 (System32) の OpenSSH Server とは二重にしない
2. C:\ProgramData\ssh\sshd_config: dotfiles が書く中身 (Get-SshdConfigText。鍵だけ・AllowUsers で tailnet と localhost に限る) に
   する。違えば sshd_config.dotfiles-bak-<日時> に退避して書き直す。MSI は Server を足した時点で sshd を起こし、sshd は
   sshd_config が無ければ既定 (パスワードでも入れる) を写すので、server を足す前に書いておく (ディレクトリが無ければ、sshd が作るのと
   同じ権限で作る)
3. Windows Firewall: 拒否の規則を 3 つ置き (Get-SshdFirewallSpecs)、22 番を許す受信の規則 (MSI が作るものなど) を無効にする。
   block は allow より強いので、Tailscale の ACL を誤っても、tailnet からは 22 番にしか届かず、22 番には tailnet と localhost
   からしか届かない
4. C:\ProgramData\ssh\administrators_authorized_keys (Windows の管理者の鍵の置き場): 鍵の写し (-KeysCopy。setup が置く) が
   あれば、その中身どおりに書く (写しに無い鍵は消す。元は .dotfiles-bak-<日時> に退避する)。写しが無ければ中身に触らず、
   ファイルが無ければ空で作る。どちらも、読み書きできるのを管理者と SYSTEM だけにする
5. サービス sshd: 自動で起こし、動かす。sshd_config を書き直したら起こし直す (つないでいる SSH が切れることがある)

管理者が要るのは揃える段だけで、そのときだけ UAC で自分を起動し直す。-Check は何も変えない。管理者でないと
administrators_authorized_keys (と、読めなければ sshd_config) は読めないので、そのときは揃えたときの記録 (StateDir の
deployed.json。書いた中身の sha256) と比べる。管理者の PowerShell で -Check を打つと、中身そのものと比べる。

sshd が読むファイル (sshd_config・administrators_authorized_keys) のコメントは ASCII にする (sshd は設定を byte のまま読む。
化けて読まれる余地を残さない)。

BOM 付きの UTF-8 で保存すること (Windows PowerShell 5.1 は BOM の無い UTF-8 を CP932 として読む)。

.PARAMETER Check
今の状態と dotfiles の形との差を出すだけで、何も変えない。揃っていれば終了コード 0、sshd が入っていなければ 3、ほかの差が
あれば (先に直すことがあって揃えられないときも) 1。

.PARAMETER IfMissing
sshd が入っていなければ入れて揃える (UAC の確認が 1 回出る)。入っていれば -Check と同じ (何も変えない)。setup が使う。

.PARAMETER KeysCopy
鍵の写し。既定は %LOCALAPPDATA%\dotfiles\sshd\authorized_keys (setup の bootstrap-windows-sshd.sh が、ホストの値の
wsl.windowsFiles.sshd.authorizedKeys から置く。null のホストでは置かない)。

.PARAMETER AllowUser
AllowUsers に書く Windows のユーザー。既定はこのスクリプトを流しているユーザー (小文字にする)。

.PARAMETER StateDir
揃えたときの記録の置き場。既定は %LOCALAPPDATA%\dotfiles\sshd。管理者で起動し直した子には、親の場所を渡す。

.PARAMETER LogPath
内部用。管理者で起動し直した子が、結果をこのファイルへ書いて親へ渡す。
#>
[CmdletBinding()]
param(
    [switch]$Check,
    [switch]$IfMissing,
    [string]$KeysCopy,
    [string]$AllowUser,
    [string]$StateDir,
    [string]$LogPath
)

# ---------------------------------------------------------------------------
# 決まり
# ---------------------------------------------------------------------------

# tailnet のアドレス (Tailscale が端末に配る CGNAT の範囲と ULA の範囲)
$script:TailnetAddresses = @('100.64.0.0/10', 'fd7a:115c:a1e0::/48')
# tailnet と localhost の外のアドレス (上の 2 つと 127.0.0.0/8・::1・:: を除いた全部)
$script:OutsideAddresses = @(
    '0.0.0.0-100.63.255.255'
    '100.128.0.0-126.255.255.255'
    '128.0.0.0-255.255.255.255'
    '::2-fd7a:115c:a1df:ffff:ffff:ffff:ffff:ffff'
    'fd7a:115c:a1e1::-ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff'
)
# 拒否の規則のグループ (Windows Defender ファイアウォールの画面で、まとめて見つけられる)
$script:RuleGroup = 'dotfiles (sshd)'
# Install-OpenSSH.ps1 が入れる winget のパッケージ (この MSI に Server を足す)
$script:PackageId = 'Microsoft.OpenSSH.Preview'
# C:\ProgramData\ssh の権限 (sshd が自分で作るときと同じ。Win32-OpenSSH の wmain_sshd.c の create_prgdata_ssh_folder)
$script:SshDirSddl = 'O:BAD:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;AU)'
# 管理者 (BUILTIN\Administrators) と SYSTEM の SID (表示の言語によらない)
$script:AdminSids = @('S-1-5-32-544', 'S-1-5-18')
# 鍵の種類 (authorized_keys の行で、オプションの後ろに来る語)
$script:KeyTypePattern = 'ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(?:256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com'

# ---------------------------------------------------------------------------
# 副作用の無い関数 (Install-Sshd.Tests.ps1 で確かめる)
# ---------------------------------------------------------------------------

# AllowUsers に書けるユーザー名か (小文字にした後の名前)。空白・パターンの文字 (* ? ! ,)・@・" を含む名前は、sshd_config の
# 1 語に書けないので断る
function Test-SshdUserName {
    param([string]$Name)
    "$Name" -cmatch '^[a-z0-9][a-z0-9._-]*$'
}

# CRLF を LF にそろえる (メモ帳で保存し直すと CRLF になる。sshd はどちらでも読むので、改行の違いはずれと数えない)
function ConvertTo-Lf {
    param([string]$Text)
    "$Text" -replace "`r`n", "`n"
}

# dotfiles が書く sshd_config の中身 (改行は LF)。$AllowUser だけを、tailnet と localhost から来たときだけ入れる
function Get-SshdConfigText {
    param([string]$AllowUser)
    $from = @($script:TailnetAddresses) + @('127.0.0.1', '::1')
    $allow = @($from | ForEach-Object { "$AllowUser@$_" }) -join ' '
    $lines = @(
        '# Written by dotfiles (Install-Sshd.ps1). Do not edit by hand: Install-Sshd -Check reports the difference,'
        '# and Install-Sshd moves this file to sshd_config.dotfiles-bak-<time> and writes it again.'
        '# Why it looks like this: dotfiles win/README.md, section "sshd".'
        '#'
        '# Public-key logins only, and only from Tailscale (the tailnet) and localhost. sshd listens on all'
        '# addresses (with ListenAddress bound to the Tailscale IP, sshd fails at boot when that IP is not up yet).'
        '# AllowUsers and the Windows Firewall block rules limit where logins can come from.'
        ''
        'Port 22'
        ''
        '# Public keys only: no passwords, no keyboard-interactive'
        'PubkeyAuthentication yes'
        'PasswordAuthentication no'
        'KbdInteractiveAuthentication no'
        'AuthenticationMethods publickey'
        ''
        '# Only this user, and only from the tailnet (100.64.0.0/10, fd7a:115c:a1e0::/48) and localhost'
        "AllowUsers $allow"
        ''
        'AuthorizedKeysFile .ssh/authorized_keys'
        ''
        'Subsystem sftp sftp-server.exe'
        ''
        '# Administrators read their keys from ProgramData, not from the user profile (the Win32-OpenSSH default)'
        'Match Group administrators'
        '       AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys'
    )
    ($lines -join "`n") + "`n"
}

# authorized_keys の書き方の行のうち、鍵の行 (# で始まる行と空の行を除き、前後の空白を落としたもの)
function Get-KeyLines {
    param([string[]]$Lines)
    foreach ($line in $Lines) {
        $t = "$line".Trim()
        if ($t -and -not $t.StartsWith('#')) { $t }
    }
}

# authorized_keys の 1 行として読めるか: 鍵の種類と base64 の組があり、改行を含まない。前にオプション (from= など) が付いてよい
function Test-AuthorizedKeyLine {
    param([string]$Line)
    if ("$Line" -match "[`r`n]") { return $false }
    "$Line" -cmatch "(^|\s)($script:KeyTypePattern)\s+[A-Za-z0-9+/]{16,}={0,3}(\s|$)"
}

# 鍵の写しの中身 (行の配列) を、鍵の行 (Lines) と読めない行 (Bad) に分ける
function ConvertFrom-KeysCopy {
    param([string[]]$Lines)
    $keys = @(Get-KeyLines -Lines $Lines)
    [pscustomobject]@{
        Lines = @($keys | Where-Object { Test-AuthorizedKeyLine -Line $_ })
        Bad   = @($keys | Where-Object { -not (Test-AuthorizedKeyLine -Line $_) })
    }
}

# 表に出す鍵の名札: コメント (無ければ base64 の末尾 8 字) と鍵の種類。from= が無ければそう添える
function Get-KeyLabel {
    param([string]$Line)
    if ("$Line" -cmatch "(?:^|\s)($script:KeyTypePattern)\s+([A-Za-z0-9+/]+={0,3})(?:\s+(.*))?$") {
        $type = $Matches[1]
        $b64 = $Matches[2]
        $comment = "$($Matches[3])".Trim()
        $name = if ($comment) { $comment } else { '…' + $b64.Substring([Math]::Max(0, $b64.Length - 8)) }
        $from = if ("$Line" -match '(^|[\s,])from="') { '' } else { '・from= 無し' }
        return "$name ($type$from)"
    }
    '(読めない行)'
}

# from= の無い鍵の行か (オプションの from="…" で、鍵を使える端末を縛っていない)
function Test-KeyWithoutFrom {
    param([string]$Line)
    -not ("$Line" -match '(^|[\s,])from="')
}

# administrators_authorized_keys に書く中身 (改行は LF)。$Managed が偽なら、鍵の写しが無いときに空で作る中身
function Get-AdminKeysText {
    param([string[]]$KeyLines, [bool]$Managed = $true)
    if ($Managed) {
        $head = @(
            '# Written by dotfiles (Install-Sshd.ps1) from the keys copy that setup puts in %LOCALAPPDATA%\dotfiles\sshd\authorized_keys.'
            '# Add or remove keys in the host values (dotfiles-private, wsl.windowsFiles.sshd.authorizedKeys), not here.'
        )
    } else {
        $head = @('# Created empty by dotfiles (Install-Sshd.ps1). One public key per line, prefixed with from="<the device''s Tailscale IP>".')
    }
    ((@($head) + @($KeyLines | Where-Object { $_ })) -join "`n") + "`n"
}

# 鍵の行の差。Added は写しにあってファイルに無い行、Removed はファイルにあって写しに無い行。Same は並びも同じか
function Compare-KeyLines {
    param([string[]]$Want, [string[]]$Have)
    $w = @($Want | Where-Object { $_ })
    $h = @($Have | Where-Object { $_ })
    [pscustomobject]@{
        Added   = @($w | Where-Object { $h -cnotcontains $_ })
        Removed = @($h | Where-Object { $w -cnotcontains $_ })
        Same    = (($w -join "`n") -ceq ($h -join "`n"))
    }
}

# 中身 (BOM の無い UTF-8 の byte) の sha256 (小文字の 16 進)
function Get-TextSha256 {
    param([string]$Text)
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes("$Text")
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        (@($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') })) -join ''
    } finally {
        $sha.Dispose()
    }
}

# Windows Firewall のアドレスの書き方を 1 つの形にそろえる (Get-NetFirewallAddressFilter は 100.64.0.0/10 を 100.64.0.0/255.192.0.0 と
# 返す)。IP は [ipaddress] の文字列 (IPv6 は小文字の省略形)、範囲は両端を、サブネットは長さ (/10) にする。Any などの語は小文字
function ConvertTo-CanonicalAddress {
    param([string]$Address)
    $a = "$Address".Trim()
    $parse = {
        param([string]$s)
        $ip = $null
        if ([System.Net.IPAddress]::TryParse($s, [ref]$ip)) { return $ip.ToString() }
        $null
    }
    if ($a -match '^([^/-]+)-([^/-]+)$') {
        $from = $Matches[1]
        $to = $Matches[2]
        $lo = & $parse $from
        $hi = & $parse $to
        if ($lo -and $hi) { return "$lo-$hi" }
        return $a.ToLowerInvariant()
    }
    if ($a -match '^([^/]+)/(.+)$') {
        $netText = $Matches[1]
        $lenText = $Matches[2]
        $net = & $parse $netText
        if ($net) {
            if ($lenText -match '^\d+$') { return "$net/$([int]$lenText)" }
            $mask = $null
            if ([System.Net.IPAddress]::TryParse($lenText, [ref]$mask) -and ("$($mask.AddressFamily)" -eq 'InterNetwork')) {
                $bits = 0
                foreach ($b in $mask.GetAddressBytes()) { $bits += ([Convert]::ToString([int]$b, 2) -replace '0', '').Length }
                return "$net/$bits"
            }
        }
        return $a.ToLowerInvariant()
    }
    $single = & $parse $a
    if ($single) { return $single }
    $a.ToLowerInvariant()
}

# アドレスの並びを、そろえた形の重ならない並び (辞書順) にする
function ConvertTo-CanonicalAddressList {
    param([string[]]$Addresses)
    @(@($Addresses | Where-Object { "$_" } | ForEach-Object { ConvertTo-CanonicalAddress -Address $_ }) | Sort-Object -Unique)
}

# 置く拒否の規則。どれも受信 (Inbound)・拒否 (Block)・すべてのプロファイル (Any) で、グループは $script:RuleGroup
#   tailnet-tcp: この PC の tailnet のアドレス宛ての TCP のうち 22 番以外 (Tailscale が入れる許可 Tailscale-In は、Tailscale の IP
#                宛てを全ポートで許す。block はそれより強い)
#   tailnet-udp: この PC の tailnet のアドレス宛ての UDP (全ポート)
#   outside-tcp22: tailnet と localhost の外 (LAN・WSL・Hyper-V など) から 22 番に来る TCP (MSI が作る許可を、作り直されても効かなくする)
function Get-SshdFirewallSpecs {
    @(
        [pscustomobject]@{
            Name          = 'dotfiles-sshd-tailnet-tcp'
            DisplayName   = 'dotfiles: tailnet から来る TCP の 22 番以外を拒否 (sshd)'
            Protocol      = 'TCP'
            LocalPort     = @('1-21', '23-65535')
            LocalAddress  = @($script:TailnetAddresses)
            RemoteAddress = @('Any')
        }
        [pscustomobject]@{
            Name          = 'dotfiles-sshd-tailnet-udp'
            DisplayName   = 'dotfiles: tailnet から来る UDP を拒否 (sshd)'
            Protocol      = 'UDP'
            LocalPort     = @('Any')
            LocalAddress  = @($script:TailnetAddresses)
            RemoteAddress = @('Any')
        }
        [pscustomobject]@{
            Name          = 'dotfiles-sshd-outside-tcp22'
            DisplayName   = 'dotfiles: tailnet と localhost の外から来る TCP の 22 番を拒否 (sshd)'
            Protocol      = 'TCP'
            LocalPort     = @('22')
            LocalAddress  = @('Any')
            RemoteAddress = @($script:OutsideAddresses)
        }
    )
}

# 読んだ規則 ($Rule。Enabled・Direction・Action・Profile・Protocol・LocalPort・LocalAddress・RemoteAddress を文字列で持つ) が、
# spec の拒否の規則と同じか。規則が無ければ偽
function Test-FirewallRuleMatch {
    param($Spec, $Rule)
    if ($null -eq $Rule) { return $false }
    $ports = { param($p) (@(@($p) | ForEach-Object { "$_".ToLowerInvariant() } | Sort-Object)) -join ',' }
    $addrs = { param($p) (ConvertTo-CanonicalAddressList -Addresses @($p)) -join ',' }
    ("$($Rule.Enabled)" -eq 'True') -and
    ("$($Rule.Direction)" -eq 'Inbound') -and
    ("$($Rule.Action)" -eq 'Block') -and
    ("$($Rule.Profile)" -eq 'Any') -and
    ("$($Rule.Protocol)" -eq $Spec.Protocol) -and
    ((& $ports $Rule.LocalPort) -eq (& $ports $Spec.LocalPort)) -and
    ((& $addrs $Rule.LocalAddress) -eq (& $addrs $Spec.LocalAddress)) -and
    ((& $addrs $Rule.RemoteAddress) -eq (& $addrs $Spec.RemoteAddress))
}

# 鍵のファイルの権限が、管理者と SYSTEM だけか (Win32-OpenSSH が administrators_authorized_keys に求める形)。$Acl は Protected
# (継承を切ったか)・Owner (SID)・Rules (Sid・Rights・Type・Inherited の組) を持つ。両方に FullControl を許し、ほかに許す相手が無い
function Test-AdminOnlyAcl {
    param($Acl)
    if (($null -eq $Acl) -or (-not $Acl.Protected)) { return $false }
    if ($script:AdminSids -notcontains "$($Acl.Owner)") { return $false }
    $rules = @($Acl.Rules)
    foreach ($r in $rules) {
        if ($r.Inherited) { return $false }
        if ("$($r.Type)" -ne 'Allow') { return $false }
        if ($script:AdminSids -notcontains "$($r.Sid)") { return $false }
        if (@('FullControl', '268435456') -notcontains "$($r.Rights)") { return $false }
    }
    $sids = @($rules | ForEach-Object { "$($_.Sid)" } | Sort-Object -Unique)
    ($sids -join ',') -eq (@($script:AdminSids | Sort-Object) -join ',')
}

# Server を足すのに、入っている版と同じ版の MSI を取り直す winget download の引数 (download は pin を見ない。winget が
# manifest の sha256 と照らす)
function Get-WingetDownloadArgs {
    param([string]$PackageId, [string]$Version, [string]$Directory)
    @('download', '--id', $PackageId, '--exact', '--source', 'winget', '--version', $Version,
        '--download-directory', $Directory, '--accept-source-agreements', '--accept-package-agreements', '--disable-interactivity')
}

# 取り直した MSI で Server を足す msiexec の引数。入っているのと同じ ProductCode なので保守の install になる。Client も並べる
# (ADDLOCAL に無い機能は今のまま残るが、並べておくと、入れ直しになったときも Client を外さない)。パスは "" で囲む
# (Start-Process は配列を空白でつなぐだけ)
function Get-MsiAddServerArgs {
    param([string]$Msi, [string]$Log)
    @('/i', ('"{0}"' -f $Msi), 'ADDLOCAL=Client,Server', '/qn', '/norestart', '/l*v', ('"{0}"' -f $Log))
}

# msiexec の終了コードの読み方。0 と 3010 (再起動が要る) は足せた。1618 は別のインストールが進んでいる
function Get-MsiexecResultText {
    param([int]$ExitCode)
    switch ($ExitCode) {
        0 { return $null }
        3010 { return $null }
        1618 { return '別のインストールが進んでいる。終わってから打ち直す' }
        1602 { return '取り消された' }
        default { return "終了コード $ExitCode" }
    }
}

# 読んだ事実 ($Facts。Get-SshdFacts) から、項目ごとの判定と表の行を作る。Blocked は揃える前に人が直すこと
# (no-openssh: OpenSSH が無い / inbox: Windows の機能の OpenSSH Server がある / bad-user: AllowUsers に書けない名前 /
# bad-keys: 鍵の写しに読めない行がある)。Items は Key・Ok・Text の並び、Notes は ※ の行
function Get-SshdVerdict {
    param($Facts)
    $items = [System.Collections.Generic.List[object]]::new()
    $notes = [System.Collections.Generic.List[string]]::new()
    $add = { param($key, $ok, $text) $items.Add([pscustomobject]@{ Key = $key; Ok = [bool]$ok; Text = $text }) }

    $blocked = $null
    if (-not $Facts.OpenSsh) {
        $blocked = 'no-openssh'
    } elseif ($Facts.Inbox) {
        $blocked = 'inbox'
    } elseif (-not (Test-SshdUserName -Name $Facts.User)) {
        $blocked = 'bad-user'
    } elseif (@($Facts.Copy.Bad).Count -gt 0) {
        $blocked = 'bad-keys'
    }

    # 1. server
    if (-not $Facts.OpenSsh) {
        & $add 'server' $false "server          : OpenSSH が入っていない ($($Facts.InstallDir)\ssh.exe が無い)。sshd はその MSI に足す"
    } elseif ($Facts.Inbox) {
        & $add 'server' $false 'server          : Windows の機能の OpenSSH Server (System32\OpenSSH) が入っている。二重にしない'
    } elseif ($Facts.Server) {
        & $add 'server' $true "server          : 入っている ($($Facts.InstallDir)\sshd.exe)"
    } else {
        & $add 'server' $false 'server          : 入っていない → 足す (Install-OpenSSH が入れた MSI の Server の機能)'
    }

    # 2. サービス
    $svc = $Facts.Service
    if ($svc.Exists) {
        $svcOk = ("$($svc.Status)" -eq 'Running') -and ("$($svc.StartType)" -eq 'Automatic')
        $svcTo = if ($svcOk) { '' } else { ' → 自動で起こし、動かす' }
        & $add 'service' $svcOk "サービス        : $($svc.Status) / $($svc.StartType)$svcTo"
    } else {
        & $add 'service' $false 'サービス        : 無い → server を足した後に、自動で起こし、動かす'
    }

    # 3. sshd_config
    $configText = Get-SshdConfigText -AllowUser $Facts.User
    $config = $Facts.Config
    if (-not $config.Exists) {
        & $add 'config' $false 'sshd_config     : 無い → dotfiles の中身を書く'
    } elseif ($config.Readable) {
        if ((ConvertTo-Lf $config.Text) -ceq $configText) {
            & $add 'config' $true 'sshd_config     : dotfiles の中身と同じ'
        } else {
            & $add 'config' $false 'sshd_config     : dotfiles の中身と違う → 退避して書き直す'
        }
    } elseif ("$($Facts.Record.ConfigSha)" -eq (Get-TextSha256 $configText)) {
        & $add 'config' $true 'sshd_config     : 読めない (管理者だけが読める)。揃えたときの記録と同じ'
    } else {
        & $add 'config' $false 'sshd_config     : 読めない (管理者だけが読める)。揃えたときの記録と違う (か記録が無い) → 退避して書き直す'
    }

    # 4. 鍵 (administrators_authorized_keys)
    $copy = $Facts.Copy
    $keys = $Facts.Keys
    $wantLines = @($copy.Lines)
    if ($copy.Managed) {
        $keysText = Get-AdminKeysText -KeyLines $wantLines
        if (-not $keys.Exists) {
            & $add 'keys' $false "鍵              : ファイルが無い → 写しの $($wantLines.Count) 本を書く"
        } elseif ($keys.Readable) {
            $diff = Compare-KeyLines -Want $wantLines -Have @(Get-KeyLines -Lines ((ConvertTo-Lf $keys.Text) -split "`n"))
            if ($diff.Same) {
                & $add 'keys' $true "鍵              : $($wantLines.Count) 本 (写しと同じ)"
            } else {
                & $add 'keys' $false "鍵              : 写しと違う (足す $(@($diff.Added).Count) 本・消す $(@($diff.Removed).Count) 本) → 写しどおりに書く"
            }
        } elseif ("$($Facts.Record.KeysSha)" -eq (Get-TextSha256 $keysText)) {
            & $add 'keys' $true "鍵              : $($wantLines.Count) 本 (読めないので、揃えたときの記録と比べた。写しと同じ)"
        } else {
            & $add 'keys' $false '鍵              : 読めない (管理者だけが読める)。揃えたときの記録と違う (か記録が無い) → 写しどおりに書く'
        }
        foreach ($line in $wantLines) { $notes.Add("※ 鍵: $(Get-KeyLabel -Line $line)") }
        if ($wantLines.Count -eq 0) {
            $notes.Add('※ 鍵が 0 本 (誰も入れない)。入れる端末の公開鍵は、ホストの値 (dotfiles-private の wsl.windowsFiles.sshd.authorizedKeys) に足して setup を流す')
        }
        $noFrom = @($wantLines | Where-Object { Test-KeyWithoutFrom -Line $_ })
        if ($noFrom.Count -gt 0) {
            $notes.Add("※ from= の無い鍵が $($noFrom.Count) 本ある。from=`"<端末の Tailscale の IP>`" を付けると、鍵が漏れてもその端末からしか使えない")
        }
    } else {
        if (-not $keys.Exists) {
            & $add 'keys' $false '鍵              : ファイルが無い → 空で作る (鍵の写しが無いので、鍵は手で置く)'
        } elseif ($keys.Readable) {
            & $add 'keys' $true "鍵              : $(@(Get-KeyLines -Lines ((ConvertTo-Lf $keys.Text) -split "`n")).Count) 本 (鍵の写しが無いので、中身は見ない)"
        } else {
            & $add 'keys' $true '鍵              : ある (読めない。鍵の写しが無いので、中身は見ない)'
        }
        $notes.Add("※ 鍵の写し ($($copy.Path)) が無いので、dotfiles は鍵を置かない (ホストの値の wsl.windowsFiles.sshd.authorizedKeys が null)")
    }

    # 5. 鍵の権限 (ファイルがあるときだけ。無ければ作るときに揃える)
    if ($keys.Exists) {
        if (-not $Facts.Acl.Readable) {
            & $add 'acl' $true '鍵の権限        : 読めない (管理者と SYSTEM だけが読める形とみる)'
        } elseif (Test-AdminOnlyAcl -Acl $Facts.Acl.Value) {
            & $add 'acl' $true '鍵の権限        : 管理者と SYSTEM だけ'
        } else {
            & $add 'acl' $false '鍵の権限        : 管理者と SYSTEM のほかにも許している (か継承している) → 管理者と SYSTEM だけにする'
        }
    }

    # 6. 拒否の規則
    if (-not $Facts.FirewallReadable) {
        & $add 'block' $false '拒否の規則      : 読めない (Get-NetFirewallRule が失敗した)'
    } else {
        $specs = @(Get-SshdFirewallSpecs)
        $bad = @($specs | Where-Object { -not (Test-FirewallRuleMatch -Spec $_ -Rule $Facts.Rules[$_.Name]) })
        if ($bad.Count -eq 0) {
            & $add 'block' $true "拒否の規則      : $($specs.Count) つとも揃っている (グループ $script:RuleGroup)"
        } else {
            & $add 'block' $false "拒否の規則      : 無い・違うものが $($bad.Count) つ ($(@($bad | ForEach-Object { $_.Name }) -join '・')) → 作り直す"
        }
    }

    # 7. 22 番を許す受信の規則
    if ($Facts.FirewallReadable) {
        $allow = @($Facts.AllowRules)
        if ($allow.Count -eq 0) {
            & $add 'allow' $true '22 番の受信の許可: 有効なものは無い'
        } else {
            & $add 'allow' $false "22 番の受信の許可: 有効 ($(@($allow | ForEach-Object { $_.DisplayName }) -join '・')) → 無効にする"
        }
    }

    if ($Facts.Inbox) {
        $notes.Add('※ Windows の機能の OpenSSH Server を外すには、管理者の PowerShell で Remove-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 を打つ (その後 Install-Sshd を打ち直す)')
    }
    if ($blocked -eq 'bad-user') {
        $notes.Add("※ AllowUsers に書けないユーザー名: $($Facts.User) (英小文字・数字・. _ - の名前だけ書ける。-AllowUser で渡す)")
    }
    foreach ($line in @($Facts.Copy.Bad)) {
        $notes.Add("※ 鍵の写しの読めない行: $(if ("$line".Length -gt 40) { "$line".Substring(0, 40) + '…' } else { $line })")
    }
    if (-not $Facts.Tailscale) {
        $notes.Add('※ Tailscale が入っていない。この sshd には tailnet と localhost からしか入れない (Tailscale は Install-Tailscale・dotfiles.wsl.windowsFiles.tailscale.enable)')
    }

    [pscustomobject]@{
        InstallDir = $Facts.InstallDir
        Blocked    = $blocked
        Installed  = [bool]($Facts.OpenSsh -and (-not $Facts.Inbox) -and $Facts.Server)
        Items      = @($items)
        Notes      = @($notes)
    }
}

# 状態の表の行 (Text と、直すことがあるかの Warn)。直すことがある行だけ先頭に ⚠ を付け、ほかは 2 字下げる。※ の行は後ろに添える
function Format-SshdState {
    param($Verdict)
    [pscustomobject]@{ Text = "sshd (OpenSSH Server、$($Verdict.InstallDir))"; Warn = $false }
    foreach ($item in @($Verdict.Items)) {
        $prefix = if ($item.Ok) { '  ' } else { '⚠ ' }
        [pscustomobject]@{ Text = "$prefix$($item.Text)"; Warn = (-not $item.Ok) }
    }
    foreach ($note in @($Verdict.Notes)) {
        [pscustomobject]@{ Text = $note; Warn = $false }
    }
}

# -Check の終了コード。人が先に直すことがあれば 1、sshd (server) が入っていなければ 3、全部揃っていれば 0、ほかは 1
function Get-SshdExitCode {
    param($Verdict)
    if ($Verdict.Blocked) { return 1 }
    if (-not $Verdict.Installed) { return 3 }
    if (@($Verdict.Items | Where-Object { -not $_.Ok }).Count -eq 0) { return 0 }
    1
}

# -Check の締めの 1 行。揃っていれば「揃っている」、ほかは ⚠️ で囲んで直し方を出す (bootstrap-windows-sshd.sh と runner の
# ps1.rs が「→ Install-Sshd で揃える」「→ Install-Sshd -IfMissing で入れる」と、先に直すことの文言で分かれる)
function Get-SshdCheckMessage {
    param($Verdict)
    if ($Verdict.Blocked -eq 'no-openssh') {
        return '⚠️ OpenSSH が入っていない → 先に Install-OpenSSH -IfMissing で入れる (sshd はその MSI に足す) ⚠️'
    }
    if ($Verdict.Blocked -eq 'inbox') {
        return '⚠️ Windows の機能の OpenSSH Server が入っている → 先に外す (二重にしない。上の ※ の行) ⚠️'
    }
    if ($Verdict.Blocked -eq 'bad-user') {
        return '⚠️ AllowUsers に書けないユーザー名 → -AllowUser で英小文字・数字・. _ - の名前を渡す ⚠️'
    }
    if ($Verdict.Blocked -eq 'bad-keys') {
        return '⚠️ 鍵の写しに読めない行がある → ホストの値 (wsl.windowsFiles.sshd.authorizedKeys) を直して setup を流し直す ⚠️'
    }
    switch (Get-SshdExitCode -Verdict $Verdict) {
        0 { '揃っている' }
        3 { '⚠️ sshd が入っていない → Install-Sshd -IfMissing で入れる (UAC の確認が 1 回出る) ⚠️' }
        default { '⚠️ dotfiles の形と揃っていない → Install-Sshd で揃える (UAC の確認が 1 回出る。sshd を起こし直すと、つないでいる SSH が切れることがある) ⚠️' }
    }
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

# ファイルを読む。Exists は在るか (読めないときは在るとみる)、Readable は読めたか
function Read-TextFile {
    param([string]$Path)
    $exists = $false
    $readable = $false
    $text = $null
    try {
        $null = Get-Item -LiteralPath $Path -ErrorAction Stop
        $exists = $true
    } catch [System.Management.Automation.ItemNotFoundException] {
        $exists = $false
    } catch {
        # 在るかも読めない (ディレクトリを読めない)。在るとみて、読めないものとして扱う
        $exists = $true
    }
    if ($exists) {
        try {
            $text = [IO.File]::ReadAllText($Path)
            $readable = $true
        } catch {
            $readable = $false
        }
    }
    [pscustomobject]@{ Exists = $exists; Readable = $readable; Text = $text }
}

# BOM の無い UTF-8 で書く (sshd は先頭の BOM を設定の文字として読む。Set-Content -Encoding UTF8 は 5.1 で BOM を付ける)
function Write-TextNoBom {
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

# 鍵の写しを読む。無ければ Managed が偽 (dotfiles は鍵を置かない)
function Read-KeysCopy {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ Managed = $false; Lines = @(); Bad = @(); Path = $Path }
    }
    $parsed = ConvertFrom-KeysCopy -Lines @([IO.File]::ReadAllLines($Path))
    [pscustomobject]@{ Managed = $true; Lines = @($parsed.Lines); Bad = @($parsed.Bad); Path = $Path }
}

# ファイルの権限を読む (Get-Acl。管理者でないと読めないことがある)
function Read-AclFacts {
    param([string]$Path)
    try {
        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
        $owner = $null
        try { $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value } catch { $owner = $null }
        $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | ForEach-Object {
                [pscustomobject]@{
                    Sid       = $_.IdentityReference.Value
                    Rights    = "$($_.FileSystemRights)"
                    Type      = "$($_.AccessControlType)"
                    Inherited = [bool]$_.IsInherited
                }
            })
        [pscustomobject]@{
            Readable = $true
            Value    = [pscustomobject]@{ Protected = [bool]$acl.AreAccessRulesProtected; Owner = $owner; Rules = $rules }
        }
    } catch {
        [pscustomobject]@{ Readable = $false; Value = $null }
    }
}

# 読み書きできるのを管理者と SYSTEM だけにする (継承を切り、持ち主を管理者にする。Microsoft の文書の icacls と同じ形を、表示の言語に
# よらない SID で書く)
function Set-AdminOnlyAcl {
    param([string]$Path)
    $acl = New-Object System.Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner((New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    foreach ($sid in $script:AdminSids) {
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            (New-Object System.Security.Principal.SecurityIdentifier($sid)), 'FullControl', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

# 拒否の規則を 1 つ読む (無ければ $null)
function Read-FirewallRuleFacts {
    param([string]$Name)
    $rule = Get-NetFirewallRule -Name $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $rule) { return $null }
    $port = $rule | Get-NetFirewallPortFilter
    $addr = $rule | Get-NetFirewallAddressFilter
    [pscustomobject]@{
        Name          = $rule.Name
        DisplayName   = $rule.DisplayName
        Enabled       = "$($rule.Enabled)"
        Direction     = "$($rule.Direction)"
        Action        = "$($rule.Action)"
        Profile       = "$($rule.Profile)"
        Protocol      = "$($port.Protocol)"
        LocalPort     = @(@($port.LocalPort) | ForEach-Object { "$_" })
        LocalAddress  = @(@($addr.LocalAddress) | ForEach-Object { "$_" })
        RemoteAddress = @(@($addr.RemoteAddress) | ForEach-Object { "$_" })
    }
}

# 22 番を許す、有効な受信の規則 (MSI が作るもの・Windows の機能が作るもの・手で作ったもの)。TCP の 22 番を名指しする規則と、
# sshd.exe を名指しする規則。Tailscale-In のように全ポートを許す規則は数えない (拒否の規則がそれより強い)
function Get-SshdAllowRules {
    $found = @{}
    foreach ($f in @(Get-NetFirewallPortFilter -All -ErrorAction SilentlyContinue |
                Where-Object { ("$($_.Protocol)" -eq 'TCP') -and (@(@($_.LocalPort) | ForEach-Object { "$_" }) -contains '22') })) {
        foreach ($r in @($f | Get-NetFirewallRule -ErrorAction SilentlyContinue)) { $found[$r.Name] = $r }
    }
    foreach ($f in @(Get-NetFirewallApplicationFilter -All -ErrorAction SilentlyContinue |
                Where-Object { "$($_.Program)" -like '*\OpenSSH\sshd.exe' })) {
        foreach ($r in @($f | Get-NetFirewallRule -ErrorAction SilentlyContinue)) { $found[$r.Name] = $r }
    }
    @($found.Values | Where-Object {
            ("$($_.Enabled)" -eq 'True') -and ("$($_.Direction)" -eq 'Inbound') -and ("$($_.Action)" -eq 'Allow')
        } | Sort-Object Name | ForEach-Object { [pscustomobject]@{ Name = $_.Name; DisplayName = $_.DisplayName } })
}

# 揃えたときの記録 (書いた中身の sha256)。無ければ両方 $null
function Read-SshdRecord {
    param([string]$Dir)
    $path = Join-Path $Dir 'deployed.json'
    $configSha = $null
    $keysSha = $null
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        try {
            $j = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json
            if ($j.PSObject.Properties['sshd_config']) { $configSha = "$($j.sshd_config)" }
            if ($j.PSObject.Properties['administrators_authorized_keys']) { $keysSha = "$($j.administrators_authorized_keys)" }
        } catch {
            $configSha = $null
            $keysSha = $null
        }
    }
    [pscustomobject]@{ ConfigSha = $configSha; KeysSha = $keysSha }
}

function Write-SshdRecord {
    param([string]$Dir, [string]$ConfigSha, [string]$KeysSha)
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    $text = ([ordered]@{ version = 1; sshd_config = $ConfigSha; administrators_authorized_keys = $KeysSha } | ConvertTo-Json -Compress) + "`n"
    Write-TextNoBom -Path (Join-Path $Dir 'deployed.json') -Text $text
}

# 今の状態を読む (何も変えない。管理者は要らない)
function Get-SshdFacts {
    param([string]$InstallDir, [string]$CopyPath, [string]$StateDir, [string]$User)
    $sshDir = Join-Path $env:ProgramData 'ssh'
    $keysPath = Join-Path $sshDir 'administrators_authorized_keys'
    $svc = Get-Service -Name sshd -ErrorAction SilentlyContinue
    $image = $null
    $reg = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\sshd' -Name ImagePath -ErrorAction SilentlyContinue
    if ($reg) { $image = "$($reg.ImagePath)" }
    $inbox = (Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32\OpenSSH\sshd.exe')) -or ($image -match '(?i)\\System32\\OpenSSH\\')
    $keys = Read-TextFile -Path $keysPath
    $acl = [pscustomobject]@{ Readable = $false; Value = $null }
    if ($keys.Exists) { $acl = Read-AclFacts -Path $keysPath }
    $rules = @{}
    $allowRules = @()
    $firewallReadable = $true
    try {
        foreach ($spec in @(Get-SshdFirewallSpecs)) { $rules[$spec.Name] = Read-FirewallRuleFacts -Name $spec.Name }
        $allowRules = @(Get-SshdAllowRules)
    } catch {
        $firewallReadable = $false
    }
    $service = [pscustomobject]@{ Exists = $false; Status = $null; StartType = $null }
    if ($svc) { $service = [pscustomobject]@{ Exists = $true; Status = "$($svc.Status)"; StartType = "$($svc.StartType)" } }
    [pscustomobject]@{
        InstallDir       = $InstallDir
        User             = $User
        OpenSsh          = Test-Path -LiteralPath (Join-Path $InstallDir 'ssh.exe')
        Server           = Test-Path -LiteralPath (Join-Path $InstallDir 'sshd.exe')
        Inbox            = [bool]$inbox
        Service          = $service
        Config           = Read-TextFile -Path (Join-Path $sshDir 'sshd_config')
        Keys             = $keys
        Acl              = $acl
        Record           = Read-SshdRecord -Dir $StateDir
        Copy             = Read-KeysCopy -Path $CopyPath
        FirewallReadable = $firewallReadable
        Rules            = $rules
        AllowRules       = $allowRules
        Tailscale        = Test-Path -LiteralPath (Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe')
    }
}

# 状態の表を出す。直すことがある行 (⚠) は黄色にする
function Write-SshdState {
    param($Verdict)
    foreach ($row in (Format-SshdState -Verdict $Verdict)) {
        if ($row.Warn) { Write-Host $row.Text -ForegroundColor Yellow } else { Write-Host $row.Text }
    }
}

# winget を打ち、出力の行 (進み具合の表示は除く) と終了コードを返す (Install-OpenSSH.ps1 と同じ)
function Invoke-Winget {
    param([string[]]$Arguments)
    # 5.1 では Stop のままだと、外部コマンドの stderr の 1 行目で止まる
    $ErrorActionPreference = 'Continue'
    $lines = & winget @Arguments 2>&1 | ForEach-Object { "$_" } |
        Where-Object { $_ -notmatch '^\s*[-\\|/]?\s*$' -and $_ -notmatch '[\u2588\u2592]' }
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Lines = @($lines) }
}

# C:\ProgramData\ssh が無ければ、sshd が自分で作るときと同じ権限で作る (SYSTEM と管理者は全部、認証したユーザーは読むだけ)。
# sshd は起きるたびに、在るディレクトリの権限を確かめる
function New-SshProgramDataDir {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) { return }
    $null = New-Item -ItemType Directory -Force -Path $Path
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetSecurityDescriptorSddlForm($script:SshDirSddl)
    Set-Acl -LiteralPath $Path -AclObject $acl
    Write-Step "$Path を作った (sshd が作るときと同じ権限)"
}

# Install-OpenSSH が入れた MSI に Server の機能を足す。入っている版と同じ版の MSI を winget download で取り直し、msiexec で
# ADDLOCAL=Client,Server を流す (保守の install)。MSI は sshd のサービスを自動で作って起こし、22 番の受信の許可を作る。成功なら $true
function Invoke-MsiAddServer {
    param([string]$InstallDir, [string]$StateDir)
    $sshExe = Join-Path $InstallDir 'ssh.exe'
    $version = "$((Get-Item -LiteralPath $sshExe).VersionInfo.FileVersion)".Trim()
    if (-not $version) {
        Write-Step "$sshExe の版が読めないので、同じ版の MSI を取り直せない"
        return $false
    }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Step 'winget が見つからない。Microsoft Store の「アプリ インストーラー」を入れる'
        return $false
    }
    $dir = Join-Path $StateDir 'msi'
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    $null = New-Item -ItemType Directory -Force -Path $dir
    $arguments = Get-WingetDownloadArgs -PackageId $script:PackageId -Version $version -Directory $dir
    Write-Step "winget $($arguments -join ' ')"
    $download = Invoke-Winget -Arguments $arguments
    $download.Lines | Select-Object -Last 3 | ForEach-Object { Write-Step "  $_" }
    $msi = @(Get-ChildItem -LiteralPath $dir -Filter '*.msi' -File -ErrorAction SilentlyContinue)
    if (($download.ExitCode -ne 0) -or ($msi.Count -ne 1)) {
        Write-Step ('winget download で {0} の MSI を取れなかった (終了コード 0x{1:X8}・MSI {2} 個)。winget に入っている版が無いなら、先に Install-OpenSSH で固定した版に揃える' -f $version, $download.ExitCode, $msi.Count)
        return $false
    }
    $log = Join-Path $StateDir 'msiexec-add-server.log'
    $arguments = Get-MsiAddServerArgs -Msi $msi[0].FullName -Log $log
    Write-Step "msiexec $($arguments -join ' ')"
    $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $arguments -Wait -PassThru
    $why = Get-MsiexecResultText -ExitCode $process.ExitCode
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    if ($why) {
        Write-Step "msiexec が失敗した ($why。ログ: $log)"
        return $false
    }
    if ($process.ExitCode -eq 3010) { Write-Step 'msiexec: 再起動が要ると返した' }
    if (-not (Test-Path -LiteralPath (Join-Path $InstallDir 'sshd.exe'))) {
        Write-Step "msiexec は通ったが、$InstallDir\sshd.exe が無い (ログ: $log)"
        return $false
    }
    Write-Step "MSI に Server の機能を足した ($version)"
    $true
}

# 管理者で行う段: 拒否の規則・sshd_config・鍵・server・22 番の許可・ssh-agent・サービスを、この順に揃える。成功なら $true
# MSI は Server を足した時点で sshd を起こし、22 番の受信の許可も作るので、拒否の規則と sshd_config と鍵は server より先に置く
# (sshd は最初から dotfiles の設定で起き、LAN からの 22 番は拒否の規則が止める)
function Invoke-SshdFix {
    param([string]$InstallDir, [string]$User, [string]$CopyPath, [string]$StateDir)
    if (-not (Test-SshdUserName -Name $User)) {
        Write-Step "AllowUsers に書けないユーザー名: $User。何もしない"
        return $false
    }
    $copy = Read-KeysCopy -Path $CopyPath
    if (@($copy.Bad).Count -gt 0) {
        Write-Step "鍵の写し ($CopyPath) に読めない行がある。何もしない"
        return $false
    }
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
    $configText = Get-SshdConfigText -AllowUser $User
    $keysText = if ($copy.Managed) { Get-AdminKeysText -KeyLines @($copy.Lines) } else { Get-AdminKeysText -KeyLines @() -Managed $false }
    $sshDir = Join-Path $env:ProgramData 'ssh'
    $configPath = Join-Path $sshDir 'sshd_config'
    $keysPath = Join-Path $sshDir 'administrators_authorized_keys'
    $sshdExe = Join-Path $InstallDir 'sshd.exe'
    $stamp = Get-Date -Format 'yyyyMMddHHmmss'

    # 1. 拒否の規則 (sshd を動かす前に置く)
    foreach ($spec in @(Get-SshdFirewallSpecs)) {
        $rule = Read-FirewallRuleFacts -Name $spec.Name
        if (Test-FirewallRuleMatch -Spec $spec -Rule $rule) { continue }
        if ($rule) { Remove-NetFirewallRule -Name $spec.Name }
        $null = New-NetFirewallRule -Name $spec.Name -DisplayName $spec.DisplayName -Group $script:RuleGroup `
            -Direction Inbound -Action Block -Profile Any -Enabled True -Protocol $spec.Protocol `
            -LocalPort $spec.LocalPort -LocalAddress $spec.LocalAddress -RemoteAddress $spec.RemoteAddress
        Write-Step "拒否の規則を作った: $($spec.DisplayName)"
    }

    # 2. sshd_config (server を足す前に置く。MSI が起こした sshd が、既定の設定を写さずにこれを読む)
    New-SshProgramDataDir -Path $sshDir
    $configChanged = $false
    $current = Read-TextFile -Path $configPath
    if (-not ($current.Readable -and ((ConvertTo-Lf $current.Text) -ceq $configText))) {
        if ($current.Exists) {
            Move-Item -LiteralPath $configPath -Destination "$configPath.dotfiles-bak-$stamp"
            Write-Step "sshd_config を退避した: sshd_config.dotfiles-bak-$stamp"
        }
        Write-TextNoBom -Path $configPath -Text $configText
        Write-Step 'sshd_config を dotfiles の中身にした'
        $configChanged = $true
    }

    # 3. 鍵 (写しがあれば写しどおり。無ければ中身に触らず、無いときだけ空で作る)
    $keys = Read-TextFile -Path $keysPath
    $writeKeys = $false
    if ($copy.Managed) {
        if (-not ($keys.Exists -and $keys.Readable)) {
            $writeKeys = $true
        } else {
            $have = @(Get-KeyLines -Lines ((ConvertTo-Lf $keys.Text) -split "`n"))
            $writeKeys = -not (Compare-KeyLines -Want @($copy.Lines) -Have $have).Same
        }
    } elseif (-not $keys.Exists) {
        $writeKeys = $true
    }
    if ($writeKeys) {
        if ($keys.Exists) {
            # 名前を替えて退避する (権限は元のまま残る)
            Move-Item -LiteralPath $keysPath -Destination "$keysPath.dotfiles-bak-$stamp"
            Write-Step "administrators_authorized_keys を退避した: administrators_authorized_keys.dotfiles-bak-$stamp"
        }
        Write-TextNoBom -Path $keysPath -Text $keysText
        if ($copy.Managed) { Write-Step "administrators_authorized_keys に鍵の写しの $(@($copy.Lines).Count) 本を書いた" }
        else { Write-Step 'administrators_authorized_keys を空で作った (鍵は手で置く)' }
    }
    if (-not (Test-AdminOnlyAcl -Acl (Read-AclFacts -Path $keysPath).Value)) {
        Set-AdminOnlyAcl -Path $keysPath
        Write-Step 'administrators_authorized_keys の権限を管理者と SYSTEM だけにした'
    }

    # 4. 記録 (管理者でない -Check が、読めないファイルをこれと比べる)
    $keysSha = $null
    if ($copy.Managed) { $keysSha = Get-TextSha256 $keysText }
    Write-SshdRecord -Dir $StateDir -ConfigSha (Get-TextSha256 $configText) -KeysSha $keysSha

    # 5. server (MSI の Server の機能。足すと MSI が sshd を自動で作って起こす)
    if (-not (Test-Path -LiteralPath $sshdExe)) {
        if (-not (Invoke-MsiAddServer -InstallDir $InstallDir -StateDir $StateDir)) { return $false }
    }
    $svc = Get-Service -Name sshd -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Step 'sshd のサービスが無い (MSI が作らなかった)。何もしない'
        return $false
    }

    # 6. 22 番を許す受信の規則を無効にする (MSI が作る OpenSSH SSH Server Preview (sshd) は、Private のネットワークの全部から
    #    22 番を許し、修復や上げ直しのたびに有効へ戻る。外からの 22 番は拒否の規則が止めるが、許可も残さない)
    foreach ($r in @(Get-SshdAllowRules)) {
        Disable-NetFirewallRule -Name $r.Name
        Write-Step "22 番の受信の許可を無効にした: $($r.DisplayName)"
    }

    # 7. ssh-agent: MSI を流すと自動・実行中に戻りうる。1Password の agent と pipe を取り合うので、Install-OpenSSH と同じく
    #    停止・無効に戻す
    $agent = Get-Service -Name ssh-agent -ErrorAction SilentlyContinue
    if ($agent) {
        if ("$($agent.Status)" -ne 'Stopped') {
            Stop-Service -Name ssh-agent -Force
            Write-Step 'ssh-agent を止めた (MSI が起こした)'
        }
        if ("$($agent.StartType)" -ne 'Disabled') {
            Set-Service -Name ssh-agent -StartupType Disabled
            Write-Step 'ssh-agent を無効にした (MSI が戻した)'
        }
    }

    # 8. サービス: 自動で起こし、動かす。設定を書き直したら起こし直す
    if ("$($svc.StartType)" -ne 'Automatic') {
        Set-Service -Name sshd -StartupType Automatic
        Write-Step 'sshd を自動で起こすようにした'
    }
    try {
        $svc = Get-Service -Name sshd
        if ("$($svc.Status)" -eq 'Running') {
            if ($configChanged) {
                Restart-Service -Name sshd -Force
                Write-Step 'sshd を起こし直した (sshd_config を書き直したので)'
            }
        } else {
            Start-Service -Name sshd
            Write-Step 'sshd を起こした'
        }
        (Get-Service -Name sshd).WaitForStatus('Running', [TimeSpan]::FromSeconds(15))
    } catch {
        Write-Step "sshd が動かない: $($_.Exception.Message)"
        # 設定の誤りなら sshd -t が理由を出す
        $ErrorActionPreference = 'Continue'
        @(& $sshdExe -t 2>&1) | ForEach-Object { Write-Step "  sshd -t: $_" }
        return $false
    }
    $true
}

# 自分を管理者で起動し直して終わるのを待ち、子が書いたログを出す。成功なら $true
function Invoke-Elevated {
    param([string]$User, [string]$CopyPath, [string]$StateDir)
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
    $log = Join-Path $StateDir 'Install-Sshd.log'
    Remove-Item -LiteralPath $log -ErrorAction SilentlyContinue
    $hostExe = (Get-Process -Id $PID).Path
    # Start-Process は配列を空白でつなぐだけなので、パスは自分で "" で囲む (どれも \ で終わらない)
    $argumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath),
        '-LogPath', ('"{0}"' -f $log), '-KeysCopy', ('"{0}"' -f $CopyPath), '-AllowUser', $User,
        '-StateDir', ('"{0}"' -f $StateDir))
    Write-Host 'UAC で管理者の PowerShell を起動する (終わると閉じる)。Windows のデスクトップに UAC の確認が出たら「はい」を押す'
    try {
        $process = Start-Process -FilePath $hostExe -ArgumentList $argumentList -Verb RunAs -Wait -PassThru
    } catch {
        Write-Host "管理者で起動できなかった (UAC で断った?): $($_.Exception.Message)"
        return $false
    }
    if (Test-Path -LiteralPath $log) {
        Get-Content -LiteralPath $log -Encoding utf8 | ForEach-Object { Write-Host "  [管理者] $_" }
    }
    $process.ExitCode -eq 0
}

function Invoke-InstallSshd {
    param([switch]$Check, [switch]$IfMissing, [string]$KeysCopy, [string]$AllowUser, [string]$StateDir, [string]$LogPath)
    $installDir = Join-Path $env:ProgramFiles 'OpenSSH'
    if (-not $StateDir) { $StateDir = Join-Path $env:LOCALAPPDATA 'dotfiles\sshd' }
    if (-not $KeysCopy) { $KeysCopy = Join-Path $env:LOCALAPPDATA 'dotfiles\sshd\authorized_keys' }
    if (-not $AllowUser) { $AllowUser = "$env:USERNAME".ToLowerInvariant() }

    if ($LogPath) {
        # 管理者で起動し直された子: 揃える段だけをして、結果を $LogPath に書く
        $script:StepLog = $LogPath
        if (Invoke-SshdFix -InstallDir $installDir -User $AllowUser -CopyPath $KeysCopy -StateDir $StateDir) { return 0 }
        return 1
    }

    $facts = Get-SshdFacts -InstallDir $installDir -CopyPath $KeysCopy -StateDir $StateDir -User $AllowUser
    $verdict = Get-SshdVerdict -Facts $facts
    Write-SshdState -Verdict $verdict
    $code = Get-SshdExitCode -Verdict $verdict
    # -Check は何も変えない。-IfMissing は入っていないときだけ入れ、入っていれば -Check と同じ
    if ($Check -or ($IfMissing -and ($code -ne 3))) {
        $message = Get-SshdCheckMessage -Verdict $verdict
        if ($code -eq 0) { Write-Host $message } else { Write-Host $message -ForegroundColor Yellow }
        return $code
    }
    if ($code -eq 0) {
        Write-Host '揃っている。何もしない'
        return 0
    }
    if ($verdict.Blocked) {
        Write-Host (Get-SshdCheckMessage -Verdict $verdict) -ForegroundColor Yellow
        return 1
    }

    if (Test-IsAdmin) {
        $script:StepLog = $null
        [void](Invoke-SshdFix -InstallDir $installDir -User $AllowUser -CopyPath $KeysCopy -StateDir $StateDir)
    } else {
        [void](Invoke-Elevated -User $AllowUser -CopyPath $KeysCopy -StateDir $StateDir)
    }

    # 揃ったかを読み直して確かめる
    Write-Host ''
    $after = Get-SshdVerdict -Facts (Get-SshdFacts -InstallDir $installDir -CopyPath $KeysCopy -StateDir $StateDir -User $AllowUser)
    Write-SshdState -Verdict $after
    if ((Get-SshdExitCode -Verdict $after) -eq 0) {
        if ($code -eq 3) { Write-Host '入れた' } else { Write-Host '揃った' }
        Write-Host 'iPhone の Herdr のアプリや hc からつなぐときは、この PC で Herdr を開いたままにしておく (管理者の SSH の会話は昇格する。そこから core を起こすと、デスクトップの会話をふさぎうる)'
        return 0
    }
    Write-Host (Get-SshdCheckMessage -Verdict $after) -ForegroundColor Yellow
    return 1
}

# dot-source されたとき (テスト) は関数だけを読み、本体は走らせない
# 思わぬ例外は受け止めて終了コード 2 で終える。受け止めないと exit まで届かず、
# -Command から呼んだとき外側の exit $LASTEXITCODE が中の msiexec の 0 を返して成功に見える
if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest
    try {
        exit (Invoke-InstallSshd -Check:$Check -IfMissing:$IfMissing -KeysCopy $KeysCopy -AllowUser $AllowUser -StateDir $StateDir -LogPath $LogPath)
    } catch {
        Write-Host "エラーで止まった: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace
        exit 2
    }
}
