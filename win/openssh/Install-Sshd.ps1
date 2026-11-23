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
   (同じ ProductCode なので保守の install になり、Server が足される)。保守の install は、入れたときに登録した MSI の名前
   (SourceList の PackageName) で原本を探すので、取り直した MSI をその名前に写してから渡す (製品や PackageCode が違えば流さずに
   止まる)。Windows Installer の手元の写しは cab が抜かれているので、ProductCode だけでは足せない。winget の install と pin には
   触らない。Windows の機能 (System32) の OpenSSH Server とは二重にしない
2. C:\ProgramData\ssh\sshd_config: dotfiles が書く中身 (Get-SshdConfigText。鍵だけ・AllowUsers でユーザーを限り、Match Address の
   DenyUsers で入ってよい送り元の外を断る) に
   する。違えば sshd_config.dotfiles-bak-<日時> に退避して書き直す。MSI は Server を足した時点で sshd を起こし、sshd は
   sshd_config が無ければ既定 (パスワードでも入れる) を写すので、server を足す前に書いておく (ディレクトリが無ければ、sshd が作るのと
   同じ権限で作る)。AllowUsers のユーザーと入ってよい送り元は、ユーザーと送り元の写し (-AllowCopy。受け持ちが runner のホストで、
   runner の手順 sshd がホストの値の [sshd] allowUsers・allowFrom から置く) があればその値、無ければ既定 (このスクリプトを流したユーザーと、
   tailnet と localhost)。書き換える前に、作った中身を sshd -t (使い捨てのホストの鍵を -h で渡す。Invoke-SshdConfigTest) で試し、断られたら
   書き換えずに止まる (sshd.exe がまだ無い、server を足す前は試せないので、そう出して書く)
3. Windows Firewall: 拒否の規則を 3 つ置き (Get-SshdFirewallSpecs)、22 番を許す受信の規則 (MSI が作るものなど) を無効にする。
   block は allow より強いので、Tailscale の ACL を誤っても、tailnet からは 22 番にしか届かず、22 番には tailnet と localhost
   からしか届かない
4. C:\ProgramData\ssh\administrators_authorized_keys (Windows の管理者の鍵の置き場): 鍵の写し (-KeysCopy。受け持ちが WSL の
   ホストは WSL の setup が、runner のホストは runner の手順 sshd が置く) があれば、その中身どおりに書く (写しに無い鍵は消す。
   元は .dotfiles-bak-<日時> に退避する)。写しが無ければ中身に触らず、ファイルが無ければ空で作る。どちらも、読み書きできるのを管理者と SYSTEM だけにする
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
鍵の写し。既定は %LOCALAPPDATA%\dotfiles\sshd\authorized_keys。受け持ちが WSL のホストは setup の bootstrap-windows-sshd.sh が
ホストの値の wsl.windowsFiles.sshd.authorizedKeys から、受け持ちが runner のホストは runner の手順 sshd が dotfiles-private の
win/hosts/<ユーザー>@<PC>.toml の [sshd] authorizedKeys から置く (どちらも null・書かないホストでは置かない)。

.PARAMETER KeysFrom
鍵の写しを置く受け持ち (runner・wsl)。鍵の足し方・直し方の案内 (※ の行と締めの行) を、TOML の値と dotfiles apply か、Nix の値と
WSL の setup にする。runner の手順 sshd が渡す。渡さなければ写しの頭の印 (runner が書く) で見分け、写しが無ければ両方を出す。

.PARAMETER AllowCopy
ユーザーと送り元の写し (JSON)。既定は %LOCALAPPDATA%\dotfiles\sshd\allow.json。受け持ちが runner のホストで、runner の手順 sshd が
dotfiles-private の win/hosts/<ユーザー>@<PC>.toml の [sshd] allowUsers・allowFrom から置く (どちらも書かないホストでは置かない)。
欄が null (書いていない) なら既定 (-AllowUser と、tailnet と localhost)、[] なら誰も・どこからも入れない。管理者で起動し直した子には、
親の場所を渡す。

.PARAMETER AllowUser
ユーザーと送り元の写しに allowUsers が無いときに AllowUsers に書く Windows のユーザー。既定はこのスクリプトを流しているユーザー
(小文字にする)。管理者で起動し直した子に、親のユーザーを渡す内部の引数 (sshd はログインした本当の名前と比べるので、別の名前は渡せない)。

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
    [ValidateSet('runner', 'wsl')]
    [string]$KeysFrom,
    [string]$AllowCopy,
    [string]$AllowUser,
    [string]$StateDir,
    [string]$LogPath
)

# ---------------------------------------------------------------------------
# 決まり
# ---------------------------------------------------------------------------

# tailnet のアドレス (Tailscale が端末に配る CGNAT の範囲と ULA の範囲)。拒否の規則の LocalAddress (この PC の側のアドレス) に使う
$script:TailnetAddresses = @('100.64.0.0/10', 'fd7a:115c:a1e0::/48')
# 入ってよい送り元の既定 (ユーザーと送り元の写しに allowFrom が無いとき): tailnet と localhost。tailnet の 2 つは上と同じ範囲だが、こちらは
# 相手の側のアドレス (sshd_config の Match Address)。ホストの値で変えるのはこちらだけで、拒否の規則には混ぜない (win/README.md の「sshd」)
$script:DefaultAllowFrom = @('100.64.0.0/10', 'fd7a:115c:a1e0::/48', '127.0.0.1', '::1')
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
# 取り直した MSI を落とすディレクトリの権限 (SYSTEM と管理者だけが全部。親から継がず、中に落ちるファイルには継がせる)。winget download は
# 管理者の PowerShell (BA) が書き、msiexec の install は Windows Installer のサービス (SY) が読む。利用者 (AU) には読ませもしない
$script:AdminDirSddl = 'O:BAD:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)'
# 管理者 (BUILTIN\Administrators) と SYSTEM の SID (表示の言語によらない)
$script:AdminSids = @('S-1-5-32-544', 'S-1-5-18')
# runner の手順 sshd が鍵の写しの頭に書く印 (win/runner/src/steps/sshd_keys.rs の RUNNER_MARK と同じ字)
$script:RunnerCopyMark = '# dotfiles-keys-from: runner'
# 鍵の種類 (authorized_keys の行で、オプションの後ろに来る語)
$script:KeyTypePattern = 'ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(?:256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com'

# ---------------------------------------------------------------------------
# 副作用の無い関数 (Install-Sshd.Tests.ps1 で確かめる)
# ---------------------------------------------------------------------------

# AllowUsers に書けるユーザー名か (小文字にした後の名前)。空白・パターンの文字 (* ? ! ,)・@・" と改行を含む名前は、sshd_config の
# 1 語に書けないので断る。外から読んだ値 (写しの JSON など) を検める正規表現は \z で終える (.NET の $ は末尾の改行の前でも当たり、
# "alice`n" を通す。通すと sshd_config の行が割れ、sshd が起動しなくなる)
function Test-SshdUserName {
    param([string]$Name)
    "$Name" -cmatch '^[a-z0-9][a-z0-9._-]*\z'
}

# 表に出す値 (写しを手で書き換えた値)。制御文字を \n・\r・\t・\xNN の字にする (※ の行が割れないように)
function ConvertTo-ShownValue {
    param([string]$Value)
    [regex]::Replace("$Value", '[\x00-\x1f\x7f]', {
            param($m)
            switch ([int][char]$m.Value) {
                10 { '\n' }
                13 { '\r' }
                9 { '\t' }
                default { '\x{0:x2}' -f [int][char]$m.Value }
            }
        })
}

# sshd_config の Match Address に書ける送り元か: IPv4・IPv6 のアドレスか CIDR (<アドレス>/<長さ>) だけ。IPv4 は 10 進の 4 つの組 (頭に 0 を
# 付けない)、長さは IPv4 で 0〜32・IPv6 で 0〜128 (頭に 0 を付けない)、CIDR のアドレスは範囲の頭 (長さより後ろのビットが 0)。sshd は長さの
# 誤りと後ろのビットが立った CIDR を Match Address の書き方の誤りとして断り、起動しなくなる (OpenSSH の addr.c の addr_pton_cidr)。
# ! * , と空白・改行・ゾーン (%) は書けない (sshd のパターン・否定・区切りにしない。改行は行を割る)。正規表現は Test-SshdUserName と同じく
# \z で終える。win/runner/src/host.rs の sshd_from_check と同じ見方
function Test-SshdFromAddress {
    param([string]$Address)
    if (-not ("$Address" -cmatch '^([0-9A-Fa-f:.]+)(?:/(0|[1-9][0-9]{0,2}))?\z')) { return $false }
    $addr = $Matches[1]
    $lenText = $Matches[2]
    $octet = '(?:25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'
    $ip = $null
    if ($addr -cmatch "^$octet(?:\.$octet){3}\z") {
        $bits = 32
    } elseif ($addr.Contains(':') -and [System.Net.IPAddress]::TryParse($addr, [ref]$ip) -and ("$($ip.AddressFamily)" -eq 'InterNetworkV6')) {
        $bits = 128
    } else {
        return $false
    }
    if (-not $lenText) { return $true }
    if ([int]$lenText -gt $bits) { return $false }
    # 範囲の頭のアドレスか (範囲の区間の下の端が、書いたアドレスと同じ)
    $range = ConvertTo-AddressInterval -Address "$addr/$lenText"
    $one = ConvertTo-AddressInterval -Address $addr
    ($null -ne $range) -and ($null -ne $one) -and ($range.Lo -eq $one.Lo)
}

# CRLF を LF にそろえる (メモ帳で保存し直すと CRLF になる。sshd はどちらでも読むので、改行の違いはずれと数えない)
function ConvertTo-Lf {
    param([string]$Text)
    "$Text" -replace "`r`n", "`n"
}

# dotfiles が書く sshd_config の中身 (改行は LF)。$AllowUsers (無ければ誰も) だけを、$AllowFrom (無ければどこからも) から来たときだけ入れる。
# 既定の値 (ユーザー 1 人と $script:DefaultAllowFrom の並び) では、値をホストの値で持つ前の中身と 1 バイトも違わない (コメントも。揃えたときの
# 記録の sha256 が変わらず、Install-Sshd を流し直さずに済む)。ほかの値のときだけ、コメントの言い方を値に合わせる。
# 接続元は AllowUsers の user@CIDR でなく、Match Address で絞る。Win32-OpenSSH は sshd_config を読んだ後、AllowUsers・DenyUsers・
# AllowGroups・DenyGroups の語ごとに最初の / を \ に替える (domain/user を domain\user と読むため。PowerShell/openssh-portable の
# servconf.c の parse_server_config の WINDOWS の分岐)。user@100.64.0.0/10 は user@100.64.0.0\10 になって CIDR として読めず、文字の
# パターンとしても当たらないので、tailnet からのログインを全部断る。Match Address はこの読み替えを通らず、CIDR がそのまま効く。
# sshd はログインのたびに Match を当ててから AllowUsers・DenyUsers を見る (auth.c の getpwnamallow)。AllowUsers は引数の無い行を書けない
# (sshd が起動しない) ので、ユーザーが 0 人なら代わりに DenyUsers * を書く。送り元が 0 なら Match Address * (どこから来ても DenyUsers *)
function Get-SshdConfigText {
    param([Alias('AllowUser')][string[]]$AllowUsers, [string[]]$AllowFrom = $script:DefaultAllowFrom)
    $users = @($AllowUsers | Where-Object { $_ })
    $from = @($AllowFrom | Where-Object { $_ })
    $defaultFrom = ($from -join ',') -ceq (@($script:DefaultAllowFrom) -join ',')
    $outside = (@('*') + @($from | ForEach-Object { "!$_" })) -join ','
    if ($defaultFrom) {
        $where = 'Tailscale (the tailnet) and localhost'
        $matchNote = '# Deny everyone unless the connection comes from the tailnet (100.64.0.0/10, fd7a:115c:a1e0::/48) or localhost.'
    } elseif ($from.Count -gt 0) {
        $where = 'the addresses that the host values allow'
        $matchNote = '# Deny everyone unless the connection comes from one of the addresses that the host values allow.'
    } else {
        $where = 'nowhere (the host values allow no address)'
        $matchNote = '# Deny everyone from every address (the host values allow no address).'
    }
    switch ($users.Count) {
        0 {
            $who = 'nobody: DenyUsers * instead'
            $userLines = @(
                '# Nobody: the host values list no user (an AllowUsers line needs at least one name, so deny everyone).'
                'DenyUsers *'
            )
        }
        default {
            $who = if ($users.Count -eq 1) { 'this user only' } else { 'these users only' }
            $only = if ($users.Count -eq 1) { 'this user. Where it may' } else { 'these users. Where they may' }
            $userLines = @(
                "# Only $only come from is limited by `"Match Address`" below, not by user@CIDR here:"
                '# Win32-OpenSSH turns the first "/" of each AllowUsers word into "\" (for domain/user), so CIDR never matches.'
                "AllowUsers $($users -join ' ')"
            )
        }
    }
    $lines = @(
        '# Written by dotfiles (Install-Sshd.ps1). Do not edit by hand: Install-Sshd -Check reports the difference,'
        '# and Install-Sshd moves this file to sshd_config.dotfiles-bak-<time> and writes it again.'
        '# Why it looks like this: dotfiles win/README.md, section "sshd".'
        '#'
        "# Public-key logins only, and only from $where. sshd listens on all"
        '# addresses (with ListenAddress bound to the Tailscale IP, sshd fails at boot when that IP is not up yet).'
        "# AllowUsers ($who), Match Address + DenyUsers and the Windows Firewall block rules limit who and"
        '# where logins can come from.'
        ''
        'Port 22'
        ''
        '# Public keys only: no passwords, no keyboard-interactive'
        'PubkeyAuthentication yes'
        'PasswordAuthentication no'
        'KbdInteractiveAuthentication no'
        'AuthenticationMethods publickey'
        ''
    ) + $userLines + @(
        ''
        'AuthorizedKeysFile .ssh/authorized_keys'
        ''
        'Subsystem sftp sftp-server.exe'
        ''
        $matchNote
        '# Match Address reads CIDR as written (also on Windows), and sshd applies Match before AllowUsers/DenyUsers.'
        "Match Address $outside"
        '       DenyUsers *'
        ''
        '# Administrators read their keys from ProgramData, not from the user profile (the Win32-OpenSSH default)'
        'Match Group administrators'
        '       AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys'
    )
    ($lines -join "`n") + "`n"
}

# ユーザーと送り元の写し (JSON を ConvertFrom-Json で読んだもの) を、AllowUsers のユーザー (Users) と入ってよい送り元 (Addresses) と、読めない
# 値の理由 (Bad) に分ける。Users・Addresses は、欄が無いか null なら $null (ホストの値に書いていない)、list ならその値 ([] は 0)。書ける値は
# Test-SshdUserName と Test-SshdFromAddress (runner がホストの値を読む時点で止めるので、Bad になるのは写しを手で書き換えたとき)
function ConvertFrom-AllowCopy {
    param($Json)
    if (($null -eq $Json) -or ($Json -isnot [System.Management.Automation.PSCustomObject])) {
        return [pscustomobject]@{ Users = $null; Addresses = $null; Bad = @('JSON の object でない') }
    }
    $version = $Json.PSObject.Properties['version']
    if ((-not $version) -or ("$($version.Value)" -ne '1')) {
        return [pscustomobject]@{ Users = $null; Addresses = $null; Bad = @('version が 1 でない') }
    }
    $bad = [System.Collections.Generic.List[string]]::new()
    $read = {
        param([string]$Key, [scriptblock]$Ok, [string]$Hint)
        $p = $Json.PSObject.Properties[$Key]
        if ((-not $p) -or ($null -eq $p.Value)) { return [pscustomobject]@{ Set = $false; Items = @() } }
        if ($p.Value -isnot [array]) {
            $bad.Add("$Key が list でも null でもない")
            return [pscustomobject]@{ Set = $true; Items = @() }
        }
        $items = @($p.Value)
        foreach ($item in $items) {
            if (($item -isnot [string]) -or (-not (& $Ok $item))) { $bad.Add("$Key の $(ConvertTo-ShownValue $item) ($Hint)") }
        }
        [pscustomobject]@{ Set = $true; Items = $items }
    }
    $u = & $read 'allowUsers' { param($v) Test-SshdUserName -Name $v } '英小文字・数字・. _ - の名前だけ'
    $a = & $read 'allowFrom' { param($v) Test-SshdFromAddress -Address $v } 'IPv4・IPv6 のアドレスか、範囲の頭のアドレスで書いた CIDR だけ'
    # 代入で受ける (if の出力にすると、空の list が $null に崩れる)
    $users = $null
    if ($u.Set) { $users = @($u.Items) }
    $addresses = $null
    if ($a.Set) { $addresses = @($a.Items) }
    [pscustomobject]@{ Users = $users; Addresses = $addresses; Bad = @($bad) }
}

# sshd_config に書くユーザーと送り元を決める。写し ($Allow。Read-AllowCopy) の値があればそれ、無ければ既定 ($User と $script:DefaultAllowFrom)。
# UsersSet・AddressesSet はホストの値に書いてあるか
function Resolve-SshdAccess {
    param($Allow, [string]$User)
    $usersSet = $null -ne $Allow.Users
    $addressesSet = $null -ne $Allow.Addresses
    [pscustomobject]@{
        Users        = @(if ($usersSet) { $Allow.Users } else { $User })
        UsersSet     = $usersSet
        Addresses    = @(if ($addressesSet) { $Allow.Addresses } else { $script:DefaultAllowFrom })
        AddressesSet = $addressesSet
    }
}

# 送り元が、拒否の規則 dotfiles-sshd-outside-tcp22 の止める範囲 ($script:OutsideAddresses。tailnet と localhost の外) にかかるか。かかる分の
# 22 番は拒否の規則が止めるので、sshd_config に書いても届かない (送り元の値で広げられるのは、tailnet と localhost の中だけ)
function Test-SshdFromOutside {
    param([string]$Address)
    $iv = ConvertTo-AddressInterval -Address $Address
    if ($null -eq $iv) { return $false }
    foreach ($o in @($script:OutsideAddresses)) {
        $ov = ConvertTo-AddressInterval -Address $o
        if (($ov.Family -eq $iv.Family) -and ($iv.Lo -le $ov.Hi) -and ($ov.Lo -le $iv.Hi)) { return $true }
    }
    $false
}

# ユーザーと送り元の ※ の行 (鍵の ※ の行と同じく、使う値をいつも出す)。$Access は Resolve-SshdAccess、$From は受け持ち (runner・wsl・'')。
# ホストの値に書いていない (既定の) 値があれば、変え方を受け持ちごとに添える
function Get-SshdAccessNotes {
    param($Access, [string]$From)
    $users = @($Access.Users)
    $addresses = @($Access.Addresses)
    $why = {
        param([bool]$Set, [int]$Count, [string]$Default, [string]$Zero)
        if (-not $Set) { return "ホストの値に書いていない。既定: $Default" }
        if ($Count -eq 0) { return "ホストの値が []。$Zero" }
        'ホストの値'
    }
    $usersText = if ($users.Count -gt 0) { $users -join '・' } else { '無し' }
    $addressesText = if ($addresses.Count -gt 0) { $addresses -join '・' } else { '無し' }
    "※ AllowUsers: $usersText ($(& $why $Access.UsersSet $users.Count 'Install-Sshd を流したユーザー' '誰も入れない'))"
    "※ 送り元: $addressesText ($(& $why $Access.AddressesSet $addresses.Count 'tailnet と localhost' 'どこからも入れない'))"
    if ((-not $Access.UsersSet) -or (-not $Access.AddressesSet)) {
        switch ($From) {
            'runner' { '※ ユーザー・送り元を変えるなら、ホストの値 (dotfiles-private の win/hosts/<ユーザー>@<PC>.toml の [sshd] allowUsers・allowFrom) に書いて dotfiles apply を流し、Install-Sshd で揃える' }
            'wsl' { '※ 受け持ちが WSL の setup のホストでは、ユーザー・送り元は既定のまま (ホストの値の [sshd] allowUsers・allowFrom で変えられるのは、受け持ちが runner のホストだけ)' }
            default { '※ ユーザー・送り元は、受け持ちが runner のホストなら、ホストの値 (dotfiles-private の win/hosts/<ユーザー>@<PC>.toml の [sshd] allowUsers・allowFrom) で変えられる (受け持ちが WSL の setup のホストは既定のまま)' }
        }
    }
    if ($Access.AddressesSet) {
        foreach ($a in @($addresses | Where-Object { Test-SshdFromOutside -Address $_ })) {
            "※ 送り元 $a は tailnet と localhost の外を含む。外から来る 22 番は拒否の規則 (dotfiles-sshd-outside-tcp22) が止めるので、sshd に届かない"
        }
    }
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

# 鍵の指紋 (ssh-keygen -l と同じ SHA256:<base64>)。base64 が読めなければ $null
function Get-KeyFingerprint {
    param([string]$Line)
    if (-not ("$Line" -cmatch "(?:^|\s)(?:$script:KeyTypePattern)\s+([A-Za-z0-9+/]+={0,3})(?:\s|$)")) { return $null }
    $b64 = $Matches[1]
    try {
        $blob = [Convert]::FromBase64String($b64)
    } catch {
        return $null
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        'SHA256:' + ([Convert]::ToBase64String($sha.ComputeHash($blob))).TrimEnd('=')
    } finally {
        $sha.Dispose()
    }
}

# 表に出す鍵の名札: コメント (無ければ base64 の末尾 8 字) と鍵の種類と指紋。from= が無ければそう添える (UAC の前に、覚えのない鍵が無いかを見分ける)
function Get-KeyLabel {
    param([string]$Line)
    if ("$Line" -cmatch "(?:^|\s)($script:KeyTypePattern)\s+([A-Za-z0-9+/]+={0,3})(?:\s+(.*))?$") {
        $type = $Matches[1]
        $b64 = $Matches[2]
        $comment = "$($Matches[3])".Trim()
        $name = if ($comment) { $comment } else { '…' + $b64.Substring([Math]::Max(0, $b64.Length - 8)) }
        $fp = Get-KeyFingerprint -Line $Line
        $fpText = if ($fp) { " $fp" } else { '' }
        $from = if ("$Line" -match '(^|[\s,])from="') { '' } else { '・from= 無し' }
        return "$name ($type$fpText$from)"
    }
    '(読めない行)'
}

# from= の無い鍵の行か (オプションの from="…" で、鍵を使える端末を縛っていない)
function Test-KeyWithoutFrom {
    param([string]$Line)
    -not ("$Line" -match '(^|[\s,])from="')
}

# 鍵の写しを置く受け持ち: -KeysFrom があればそれ、無ければ写しの頭の印 (runner が書く) で runner、印の無い写しは wsl、写しが無ければ
# '' (分からない)
function Resolve-KeysFrom {
    param([string]$KeysFrom, [bool]$Exists, [string[]]$Lines)
    if ($KeysFrom) { return $KeysFrom }
    if (-not $Exists) { return '' }
    if (@($Lines | Where-Object { "$_".Trim() -ceq $script:RunnerCopyMark }).Count -gt 0) { return 'runner' }
    'wsl'
}

# 鍵の足し方・直し方の案内 (受け持ちごと)。Kind は zero (鍵が 0 本)・null (写しが無い)・bad (写しに読めない行がある)
function Get-KeysHint {
    param([string]$Kind, [string]$From, [string]$CopyPath)
    switch ("$Kind/$From") {
        'zero/runner' { return '※ 鍵が 0 本 (誰も入れない)。入れる端末の公開鍵は、ホストの値 (dotfiles-private の win/hosts/<ユーザー>@<PC>.toml の [sshd] authorizedKeys) に足して dotfiles apply を流し、Install-Sshd で揃える' }
        'null/runner' { return "※ 鍵の写し ($CopyPath) が無いので、dotfiles は鍵を置かない (ホストの値の win/hosts/<ユーザー>@<PC>.toml に [sshd] authorizedKeys が無い。書いて dotfiles apply を流すと runner が写しを置く)" }
        'null/' { return "※ 鍵の写し ($CopyPath) が無いので、dotfiles は鍵を置かない (受け持ちが runner なら dotfiles-private の win/hosts/<ユーザー>@<PC>.toml に [sshd] authorizedKeys が無い。WSL の setup ならホストの値の wsl.windowsFiles.sshd.authorizedKeys が null)" }
        'bad/runner' { return '⚠️ 鍵の写しに読めない行がある → ホストの値 (dotfiles-private の win/hosts の TOML の [sshd] authorizedKeys) を直して dotfiles apply を流し直す ⚠️' }
        { $_ -like 'zero/*' } { return '※ 鍵が 0 本 (誰も入れない)。入れる端末の公開鍵は、ホストの値 (dotfiles-private の wsl.windowsFiles.sshd.authorizedKeys) に足して setup を流す' }
        { $_ -like 'null/*' } { return "※ 鍵の写し ($CopyPath) が無いので、dotfiles は鍵を置かない (ホストの値の wsl.windowsFiles.sshd.authorizedKeys が null)" }
        default { return '⚠️ 鍵の写しに読めない行がある → ホストの値 (wsl.windowsFiles.sshd.authorizedKeys) を直して setup を流し直す ⚠️' }
    }
}

# administrators_authorized_keys に書く中身 (改行は LF)。$Managed が偽なら、鍵の写しが無いときに空で作る中身。$From は写しを置く受け持ち
# (runner なら見出しに TOML の値を書く。ほかは前からの見出しのまま。揃えたときの記録の sha256 が変わらないように)
function Get-AdminKeysText {
    param([string[]]$KeyLines, [bool]$Managed = $true, [string]$From = 'wsl')
    if ($Managed -and $From -eq 'runner') {
        $head = @(
            '# Written by dotfiles (Install-Sshd.ps1) from the keys copy that the Windows runner puts in %LOCALAPPDATA%\dotfiles\sshd\authorized_keys.'
            '# Add or remove keys in the host values (dotfiles-private, win/hosts/<user>@<pc>.toml [sshd] authorizedKeys), not here.'
        )
    } elseif ($Managed) {
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

# Windows Firewall のアドレスの書き方 (1 つの IP・範囲 a-b・サブネット a/長さ・a/マスク) を、数の区間 (Family・Lo・Hi) にする。
# Get-NetFirewallAddressFilter は 100.64.0.0/10 を 100.64.0.0/255.192.0.0 と返し、範囲をサブネットの形で返すこともあるので、書き方に
# よらず数で比べる。IP として読めないもの (Any・LocalSubnet などの語) は $null
function ConvertTo-AddressInterval {
    param([string]$Address)
    $a = "$Address".Trim()
    $num = {
        param([string]$text)
        $ip = $null
        if (-not [System.Net.IPAddress]::TryParse($text, [ref]$ip)) { return $null }
        $bytes = $ip.GetAddressBytes()
        $le = [byte[]]::new($bytes.Length + 1)
        for ($i = 0; $i -lt $bytes.Length; $i++) { $le[$i] = $bytes[$bytes.Length - 1 - $i] }
        [pscustomobject]@{ Family = "$($ip.AddressFamily)"; Value = [System.Numerics.BigInteger]::new($le); Bits = $bytes.Length * 8 }
    }
    if ($a -match '^([^/-]+)-([^/-]+)$') {
        $loText = $Matches[1]
        $hiText = $Matches[2]
        $lo = & $num $loText
        $hi = & $num $hiText
        if (($null -eq $lo) -or ($null -eq $hi) -or ($lo.Family -ne $hi.Family) -or ($lo.Value -gt $hi.Value)) { return $null }
        return [pscustomobject]@{ Family = $lo.Family; Lo = $lo.Value; Hi = $hi.Value }
    }
    if ($a -match '^([^/]+)/(.+)$') {
        $netText = $Matches[1]
        $lenText = $Matches[2]
        $net = & $num $netText
        if ($null -eq $net) { return $null }
        $len = $null
        if ($lenText -match '^\d+$') {
            $len = [int]$lenText
        } else {
            $mask = & $num $lenText
            if (($null -eq $mask) -or ($mask.Family -ne 'InterNetwork') -or ($net.Family -ne 'InterNetwork')) { return $null }
            $len = 0
            $bits = $mask.Value
            for ($i = 31; $i -ge 0; $i--) {
                if (($bits / [System.Numerics.BigInteger]::Pow(2, $i)) % 2 -eq 1) { $len++ } else { break }
            }
        }
        if (($len -lt 0) -or ($len -gt $net.Bits)) { return $null }
        $size = [System.Numerics.BigInteger]::Pow(2, $net.Bits - $len)
        $lo = $net.Value - ($net.Value % $size)
        return [pscustomobject]@{ Family = $net.Family; Lo = $lo; Hi = $lo + $size - 1 }
    }
    $one = & $num $a
    if ($null -eq $one) { return $null }
    [pscustomobject]@{ Family = $one.Family; Lo = $one.Value; Hi = $one.Value }
}

# アドレスの並びを、比べられる 1 つの形にする: IP は family ごとに区間を並べて重なり・隣り合いをつなぎ、語 (Any など) は小文字にする
function ConvertTo-CanonicalAddressList {
    param([string[]]$Addresses)
    $words = [System.Collections.Generic.List[string]]::new()
    $intervals = [System.Collections.Generic.List[object]]::new()
    foreach ($a in @($Addresses | Where-Object { "$_" })) {
        $iv = ConvertTo-AddressInterval -Address $a
        if ($null -eq $iv) { $words.Add("$a".Trim().ToLowerInvariant()) } else { $intervals.Add($iv) }
    }
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($family in @('InterNetwork', 'InterNetworkV6')) {
        $cur = $null
        foreach ($iv in @($intervals | Where-Object { $_.Family -eq $family } | Sort-Object { $_.Lo.ToString().PadLeft(40, '0') })) {
            if (($null -ne $cur) -and ($iv.Lo -le ($cur.Hi + 1))) {
                if ($iv.Hi -gt $cur.Hi) { $cur.Hi = $iv.Hi }
            } else {
                if ($null -ne $cur) { $out.Add("$($family):$($cur.Lo)-$($cur.Hi)") }
                $cur = [pscustomobject]@{ Lo = $iv.Lo; Hi = $iv.Hi }
            }
        }
        if ($null -ne $cur) { $out.Add("$($family):$($cur.Lo)-$($cur.Hi)") }
    }
    @(@($words | Sort-Object -Unique) + @($out))
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

# 読んだ規則 ($Rule。Enabled・Direction・Action・Profile・Protocol・LocalPort・LocalAddress・RemoteAddress と、絞りの条件 Program・
# Service・InterfaceAlias・InterfaceType を文字列で持つ) が、spec の拒否の規則と同じか。規則が無ければ偽。絞りの条件が Any でなければ
# (画面で program などを足された)、sshd に効かないことがあるので同じとみない
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
    ((& $addrs $Rule.RemoteAddress) -eq (& $addrs $Spec.RemoteAddress)) -and
    ((& $ports $Rule.Program) -eq 'any') -and
    ((& $ports $Rule.Service) -eq 'any') -and
    ((& $ports $Rule.InterfaceAlias) -eq 'any') -and
    ((& $ports $Rule.InterfaceType) -eq 'any')
}

# 22 番を許す、有効な受信の規則を選ぶ。$Rules は Windows Firewall の COM (HNetCfg.FwPolicy2 の Rules) の規則か、同じ名前の値を持つもの:
# Name (表示の名前)・Enabled・Direction (1 = 受信)・Action (1 = 許可)・Protocol (6 = TCP。256 = すべて)・LocalPorts (, 区切りの文字列。
# すべてなら空か *)・ApplicationName。選ぶのは、TCP の 22 番を名指しする規則と、sshd.exe を名指しする規則。Disable は無効にするもの
# (sshd.exe の規則と、ポートが 22 番だけの規則。22 番とほかのポートを並べた規則は、ほかのポートまで閉じないよう残す)。Tailscale-In の
# ように全ポートを許す規則と、範囲 (1-1024 など) で許す規則は数えない (22 番は拒否の規則がそれより強い)。Rule は元の規則 (無効にするときに
# その Enabled を書く)
function Select-SshdAllowRules {
    param([object[]]$Rules)
    $picked = @(foreach ($r in @($Rules)) {
            if ($null -eq $r) { continue }
            if (("$($r.Enabled)" -ne 'True') -or ("$($r.Direction)" -ne '1') -or ("$($r.Action)" -ne '1')) { continue }
            $ports = @("$($r.LocalPorts)" -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
            $tcp22 = ("$($r.Protocol)" -eq '6') -and ($ports -contains '22')
            $sshd = "$($r.ApplicationName)" -like '*\OpenSSH\sshd.exe'
            if (-not ($tcp22 -or $sshd)) { continue }
            [pscustomobject]@{
                DisplayName = "$($r.Name)"
                Disable     = [bool]($sshd -or ($ports.Count -eq 1))
                Rule        = $r
            }
        })
    @($picked | Sort-Object -Property DisplayName)
}

# 例外 ($ErrorRecord) を表の 1 行に収める: 「<落ちたコマンド>: <文の 1 行目>」。コマンドが分からない (.NET や COM のメソッド・プロパティの
# 例外) ときは、$Fallback (読み方の名前) を頭に付ける。「読めない」の行に、どの読み方が何で落ちたかを出す
function Get-ErrorSummary {
    param($ErrorRecord, [string]$Fallback)
    $lines = @("$($ErrorRecord.Exception.Message)" -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    $message = if ($lines.Count -gt 0) { $lines[0] } else { $ErrorRecord.Exception.GetType().Name }
    $command = $Fallback
    $invocation = $ErrorRecord.InvocationInfo
    if ($invocation -and $invocation.MyCommand -and "$($invocation.MyCommand.Name)") { $command = "$($invocation.MyCommand.Name)" }
    if ($command) { "${command}: $message" } else { $message }
}

# Windows Firewall のプロファイル ($Profiles。Name・Enabled・AllowLocal) のうち、拒否の規則が効かないもの (無効か、グループ ポリシーが
# ローカルの規則を止めている) の名前
function Get-IneffectiveFirewallProfiles {
    param($Profiles)
    @($Profiles | Where-Object { ("$($_.Enabled)" -ne 'True') -or ("$($_.AllowLocal)" -eq 'False') } | ForEach-Object { "$($_.Name)" })
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

# Windows Installer がレジストリ (HKLM:\SOFTWARE\Classes\Installer\Products\<これ> など) で使う、詰めた GUID の形 (大文字の 32 字)。
# {} と - を除き、頭の 3 つの組は字を逆に並べ、残りの 8 byte は byte ごとに 2 字を入れ替える。GUID として読めなければ $null
# (MSI から読んだ値を検めるので、Test-SshdUserName と同じく \z で終える)
function ConvertTo-PackedGuid {
    param([string]$Guid)
    if (-not ("$Guid" -match '^\{?([0-9A-Fa-f]{8})-([0-9A-Fa-f]{4})-([0-9A-Fa-f]{4})-([0-9A-Fa-f]{4})-([0-9A-Fa-f]{12})\}?\z')) { return $null }
    $groups = @($Matches[1], $Matches[2], $Matches[3])
    $tail = $Matches[4] + $Matches[5]
    $head = -join @($groups | ForEach-Object { -join ($_.ToCharArray()[($_.Length - 1)..0]) })
    $swapped = -join @(0..7 | ForEach-Object { $tail[2 * $_ + 1]; $tail[2 * $_] })
    ($head + $swapped).ToUpperInvariant()
}

# MSI の名前として、そのままディレクトリの中に置けるか (区切りやドライブを含まず、.msi で終わる)。登録された PackageName をパスに使う前に確かめる
# (レジストリから読んだ値を検めるので、Test-SshdUserName と同じく \z で終える。$ だと末尾の改行を通す)
function Test-MsiPackageName {
    param([string]$Name)
    ("$Name" -match '^[^\\/:*?"<>|\x00-\x1f]+\.msi\z') -and ("$Name" -notmatch '^\.')
}

# 取り直した MSI を、msiexec の保守の install に渡す形を決める。入っている製品に保守の install を流すと、Windows Installer は SOURCEDIR
# (渡した MSI のあるディレクトリ) の下で、入れたときに登録した名前 (SourceList の PackageName) のファイルを原本として探す (無いと
# 2203・1316 で SecureRepair が落ち、1603 になる)。winget download は別の名前で保存するので、その名前に写してから渡す。
# $Msi は落とした MSI (Name・ProductCode・PackageCode。PackageCode は要約情報の {GUID})、$Installed は入っている製品の登録 (Exists・
# PackageName・PackageCode。PackageCode は詰めた形)。返すのは Name (msiexec に渡す MSI の名前)・Copy (その名前に写すか)・Error (止まる理由)。
# PackageCode が違う MSI (同じ版でも作り直されたもの) は、保守の install の原本にならない (SecureRepair も入れたときの原本の hash と照らす)
function Get-MsiSourcePlan {
    param($Msi, $Installed)
    $fail = { param($why) [pscustomobject]@{ Name = $null; Copy = $false; Error = $why } }
    if (-not $Msi.ProductCode) { return (& $fail '落とした MSI の ProductCode が読めない') }
    if (-not $Installed.Exists) {
        return (& $fail "落とした MSI の製品 ($($Msi.ProductCode)) がこの PC に入っていない (入っている OpenSSH と製品が違う)")
    }
    $name = "$($Installed.PackageName)"
    if (-not (Test-MsiPackageName -Name $name)) {
        return (& $fail "入っている製品 ($($Msi.ProductCode)) の、登録された MSI の名前 (SourceList の PackageName) が読めない ($name)")
    }
    if ($Installed.PackageCode) {
        $want = ConvertTo-PackedGuid -Guid $Msi.PackageCode
        if ($want -ne "$($Installed.PackageCode)".ToUpperInvariant()) {
            return (& $fail "落とした MSI のパッケージ (PackageCode $($Msi.PackageCode)) が、入れたときのものと違う (同じ版を作り直した MSI は、保守の install の原本にならない)")
        }
    }
    [pscustomobject]@{ Name = $name; Copy = ("$($Msi.Name)" -ne $name); Error = $null }
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
# (no-openssh: OpenSSH が無い / inbox: Windows の機能の OpenSSH Server がある / bad-allow: ユーザーと送り元の写しに読めない値がある /
# bad-user: AllowUsers に書けない名前 (写しに allowUsers が無く、流したユーザーを書くとき) /
# bad-keys: 鍵の写しに読めない行がある / firewall-off: 拒否の規則が効かないプロファイルがある / no-service: sshd.exe はあるが
# サービスが無い)。Items は Key・Ok・Text の並び、Notes は ※ の行
function Get-SshdVerdict {
    param($Facts)
    $items = [System.Collections.Generic.List[object]]::new()
    $notes = [System.Collections.Generic.List[string]]::new()
    $add = { param($key, $ok, $text) $items.Add([pscustomobject]@{ Key = $key; Ok = [bool]$ok; Text = $text }) }
    $allowBad = @($Facts.Allow.Bad).Count -gt 0
    $access = Resolve-SshdAccess -Allow $Facts.Allow -User $Facts.User

    $blocked = $null
    if (-not $Facts.OpenSsh) {
        $blocked = 'no-openssh'
    } elseif ($Facts.Inbox) {
        $blocked = 'inbox'
    } elseif ($allowBad) {
        $blocked = 'bad-allow'
    } elseif ((-not $access.UsersSet) -and (-not (Test-SshdUserName -Name $Facts.User))) {
        $blocked = 'bad-user'
    } elseif (@($Facts.Copy.Bad).Count -gt 0) {
        $blocked = 'bad-keys'
    } elseif ($Facts.FirewallReadable -and (@(Get-IneffectiveFirewallProfiles -Profiles $Facts.FirewallProfiles).Count -gt 0)) {
        $blocked = 'firewall-off'
    } elseif ($Facts.Server -and (-not $Facts.Service.Exists)) {
        $blocked = 'no-service'
    }

    # 1. server
    if (-not $Facts.OpenSsh) {
        & $add 'server' $false "server          : OpenSSH が入っていない ($($Facts.InstallDir)\ssh.exe が無い)。sshd はその MSI に足す"
    } elseif ($Facts.Inbox) {
        & $add 'server' $false 'server          : Windows の機能の OpenSSH Server (System32\OpenSSH) が入っている。二重にしない'
    } elseif ($Facts.Server -and (-not $Facts.Service.Exists)) {
        & $add 'server' $false "server          : $($Facts.InstallDir)\sshd.exe はあるが、サービス sshd が無い (MSI の入り方が崩れている)"
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

    # 3. sshd_config (AllowUsers と Match Address は、ユーザーと送り元の写しの値か既定。読めない値があれば比べない)
    $configText = Get-SshdConfigText -AllowUsers $access.Users -AllowFrom $access.Addresses
    $config = $Facts.Config
    if ($allowBad) {
        & $add 'config' $false 'sshd_config     : ユーザーと送り元の写しに読めない値があるので、比べない'
    } elseif (-not $config.Exists) {
        & $add 'config' $false 'sshd_config     : 無い → dotfiles の中身を書く'
    } elseif ($config.Readable -and $config.HasBom) {
        & $add 'config' $false 'sshd_config     : 先頭に BOM が付いている (sshd は読めずに起きない) → 退避して書き直す'
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
    # 使うユーザーと送り元は、いつも ※ で出す (ホストの値か既定か。UAC の前に、覚えのない値が無いかを見る)
    if ($allowBad) {
        foreach ($why in @($Facts.Allow.Bad)) { $notes.Add("※ ユーザーと送り元の写し ($($Facts.Allow.Path)) の読めない値: $why") }
    } else {
        foreach ($line in @(Get-SshdAccessNotes -Access $access -From $Facts.Copy.From)) { $notes.Add($line) }
    }

    # 4. 鍵 (administrators_authorized_keys)
    $copy = $Facts.Copy
    $keys = $Facts.Keys
    $wantLines = @($copy.Lines)
    if ($copy.Managed) {
        $keysText = Get-AdminKeysText -KeyLines $wantLines -From $copy.From
        if (-not $keys.Exists) {
            & $add 'keys' $false "鍵              : ファイルが無い → 写しの $($wantLines.Count) 本を書く"
        } elseif ($keys.Readable) {
            $diff = Compare-KeyLines -Want $wantLines -Have @(Get-KeyLines -Lines ((ConvertTo-Lf $keys.Text) -split "`n"))
            if ($diff.Same -and (-not $keys.HasBom)) {
                & $add 'keys' $true "鍵              : $($wantLines.Count) 本 (写しと同じ)"
            } elseif ($diff.Same) {
                & $add 'keys' $false '鍵              : 先頭に BOM が付いている → 写しどおりに書き直す'
            } else {
                & $add 'keys' $false "鍵              : 写しと違う (足す $(@($diff.Added).Count) 本・消す $(@($diff.Removed).Count) 本) → 写しどおりに書く"
                # 今の鍵のファイルを読めるとき (管理者の PowerShell) は、足す鍵と消す鍵を分けて出す (写しは利用者の権限で書けるので、
                # 覚えのない鍵が無いかを見る)
                foreach ($line in @($diff.Added)) { $notes.Add("※ 鍵を足す: $(Get-KeyLabel -Line $line)") }
                foreach ($line in @($diff.Removed)) { $notes.Add("※ 鍵を消す: $(Get-KeyLabel -Line $line)") }
            }
        } elseif ("$($Facts.Record.KeysSha)" -eq (Get-TextSha256 $keysText)) {
            & $add 'keys' $true "鍵              : $($wantLines.Count) 本 (読めないので、揃えたときの記録と比べた。写しと同じ)"
        } else {
            & $add 'keys' $false '鍵              : 読めない (管理者だけが読める)。揃えたときの記録と違う (か記録が無い) → 写しどおりに書く'
        }
        # 写しの鍵は全部、名札と指紋で出す。管理者でない -Check (setup・runner・UAC の前の表) は今の鍵のファイルを読めず、足す・消すに
        # 分けられないので、ここで覚えのない鍵が無いかを見る (揃えたときの記録は利用者が書けるので、記録と比べて分けることはしない)
        foreach ($line in $wantLines) { $notes.Add("※ 鍵: $(Get-KeyLabel -Line $line)") }
        if ($wantLines.Count -eq 0) {
            $notes.Add((Get-KeysHint -Kind 'zero' -From $copy.From))
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
        $notes.Add((Get-KeysHint -Kind 'null' -From $copy.From -CopyPath $copy.Path))
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
        & $add 'block' $false "拒否の規則      : 読めない ($($Facts.FirewallError))"
    } else {
        $specs = @(Get-SshdFirewallSpecs)
        $bad = @($specs | Where-Object { -not (Test-FirewallRuleMatch -Spec $_ -Rule $Facts.Rules[$_.Name]) })
        if ($bad.Count -eq 0) {
            & $add 'block' $true "拒否の規則      : $($specs.Count) つとも揃っている (グループ $script:RuleGroup)"
        } else {
            & $add 'block' $false "拒否の規則      : 無い・違うものが $($bad.Count) つ ($(@($bad | ForEach-Object { $_.Name }) -join '・')) → 作り直す"
        }
    }

    # 7. 22 番を許す受信の規則 (22 番だけの規則と sshd.exe の規則は無効にする。22 番とほかのポートを並べた規則は、ほかのポートまで
    #    閉じないよう残す。22 番は拒否の規則が止める)。拒否の規則とは別に読むので、読めないときもこの行だけを ⚠ にする
    if (-not $Facts.AllowReadable) {
        & $add 'allow' $false "22 番の受信の許可: 読めない ($($Facts.AllowError))"
    } else {
        $allow = @($Facts.AllowRules | Where-Object { $_.Disable })
        $mixed = @($Facts.AllowRules | Where-Object { -not $_.Disable })
        if ($allow.Count -eq 0) {
            & $add 'allow' $true '22 番の受信の許可: 有効なものは無い'
        } else {
            & $add 'allow' $false "22 番の受信の許可: 有効 ($(@($allow | ForEach-Object { $_.DisplayName }) -join '・')) → 無効にする"
        }
        if ($mixed.Count -gt 0) {
            $notes.Add("※ 22 番とほかのポートを許す受信の規則 ($(@($mixed | ForEach-Object { $_.DisplayName }) -join '・')) は無効にしない (ほかのポートまで閉じないため。22 番は拒否の規則が止める)")
        }
    }

    if ($Facts.Inbox) {
        $notes.Add('※ Windows の機能の OpenSSH Server を外すには、管理者の PowerShell で Remove-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 を打つ (その後 Install-Sshd を打ち直す)')
    }
    if ($blocked -eq 'bad-user') {
        $notes.Add("※ AllowUsers に書けないユーザー名: $($Facts.User) (dotfiles は英小文字・数字・. _ - の名前だけを書く。sshd はログインした本当の名前と比べるので、別の名前は渡せない)")
    }
    if ($blocked -eq 'firewall-off') {
        $notes.Add("※ 拒否の規則が効かない Windows Firewall のプロファイル: $(@(Get-IneffectiveFirewallProfiles -Profiles $Facts.FirewallProfiles) -join '・') (無効か、グループ ポリシーがローカルの規則を止めている)。有効にするには、管理者の PowerShell で Set-NetFirewallProfile -Profile Domain,Private,Public -Enabled True を打つ")
    }
    if ($blocked -eq 'no-service') {
        $notes.Add('※ サービスを作り直すには、win/README.md の「sshd を止める・外す」の手順で Server の機能を外してから、Install-Sshd を打ち直す')
    }
    foreach ($line in @($Facts.Copy.Bad)) {
        $notes.Add("※ 鍵の写しの読めない行: $(if ("$line".Length -gt 40) { "$line".Substring(0, 40) + '…' } else { $line })")
    }
    if (-not $Facts.Tailscale) {
        $notes.Add('※ Tailscale が入っていない。この sshd には tailnet と localhost からしか入れない (Tailscale は Install-Tailscale・dotfiles.wsl.windowsFiles.tailscale.enable)')
    }

    [pscustomobject]@{
        InstallDir = $Facts.InstallDir
        KeysFrom   = $Facts.Copy.From
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
    if ($Verdict.Blocked -eq 'bad-allow') {
        return '⚠️ ユーザーと送り元の写しに読めない値がある → ホストの値 (dotfiles-private の win/hosts の TOML の [sshd] allowUsers・allowFrom) を直して dotfiles apply を流し直す ⚠️'
    }
    if ($Verdict.Blocked -eq 'bad-user') {
        return '⚠️ AllowUsers に書けないユーザー名 → このユーザーでは dotfiles の sshd を使えない (上の ※ の行) ⚠️'
    }
    if ($Verdict.Blocked -eq 'firewall-off') {
        return '⚠️ Windows Firewall が効いていないプロファイルがある → 先に有効にする (拒否の規則が効かない。上の ※ の行) ⚠️'
    }
    if ($Verdict.Blocked -eq 'no-service') {
        return '⚠️ sshd.exe はあるがサービス sshd が無い → Server の機能を外してから入れ直す (上の ※ の行) ⚠️'
    }
    if ($Verdict.Blocked -eq 'bad-keys') {
        return (Get-KeysHint -Kind 'bad' -From $Verdict.KeysFrom)
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

# SSH の会話の中で動いているか (sshd が SSH_CONNECTION・SSH_CLIENT を渡す)
function Test-InSshSession {
    [bool]($env:SSH_CONNECTION -or $env:SSH_CLIENT)
}

# ファイルを読む。Exists は在るか (読めないときは在るとみる)、Readable は読めたか、HasBom は先頭に UTF-8 の BOM があるか
# (ReadAllText は BOM を落とすので、byte で見る。sshd は BOM を設定の文字として読み、起きなくなる)
function Read-TextFile {
    param([string]$Path)
    $exists = $false
    $readable = $false
    $hasBom = $false
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
            $bytes = [IO.File]::ReadAllBytes($Path)
            $hasBom = ($bytes.Length -ge 3) -and ($bytes[0] -eq 0xEF) -and ($bytes[1] -eq 0xBB) -and ($bytes[2] -eq 0xBF)
            $text = [Text.UTF8Encoding]::new($false).GetString($bytes)
            if ($hasBom) { $text = $text.Substring(1) }
            $readable = $true
        } catch {
            $readable = $false
        }
    }
    [pscustomobject]@{ Exists = $exists; Readable = $readable; HasBom = $hasBom; Text = $text }
}

# BOM の無い UTF-8 で書く (sshd は先頭の BOM を設定の文字として読む。Set-Content -Encoding UTF8 は 5.1 で BOM を付ける)
function Write-TextNoBom {
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

# 一時ファイルに書いてから差し替える。在れば元を $Backup に退避して入れ替え ([IO.File]::Replace)、無ければ名前を替えて置く。途中で
# 落ちても、元のファイルが消えたままにならない (sshd_config が無いと、sshd は次に起きるときに既定 (パスワードでも入れる) を写す)
function Write-TextReplacing {
    param([string]$Path, [string]$Text, [string]$Backup)
    $tmp = "$Path.dotfiles-tmp"
    Write-TextNoBom -Path $tmp -Text $Text
    if (Test-Path -LiteralPath $Path) {
        [IO.File]::Replace($tmp, $Path, $Backup)
    } else {
        [IO.File]::Move($tmp, $Path)
    }
}

# 鍵の写しを読む。無ければ Managed が偽 (dotfiles は鍵を置かない)。From は写しを置く受け持ち (Resolve-KeysFrom)
function Read-KeysCopy {
    param([string]$Path, [string]$KeysFrom)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ Managed = $false; Lines = @(); Bad = @(); Path = $Path; From = (Resolve-KeysFrom -KeysFrom $KeysFrom -Exists $false) }
    }
    $raw = @([IO.File]::ReadAllLines($Path))
    $parsed = ConvertFrom-KeysCopy -Lines $raw
    [pscustomobject]@{ Managed = $true; Lines = @($parsed.Lines); Bad = @($parsed.Bad); Path = $Path; From = (Resolve-KeysFrom -KeysFrom $KeysFrom -Exists $true -Lines $raw) }
}

# ユーザーと送り元の写し (JSON) を読む。無ければ Managed が偽で、ユーザーも送り元も既定 (Users・Addresses が $null)。読めない JSON は Bad に理由
function Read-AllowCopy {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ Managed = $false; Users = $null; Addresses = $null; Bad = @(); Path = $Path }
    }
    try {
        $json = [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false)).TrimStart([char]0xFEFF) | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return [pscustomobject]@{ Managed = $true; Users = $null; Addresses = $null; Bad = @("JSON として読めない ($(Get-ErrorSummary -ErrorRecord $_ -Fallback 'ConvertFrom-Json'))"); Path = $Path }
    }
    $parsed = ConvertFrom-AllowCopy -Json $json
    [pscustomobject]@{ Managed = $true; Users = $parsed.Users; Addresses = $parsed.Addresses; Bad = @($parsed.Bad); Path = $Path }
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

# 作った sshd_config の中身 ($Text) を、書き換える前に sshd の -t で試す。書くのと同じ文字列 (BOM の無い UTF-8・LF) を $Directory の一時の
# ファイルに書き、使い捨てのホストの鍵 (ed25519) を作って -h で渡す (-h があると sshd は既定のホストの鍵を読まないので、ホストの鍵がまだ無い・
# 読めないことを設定の誤りと取り違えない。断るのは設定の誤りだけ)。$Directory は管理者だけが書ける所 (%ProgramData%\ssh) にする (利用者が書ける
# TEMP や LOCALAPPDATA だと、試してから書くまでの間に差し替えられる)。一時のファイルは、試した後にいつも消す。
# 返すのは Tested (試せたか)・Ok (sshd が通したか。終了コード 0)・Lines (sshd -t の出力)・Why (試せなかったわけ)。sshd・ssh-keygen が無い・鍵を
# 作れないときは Tested が偽 (止めずに進める側が決める)。Windows では鍵の権限を管理者と SYSTEM だけにする (Win32-OpenSSH はほかの人が読める
# ホストの鍵を読まない)。Linux の sshd でも同じに流れる (ssh-keygen が 0600 で作る。Install-Sshd.Tests.ps1 が nixpkgs の sshd で確かめる)
function Invoke-SshdConfigTest {
    param([string]$SshdExe, [string]$Text, [string]$Directory)
    $result = { param($tested, $ok, $lines, $why) [pscustomobject]@{ Tested = [bool]$tested; Ok = [bool]$ok; Lines = @($lines); Why = $why } }
    if (-not (Test-Path -LiteralPath $SshdExe -PathType Leaf)) {
        return (& $result $false $false @() "$SshdExe が無い (server を足す前)")
    }
    # ssh-keygen は sshd の隣 (Windows は ssh-keygen.exe、Linux は ssh-keygen)
    $keygen = Join-Path (Split-Path -Parent $SshdExe) ('ssh-keygen' + [IO.Path]::GetExtension($SshdExe))
    if (-not (Test-Path -LiteralPath $keygen -PathType Leaf)) {
        return (& $result $false $false @() "$keygen が無い (使い捨てのホストの鍵を作れない)")
    }
    $id = [guid]::NewGuid().ToString('N')
    $config = Join-Path $Directory "sshd_config.dotfiles-test-$id"
    $key = Join-Path $Directory "ssh_host_ed25519_key.dotfiles-test-$id"
    try {
        Write-TextNoBom -Path $config -Text $Text
        # 空のパスフレーズは Start-Process で "" と書いて渡す (Windows PowerShell 5.1 は、外のコマンドに渡す空の引数を落とす)。名前は毎回新しい
        # ので、ssh-keygen が上書きを聞いて止まることはない
        $gen = Start-Process -FilePath $keygen -ArgumentList @('-q', '-t', 'ed25519', '-N', '""', '-C', 'dotfiles-sshd-test', '-f', ('"{0}"' -f $key)) -Wait -PassThru -NoNewWindow
        if (($gen.ExitCode -ne 0) -or (-not (Test-Path -LiteralPath $key -PathType Leaf))) {
            return (& $result $false $false @() "使い捨てのホストの鍵を作れなかった (ssh-keygen の終了コード $($gen.ExitCode))")
        }
        if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
            try {
                Set-AdminOnlyAcl -Path $key
            } catch {
                return (& $result $false $false @() "使い捨てのホストの鍵の権限を、管理者と SYSTEM だけにできなかった ($(Get-ErrorSummary -ErrorRecord $_ -Fallback 'Set-Acl'))")
            }
        }
        # 5.1 では Stop のままだと、外部コマンドの stderr の 1 行目で止まる
        $ErrorActionPreference = 'Continue'
        $lines = @(& $SshdExe -t -f $config -h $key 2>&1 | ForEach-Object { "$_" })
        & $result $true ($LASTEXITCODE -eq 0) $lines $null
    } finally {
        foreach ($p in @($config, $key, "$key.pub")) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
    }
}

# 拒否の規則を 1 つ読む (無ければ $null)。無い (ObjectNotFound) 以外の失敗は例外にする (読めないのを「無い」と読まない)
function Read-FirewallRuleFacts {
    param([string]$Name)
    $err = $null
    $rule = Get-NetFirewallRule -Name $Name -ErrorAction SilentlyContinue -ErrorVariable err | Select-Object -First 1
    if (-not $rule) {
        $other = @($err | Where-Object { "$($_.CategoryInfo.Category)" -ne 'ObjectNotFound' })
        if ($other.Count -gt 0) { throw $other[0] }
        return $null
    }
    $port = $rule | Get-NetFirewallPortFilter -ErrorAction Stop
    $addr = $rule | Get-NetFirewallAddressFilter -ErrorAction Stop
    $app = $rule | Get-NetFirewallApplicationFilter -ErrorAction Stop
    $svc = $rule | Get-NetFirewallServiceFilter -ErrorAction Stop
    $ifa = $rule | Get-NetFirewallInterfaceFilter -ErrorAction Stop
    $ift = $rule | Get-NetFirewallInterfaceTypeFilter -ErrorAction Stop
    [pscustomobject]@{
        Name          = $rule.Name
        DisplayName   = $rule.DisplayName
        Enabled       = "$($rule.Enabled)"
        Direction     = "$($rule.Direction)"
        Action        = "$($rule.Action)"
        Profile       = "$($rule.Profile)"
        Protocol      = "$($port.Protocol)"
        LocalPort     = @(@($port.LocalPort) | ForEach-Object { "$_" })
        LocalAddress   = @(@($addr.LocalAddress) | ForEach-Object { "$_" })
        RemoteAddress  = @(@($addr.RemoteAddress) | ForEach-Object { "$_" })
        Program        = "$($app.Program)"
        Service        = "$($svc.Service)"
        InterfaceAlias = @(@($ifa.InterfaceAlias) | ForEach-Object { "$_" })
        InterfaceType  = "$($ift.InterfaceType)"
    }
}

# 22 番を許す、有効な受信の規則 (MSI が作るもの・Windows の機能が作るもの・手で作ったもの。選び方は Select-SshdAllowRules)。
# 規則は Windows Firewall の COM (HNetCfg.FwPolicy2) の Rules で読む。管理者でない PowerShell (setup・runner の -Check) では
# Get-NetFirewallPortFilter -All が PermissionDenied で落ちる。規則ごとに Get-NetFirewallPortFilter を引けば管理者でなくても読めるが、
# 有効な受信の許可に絞っても 10 秒を超え、毎回の setup に乗る (COM は 500 余りの規則を 1 秒かからずに読む)。COM の規則は
# Get-NetFirewallRule の Name を持たないので、無効にするときも COM の規則の Enabled を書く。読めなければ例外にする (読めないのを
# 「無い」と読まない)
function Get-SshdAllowRules {
    $policy = New-Object -ComObject HNetCfg.FwPolicy2
    @(Select-SshdAllowRules -Rules @($policy.Rules))
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
    param([string]$InstallDir, [string]$CopyPath, [string]$StateDir, [string]$User, [string]$KeysFrom, [string]$AllowPath)
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
    $profiles = @()
    $firewallReadable = $true
    $firewallError = $null
    try {
        # 効いている値 (グループ ポリシーを含む) で、プロファイルが有効か・ローカルの規則を使うかを見る
        $profiles = @(Get-NetFirewallProfile -PolicyStore ActiveStore -ErrorAction Stop | ForEach-Object {
                [pscustomobject]@{ Name = "$($_.Name)"; Enabled = "$($_.Enabled)"; AllowLocal = "$($_.AllowLocalFirewallRules)" }
            })
        foreach ($spec in @(Get-SshdFirewallSpecs)) { $rules[$spec.Name] = Read-FirewallRuleFacts -Name $spec.Name }
    } catch {
        $firewallReadable = $false
        $firewallError = Get-ErrorSummary -ErrorRecord $_ -Fallback 'Windows Firewall'
    }
    # 22 番の許可は読み方 (COM) が違うので、別に受け止める (片方が落ちても、もう片方の行は出す)
    $allowRules = @()
    $allowReadable = $true
    $allowError = $null
    try {
        $allowRules = @(Get-SshdAllowRules)
    } catch {
        $allowReadable = $false
        $allowError = Get-ErrorSummary -ErrorRecord $_ -Fallback 'HNetCfg.FwPolicy2'
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
        Copy             = Read-KeysCopy -Path $CopyPath -KeysFrom $KeysFrom
        Allow            = Read-AllowCopy -Path $AllowPath
        FirewallReadable = $firewallReadable
        FirewallError    = $firewallError
        FirewallProfiles = $profiles
        Rules            = $rules
        AllowReadable    = $allowReadable
        AllowError       = $allowError
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

# 管理者と SYSTEM だけが読み書きできる空のディレクトリを、新しく作る (取り直した MSI を、msiexec の前に利用者の権限で差し替えられない
# ように)。成功なら $true。在る名前には作らない (-Force を付けない。利用者の権限で前もって置かれたディレクトリやジャンクションを使わず、
# 消しもしない。Windows PowerShell 5.1 の Remove-Item -Recurse はジャンクションの先まで消す)。作ってから権限を替えるまでの間は親
# (ProgramData) の権限を継ぎ、利用者も中に置けるので、替えた後に権限と、空かどうかを確かめる
function New-AdminOnlyDir {
    param([string]$Path)
    $null = New-Item -ItemType Directory -Path $Path -ErrorAction Stop
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetSecurityDescriptorSddlForm($script:AdminDirSddl)
    Set-Acl -LiteralPath $Path -AclObject $acl
    $facts = Read-AclFacts -Path $Path
    $placed = @(Get-ChildItem -LiteralPath $Path -Force)
    if ($facts.Readable -and (Test-AdminOnlyAcl -Acl $facts.Value) -and ($placed.Count -eq 0)) { return $true }
    # 消さずに残す (中に置かれたものがジャンクションでも、たどらない)
    Write-Step "$Path を、管理者と SYSTEM だけが読み書きできる空のディレクトリにできなかった (中に $($placed.Count) 個)。MSI を落とさない。中を確かめてから手で消す"
    $false
}

# MSI の Property 表の ProductCode と、要約情報の PackageCode (Revision Number) を読む (WindowsInstaller.Installer の COM。型の情報が
# 無いので InvokeMember で呼ぶ)。行が無ければ ProductCode は $null。読み終えたら COM を放す (MSI を開いたまま msiexec に渡さない)
function Read-MsiPackageFacts {
    param([string]$Path)
    $invoke = { param($o, [string]$name, [System.Reflection.BindingFlags]$kind, [object[]]$a) $o.GetType().InvokeMember($name, $kind, $null, $o, $a) }
    $installer = New-Object -ComObject WindowsInstaller.Installer
    $db = $null
    $view = $null
    $record = $null
    $summary = $null
    try {
        $db = & $invoke $installer 'OpenDatabase' 'InvokeMethod' @($Path, 0)
        $view = & $invoke $db 'OpenView' 'InvokeMethod' @("SELECT ``Value`` FROM ``Property`` WHERE ``Property`` = 'ProductCode'")
        $null = & $invoke $view 'Execute' 'InvokeMethod' @()
        $record = & $invoke $view 'Fetch' 'InvokeMethod' @()
        $productCode = $null
        if ($null -ne $record) { $productCode = "$(& $invoke $record 'StringData' 'GetProperty' @(1))" }
        $null = & $invoke $view 'Close' 'InvokeMethod' @()
        $summary = & $invoke $db 'SummaryInformation' 'GetProperty' @(0)
        $packageCode = "$(& $invoke $summary 'Property' 'GetProperty' @(9))"
        [pscustomobject]@{ ProductCode = $productCode; PackageCode = $packageCode }
    } finally {
        foreach ($o in @($summary, $record, $view, $db, $installer)) {
            if ($null -ne $o) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($o) }
        }
    }
}

# マシンに入れた製品の登録 (HKLM:\SOFTWARE\Classes\Installer\Products\<詰めた ProductCode>)。PackageCode は詰めた形のまま、
# PackageName (入れたときの MSI の名前) は SourceList の値。製品が無ければ Exists が偽
function Read-InstalledMsiProduct {
    param([string]$ProductCode)
    $none = [pscustomobject]@{ Exists = $false; PackageName = $null; PackageCode = $null }
    $packed = ConvertTo-PackedGuid -Guid $ProductCode
    if (-not $packed) { return $none }
    $key = "HKLM:\SOFTWARE\Classes\Installer\Products\$packed"
    if (-not (Test-Path -LiteralPath $key)) { return $none }
    $product = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
    $source = Get-ItemProperty -LiteralPath "$key\SourceList" -ErrorAction SilentlyContinue
    $packageName = $null
    if ($source -and $source.PSObject.Properties['PackageName']) { $packageName = "$($source.PackageName)" }
    $packageCode = $null
    if ($product -and $product.PSObject.Properties['PackageCode']) { $packageCode = "$($product.PackageCode)" }
    [pscustomobject]@{ Exists = $true; PackageName = $packageName; PackageCode = $packageCode }
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
    # 落とす先は、管理者と SYSTEM だけが書ける場所 (利用者の %LOCALAPPDATA% だと、winget が sha256 を照らした後に差し替えられうる)。
    # 名前は毎回新しくする (利用者は ProgramData の下にディレクトリを作れるので、決まった名前だと前もって置かれうる)
    $dir = Join-Path $env:ProgramData ('dotfiles-sshd-msi-' + [guid]::NewGuid().ToString('N'))
    if (-not (New-AdminOnlyDir -Path $dir)) { return $false }
    try {
        $arguments = Get-WingetDownloadArgs -PackageId $script:PackageId -Version $version -Directory $dir
        Write-Step "winget $($arguments -join ' ')"
        $download = Invoke-Winget -Arguments $arguments
        $download.Lines | Select-Object -Last 3 | ForEach-Object { Write-Step "  $_" }
        $msi = @(Get-ChildItem -LiteralPath $dir -Filter '*.msi' -File -ErrorAction SilentlyContinue)
        if (($download.ExitCode -ne 0) -or ($msi.Count -ne 1)) {
            Write-Step ('winget download で {0} の MSI を取れなかった (終了コード 0x{1:X8}・MSI {2} 個)。winget に入っている版が無いなら、先に Install-OpenSSH で固定した版に揃える' -f $version, $download.ExitCode, $msi.Count)
            return $false
        }
        # 保守の install の原本にするため、入っている製品の登録された名前 (PackageName) に写す (Get-MsiSourcePlan)
        try {
            $msiFacts = Read-MsiPackageFacts -Path $msi[0].FullName
        } catch {
            Write-Step "落とした MSI を読めなかった ($(Get-ErrorSummary -ErrorRecord $_ -Fallback 'WindowsInstaller.Installer'))"
            $msiFacts = [pscustomobject]@{ ProductCode = $null; PackageCode = $null }
        }
        $installed = Read-InstalledMsiProduct -ProductCode $msiFacts.ProductCode
        $plan = Get-MsiSourcePlan -Installed $installed -Msi ([pscustomobject]@{
                Name = $msi[0].Name; ProductCode = $msiFacts.ProductCode; PackageCode = $msiFacts.PackageCode
            })
        if ($plan.Error) {
            Write-Step "$($plan.Error)。msiexec を流さない"
            return $false
        }
        $source = Join-Path $dir $plan.Name
        if ($plan.Copy) {
            [IO.File]::Copy($msi[0].FullName, $source)
            Write-Step "MSI を、入っている製品の登録された名前 ($($plan.Name)) に写した (保守の install は、この名前で原本を探す)"
        }
        $log = Join-Path $StateDir 'msiexec-add-server.log'
        $arguments = Get-MsiAddServerArgs -Msi $source -Log $log
        Write-Step "msiexec $($arguments -join ' ')"
        $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $arguments -Wait -PassThru
        $exitCode = $process.ExitCode
    } finally {
        # 落ちたときも残さない (中は管理者と SYSTEM だけが書けるので、winget が落としたものしか無い)
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
    $why = Get-MsiexecResultText -ExitCode $exitCode
    if ($why) {
        Write-Step "msiexec が失敗した ($why。ログ: $log)"
        return $false
    }
    if ($exitCode -eq 3010) { Write-Step 'msiexec: 再起動が要ると返した' }
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
    param([string]$InstallDir, [string]$User, [string]$CopyPath, [string]$StateDir, [string]$KeysFrom, [string]$AllowPath)
    $allow = Read-AllowCopy -Path $AllowPath
    if (@($allow.Bad).Count -gt 0) {
        Write-Step "ユーザーと送り元の写し ($AllowPath) に読めない値がある。何もしない"
        return $false
    }
    $access = Resolve-SshdAccess -Allow $allow -User $User
    if ((-not $access.UsersSet) -and (-not (Test-SshdUserName -Name $User))) {
        Write-Step "AllowUsers に書けないユーザー名: $User。何もしない"
        return $false
    }
    $copy = Read-KeysCopy -Path $CopyPath -KeysFrom $KeysFrom
    if (@($copy.Bad).Count -gt 0) {
        Write-Step "鍵の写し ($CopyPath) に読めない行がある。何もしない"
        return $false
    }
    # 拒否の規則が効かないプロファイルがあれば、何もしない (sshd を LAN に開けない)
    $ineffective = @(Get-IneffectiveFirewallProfiles -Profiles @(Get-NetFirewallProfile -PolicyStore ActiveStore -ErrorAction Stop | ForEach-Object {
                [pscustomobject]@{ Name = "$($_.Name)"; Enabled = "$($_.Enabled)"; AllowLocal = "$($_.AllowLocalFirewallRules)" }
            }))
    if ($ineffective.Count -gt 0) {
        Write-Step "拒否の規則が効かない Windows Firewall のプロファイルがある ($($ineffective -join '・'))。何もしない"
        return $false
    }
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
    $configText = Get-SshdConfigText -AllowUsers $access.Users -AllowFrom $access.Addresses
    $keysText = if ($copy.Managed) { Get-AdminKeysText -KeyLines @($copy.Lines) -From $copy.From } else { Get-AdminKeysText -KeyLines @() -Managed $false }
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
    if (-not ($current.Readable -and (-not $current.HasBom) -and ((ConvertTo-Lf $current.Text) -ceq $configText))) {
        # 書き換える前に、作った中身を sshd -t で試す (一時のファイルは管理者だけが書ける %ProgramData%\ssh に置く)。断られたら書き換えずに
        # 止まる (今の sshd_config と sshd はそのまま。起こし直してから落ちると、sshd が止まったままになる)。sshd.exe がまだ無い (MSI で server を
        # 足す前) ときは試せないので、そう出して今までどおり書く
        $test = Invoke-SshdConfigTest -SshdExe $sshdExe -Text $configText -Directory $sshDir
        if (-not $test.Tested) {
            Write-Step "sshd_config の中身を sshd -t で試せなかった ($($test.Why))。試さずに書く"
        } elseif (-not $test.Ok) {
            Write-Step 'sshd_config の中身を sshd -t が断った。sshd_config を書き換えずに止める (今の sshd_config と sshd はそのまま)'
            foreach ($line in @($test.Lines)) { Write-Step "  sshd -t: $line" }
            return $false
        } else {
            Write-Step 'sshd_config の中身を sshd -t で試した (通った)'
        }
        # 一時ファイルから差し替える (書けずに消えると、sshd は次に起きるときに既定を写す)
        Write-TextReplacing -Path $configPath -Text $configText -Backup "$configPath.dotfiles-bak-$stamp"
        if ($current.Exists) { Write-Step "sshd_config を退避した: sshd_config.dotfiles-bak-$stamp" }
        Write-Step 'sshd_config を dotfiles の中身にした'
        # 書いたユーザーと送り元 (管理者の子のログは親が出す。UAC の前の表の ※ の行と同じ値か)
        $users = @($access.Users)
        $addresses = @($access.Addresses)
        Write-Step "  AllowUsers: $(if ($users.Count -gt 0) { $users -join '・' } else { '無し (DenyUsers *)' })"
        Write-Step "  送り元: $(if ($addresses.Count -gt 0) { $addresses -join '・' } else { '無し' })"
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
            $writeKeys = $keys.HasBom -or (-not (Compare-KeyLines -Want @($copy.Lines) -Have $have).Same)
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
        if ($copy.Managed) {
            Write-Step "administrators_authorized_keys に鍵の写しの $(@($copy.Lines).Count) 本を書いた"
            foreach ($line in @($copy.Lines)) { Write-Step "  鍵: $(Get-KeyLabel -Line $line)" }
        } else {
            Write-Step 'administrators_authorized_keys を空で作った (鍵は手で置く)'
        }
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
    #    22 番を許し、修復や上げ直しのたびに有効へ戻る。外からの 22 番は拒否の規則が止めるが、許可も残さない)。読んだ COM の規則の
    #    Enabled を書く (COM の規則には Disable-NetFirewallRule に渡す Name が無い)
    foreach ($r in @(Get-SshdAllowRules | Where-Object { $_.Disable })) {
        $r.Rule.Enabled = $false
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
            if ($configChanged -and (Test-InSshSession)) {
                # 起こし直すとこの会話ごと切れ、止めてから起こす間に落ちると、sshd が止まったままになる (外から入れなくなる)
                Write-Step 'SSH の会話の中なので sshd を起こし直さない。書き直した sshd_config を効かせるには、PC で Restart-Service sshd を打つ (管理者の PowerShell)'
            } elseif ($configChanged) {
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
    param([string]$User, [string]$CopyPath, [string]$StateDir, [string]$KeysFrom, [string]$AllowPath)
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
    $log = Join-Path $StateDir 'Install-Sshd.log'
    Remove-Item -LiteralPath $log -ErrorAction SilentlyContinue
    $hostExe = (Get-Process -Id $PID).Path
    # Start-Process は配列を空白でつなぐだけなので、パスは自分で "" で囲む (どれも \ で終わらない)。ユーザーと送り元の写しも、親の場所を
    # 渡す (別の管理者のアカウントで昇格すると、子の LOCALAPPDATA は親と違う)
    $argumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath),
        '-LogPath', ('"{0}"' -f $log), '-KeysCopy', ('"{0}"' -f $CopyPath), '-AllowCopy', ('"{0}"' -f $AllowPath),
        '-AllowUser', $User, '-StateDir', ('"{0}"' -f $StateDir))
    if ($KeysFrom) { $argumentList += @('-KeysFrom', $KeysFrom) }
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
    param([switch]$Check, [switch]$IfMissing, [string]$KeysCopy, [string]$KeysFrom, [string]$AllowCopy, [string]$AllowUser, [string]$StateDir, [string]$LogPath)
    $installDir = Join-Path $env:ProgramFiles 'OpenSSH'
    if (-not $StateDir) { $StateDir = Join-Path $env:LOCALAPPDATA 'dotfiles\sshd' }
    if (-not $KeysCopy) { $KeysCopy = Join-Path $env:LOCALAPPDATA 'dotfiles\sshd\authorized_keys' }
    if (-not $AllowCopy) { $AllowCopy = Join-Path $env:LOCALAPPDATA 'dotfiles\sshd\allow.json' }
    if (-not $AllowUser) { $AllowUser = "$env:USERNAME".ToLowerInvariant() }

    if ($LogPath) {
        # 管理者で起動し直された子: 揃える段だけをして、結果を $LogPath に書く
        $script:StepLog = $LogPath
        if (Invoke-SshdFix -InstallDir $installDir -User $AllowUser -CopyPath $KeysCopy -StateDir $StateDir -KeysFrom $KeysFrom -AllowPath $AllowCopy) { return 0 }
        return 1
    }

    $facts = Get-SshdFacts -InstallDir $installDir -CopyPath $KeysCopy -StateDir $StateDir -User $AllowUser -KeysFrom $KeysFrom -AllowPath $AllowCopy
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
        [void](Invoke-SshdFix -InstallDir $installDir -User $AllowUser -CopyPath $KeysCopy -StateDir $StateDir -KeysFrom $KeysFrom -AllowPath $AllowCopy)
    } else {
        [void](Invoke-Elevated -User $AllowUser -CopyPath $KeysCopy -StateDir $StateDir -KeysFrom $KeysFrom -AllowPath $AllowCopy)
    }

    # 揃ったかを読み直して確かめる
    Write-Host ''
    $after = Get-SshdVerdict -Facts (Get-SshdFacts -InstallDir $installDir -CopyPath $KeysCopy -StateDir $StateDir -User $AllowUser -KeysFrom $KeysFrom -AllowPath $AllowCopy)
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
        exit (Invoke-InstallSshd -Check:$Check -IfMissing:$IfMissing -KeysCopy $KeysCopy -KeysFrom $KeysFrom -AllowCopy $AllowCopy -AllowUser $AllowUser -StateDir $StateDir -LogPath $LogPath)
    } catch {
        Write-Host "エラーで止まった: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace
        # 管理者で起動し直した子の窓はすぐ閉じるので、親が出せるようにログにも書く
        if ($LogPath) {
            try {
                Add-Content -LiteralPath $LogPath -Value @("エラーで止まった: $($_.Exception.Message)", "$($_.ScriptStackTrace)") -Encoding utf8
            } catch {
                Write-Host "ログにも書けなかった: $($_.Exception.Message)"
            }
        }
        exit 2
    }
}
