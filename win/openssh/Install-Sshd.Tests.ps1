# win/openssh/Install-Sshd.ps1 のうち、副作用の無い関数のテスト。Pester は使わない。
# サービス・ファイル・Windows Firewall・winget・msiexec に触る部分は、実機で -Check と本番を打って確かめる (win/README.md の「sshd」)。
#
# WSL から流す (Linux の pwsh で動かすので、Windows 側には触らない。PATH に sshd があれば、作る sshd_config を sshd -G で読ませる):
#   nix shell nixpkgs#powershell nixpkgs#openssh -c pwsh -NoProfile -File win/openssh/Install-Sshd.Tests.ps1
#
# BOM 付きの UTF-8 で保存すること (win/README.md の「dotfiles.ps1 を書くときの注意」)。
#
# ## 確かめること
#
#   - AllowUsers に書けるユーザー名 (英小文字・数字・. _ -) だけを通す。末尾・頭の改行も断る (検めは \z で終える。.NET の $ は末尾の
#     改行の前でも当たる)
#   - Match Address に書ける送り元: IPv4・IPv6 のアドレスか CIDR だけ (IPv4 の組と CIDR の長さは頭に 0 を付けない・長さは 32 と 128 まで・
#     CIDR のアドレスは範囲の頭)。! * , と空白・末尾の改行・ゾーン・名前・欠けた形は断る
#   - 作る sshd_config: 鍵だけ (PasswordAuthentication no・KbdInteractiveAuthentication no・AuthenticationMethods publickey)、AllowUsers は
#     ユーザーだけ (接続元を書かない) で、最初の Match より前に書く。接続元は Match Address で絞り、既定では tailnet (100.64.0.0/10・
#     fd7a:115c:a1e0::/48) と localhost の外から来たら DenyUsers * にする。AllowUsers・DenyUsers・AllowGroups・DenyGroups の語に / を
#     書かない (Win32-OpenSSH は語の最初の / を \ に替えるので、user@CIDR は Windows で当たらない)。
#     ListenAddress は書かない。改行は LF で、BOM も CR も無く、ASCII だけ。PATH に sshd があれば sshd -G が読め、AllowUsers が 1 つ。
#     PATH に sshd と ssh-keygen があれば、使い捨ての host 鍵で sshd -T -C を流し、tailnet と localhost から来たときだけ DenyUsers が付かない
#   - ユーザーと送り元を渡した sshd_config: 既定の値 (ユーザー 1 人と既定の送り元の並び) では、値をホストの値で持つ前の中身と 1 バイトも
#     違わない (写しを置いた後も Install-Sshd を流し直さずに済む)。ユーザーが 2 人以上なら AllowUsers に並べ、0 人なら AllowUsers の代わりに
#     DenyUsers * を最初の Match より前に書く。送り元は Match Address の否定に並べ、0 なら Match Address * にする。どれも ASCII と LF だけで、
#     sshd -G が読み、sshd -T -C で、書いた送り元から来たときだけ DenyUsers が付かない (0 人・0 のときはどこから来ても付く)
#   - ユーザーと送り元の写し (JSON) の読み方: 欄が無い・null は書いていない ($null)、[] は 0、list はその値。version が 1 でない・object で
#     ない・list でも null でもない・書けない値 (ユーザー名と送り元の検め。JSON の \n で末尾に改行を入れた値も) は読めない値として理由を
#     出す (値の制御文字は \n などの字にして出す)。runner の手順 sshd が書く形
#     (win/runner/src/steps/sshd_allow.rs の copy_text と同じ) を読める。使う値は、写しの値があればそれ、無ければ既定 (流したユーザーと、
#     tailnet と localhost)
#   - 管理者で起動し直すとき (Invoke-Elevated)、子にユーザーと送り元の写しの場所と流したユーザーと受け持ちを渡す
#   - 鍵の写しの読み方: コメントと空の行を除き、authorized_keys の行として読めない行は分ける。from= の有無を見分ける。名札はコメント
#     (無ければ base64 の末尾) と鍵の種類。写しを置く受け持ち (-KeysFrom が先。無ければ写しの頭の runner の印で runner、印の無い写しは
#     wsl、写しが無ければ分からない) を見分け、鍵が 0 本・写しが無い・読めない行の案内を、runner なら TOML の [sshd] authorizedKeys と
#     dotfiles apply、wsl なら Nix の値と setup にする (分からなければ両方)。runner の写しの管理者の鍵のファイルの見出しは TOML を指す
#   - administrators_authorized_keys に書く中身 (鍵の行と ASCII の見出し) と、鍵の行の差 (足す・消す・並びも同じか)
#   - Windows Firewall のアドレスを数の区間にそろえて比べる (マスク表記・範囲・サブネットのどれで返っても同じ。隣り合う区間はつなぐ)。
#     外のアドレスは、tailnet・localhost と合わせて全部の空間をちょうど覆う。拒否の規則は 3 つで、読んだ規則が同じかを、有効・向き・
#     拒否・プロファイル・プロトコル・ポート・アドレスと、program などの絞りが Any かで比べる。拒否の規則が効かないプロファイル
#     (無効・ローカルの規則を止めた GPO) を見分ける
#   - 22 番を許す受信の規則の選び方 (COM の HNetCfg.FwPolicy2 の規則の形で渡す): 有効な受信の許可のうち、TCP の 22 番を名指しする規則と
#     sshd.exe の規則を選び、sshd.exe の規則と 22 番だけの規則を無効にする印を付ける。22 番とほかのポートを並べた規則は残し、全ポート・
#     範囲・2222 番・UDP・送信・拒否・無効の規則は数えない
#   - 例外を「<落ちたコマンド>: <文の 1 行目>」の 1 行にする (コマンドが分からなければ読み方の名前を頭に付ける)
#   - 鍵の指紋は ssh-keygen -l と同じ SHA256:<base64>
#   - BOM の付いたファイルを見分け、一時ファイルから差し替える (元を退避し、無ければそのまま置く)
#   - 鍵のファイルの権限は、継承を切り、管理者と SYSTEM だけに FullControl を許す形だけを通す
#   - Server を足すときの winget download と msiexec の引数 (同じ版を取り直し、ADDLOCAL=Client,Server。--include-pinned は付けない)
#   - 保守の install に渡す MSI の名前: GUID をレジストリの詰めた形にし、登録された PackageName (ディレクトリの中に置ける名前だけ) に
#     写して渡す (名前が同じなら写さない)。ProductCode が読めない・製品が入っていない・PackageName が読めない・PackageCode が違うときは止まる
#   - MSI を落とすディレクトリの権限 (AdminDirSddl) は、継承を切り、管理者と SYSTEM だけに FullControl で、中のファイルにも継ぐ
#     (Linux の .NET は SDDL を読めないので、使う形だけを読む読み手で Test-AdminOnlyAcl に通す)
#   - Install-Sshd.ps1 が読む $script: の変数は、どれも script のどこかで代入されている (構文木で見る。本体は StrictMode で流すので、
#     代入の無い変数を読むとそこで止まる)
#   - 管理者の段 (Invoke-SshdFix) を、Windows に触る cmdlet と関数を偽物に替えて StrictMode のまま流す。拒否の規則・sshd_config・空の鍵は
#     揃い sshd.exe とサービスが無い形 (MSI を落とす前に止まった後) から: 規則・設定・鍵には触らず、毎回新しい名前の管理者と SYSTEM だけの
#     ディレクトリに MSI を落とし、登録された PackageName に写して msiexec に渡して後で消し、22 番の許可を無効にし、ssh-agent を止めて無効にし、sshd を自動で起こす。揃えた後の
#     判定は 0。msiexec が落ちたらサービスに触らず止まり、ディレクトリは消す。権限を替えるまでに何か置かれたら MSI を落とさずに止まり、
#     ディレクトリは消さない。PackageName が読めない・製品が入っていないときは msiexec を流さずに止まる。在るディレクトリには作らない
#   - 判定: 揃っていれば 0、server が無ければ 3、ずれていれば 1。OpenSSH が無い・Windows の機能の OpenSSH Server がある・書けない
#     ユーザー名・鍵の写しの読めない行・拒否の規則が効かないプロファイル・サービスの無い sshd.exe は、揃えずに 1 で止まり、締めの行で
#     先に直すことを出す。BOM の付いた sshd_config・鍵はずれ。鍵のファイルを読めるときは足す鍵と消す鍵を、読めないとき (管理者でない) は
#     写しの鍵を全部、※ で名札と指紋つきで出す。22 番だけの許可は無効にし、
#     22 番とほかのポートを並べた許可は ※ で添えるだけ。管理者でなく読めないファイルは、揃えた
#     ときの記録と比べる。鍵の写しが無いときは鍵の中身を見ない。鍵が 0 本・from= の無い鍵・Tailscale が無いときは ※ で添える。
#     Windows Firewall の拒否の規則と 22 番の許可は別に読み、読めない方の行だけを ⚠ で「読めない (<落ちたコマンド>: <理由>)」にする
#   - 判定のユーザーと送り元: 使う AllowUsers と送り元をいつも ※ で出し、ホストの値に書いていなければ「既定」と、変え方を受け持ちごとに
#     添える。写しの値で作る sshd_config と比べる (既定と同じ値なら、写しが無いときと同じく揃っている)。0 人・0 なら誰も・どこからも
#     入れないと出し、tailnet と localhost の外にかかる送り元は拒否の規則が止めると添える。写しに読めない値があれば、揃えずに 1 で止まり、
#     sshd_config は比べず、読めない値と、ホストの値を直す締めの行を出す。写しに allowUsers があれば、流したユーザーの名前は検めない
#   - 管理者の段は、写しのユーザーと送り元で sshd_config を書き、書いた値をログに出す。写しに読めない値 (末尾の改行も) があれば何も変えずに
#     止まる
#   - MSI から読む GUID と、レジストリから読む MSI の名前の検めも、末尾に改行の付いた値を断る
#   - 書き換える前の sshd -t の試し: 管理者の段は、中身を書き換えるときだけ試す (ProgramData の ssh の下で)。断られたら書き換えず・起こし直さず
#     ・記録も書かずに止まり、sshd -t の出力を出す。通れば書き換えて起こし直す。sshd.exe がまだ無ければ試せないと出し、止めずに書く。
#     PATH に sshd と ssh-keygen があれば、Invoke-SshdConfigTest を本物の sshd で流し (使い捨てのホストの鍵を -h で渡す)、作った中身が通り、
#     改行で割れた中身 (ユーザー・送り元) が断られ、一時のファイルが残らないことを見る。sshd が無ければ試せない
#   - 本体の入口: 思わぬ例外では終了コード 2 で止まる
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# dot-source すると関数だけを読み、本体は走らない (Install-Sshd.ps1 の末尾)
. (Join-Path $PSScriptRoot 'Install-Sshd.ps1')

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
    # 文化に依存しない比較 (Ordinal)。-ceq は U+FE0F のような無視できる文字を無視するので、締めの行の ⚠️ を見分けられない
    if ([string]::Equals($e, $a, [System.StringComparison]::Ordinal)) {
        Write-Host "ok   $Name"
    } else {
        Write-Host "FAIL $Name"
        Write-Host "     expected: [$e]"
        Write-Host "     actual:   [$a]"
        $script:Failures++
    }
}

# 例の鍵 (作り物。from= の IP は tailnet の範囲の例)
$key1 = 'from="100.64.0.1,fd7a:115c:a1e0::1" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleExampleExampleExampleExampleExample01 phone (Herdr)'
$key2 = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleExampleExampleExampleExampleExample02'
$key3 = 'from="100.64.0.2" ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYExampleExample03 tablet'
# 本物の形の鍵 (使い捨て。秘密鍵は作った直後に消した)。指紋は ssh-keygen -lf で読んだ値
$realKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDdrtavif9L+rRlntUK51T6E+jG26ZPRouZ36lduScCu test-phone'
$realFp = 'SHA256:kLVpk0AH0TT1jO9AFrnyUS/AXw34tPRZq3ilh6aAlxY'

# Test-SshdUserName: AllowUsers に書けるユーザー名か
Test-Case 'ふつうの名前は書ける' 'True' { Test-SshdUserName -Name 'alice' }
Test-Case '数字・. _ - を含む名前も書ける' 'True' { Test-SshdUserName -Name 'a.b_c-1' }
Test-Case '大文字は小文字にしてから渡す (大文字のままは断る)' 'False' { Test-SshdUserName -Name 'Alice' }
Test-Case '空白・@・* を含む名前は断る' 'False False False' {
    Test-SshdUserName -Name 'john doe'; Test-SshdUserName -Name 'a@b'; Test-SshdUserName -Name 'a*'
}
Test-Case '空の名前は断る' 'False' { Test-SshdUserName -Name '' }
# .NET の正規表現の $ は末尾の改行の前でも当たる。写しの JSON に "alice\n" と書くと、$ で終える検めは通し、sshd_config の行が割れて
# sshd が起動しなくなる (Windows の sshd -T で exit 255)。検めは \z で終える
Test-Case '末尾・頭に改行の付いた名前は断る (改行の前で当たる $ でなく \z で終える)' 'False False False' {
    Test-SshdUserName -Name "alice`n"; Test-SshdUserName -Name "alice`r`n"; Test-SshdUserName -Name "`nalice"
}

# Test-SshdFromAddress: Match Address に書ける送り元か (win/runner/src/host.rs の sshd_from_check と同じ見方)
Test-Case 'IPv4・IPv6 のアドレスと、範囲の頭で書いた CIDR は書ける' 'True True True True True True True True True True' {
    foreach ($a in @('100.64.0.0/10', 'fd7a:115c:a1e0::/48', '127.0.0.1', '::1', '192.0.2.10', '192.0.2.0/24', '2001:db8::1', '2001:db8::/32', '0.0.0.0/0', '::ffff:192.0.2.1')) {
        Test-SshdFromAddress -Address $a
    }
}
Test-Case '長さが 32 (IPv4)・128 (IPv6) を超える・頭に 0 の付いた長さや組は断る' 'False False False False False' {
    Test-SshdFromAddress -Address '100.64.0.0/33'
    Test-SshdFromAddress -Address 'fd7a:115c:a1e0::/129'
    Test-SshdFromAddress -Address '100.64.0.0/010'
    Test-SshdFromAddress -Address '010.0.0.1'
    Test-SshdFromAddress -Address '100.64.0.0/'
}
Test-Case 'CIDR のアドレスに、長さより後ろのビットが立っていれば断る (sshd が起動しなくなる)' 'False False True True' {
    Test-SshdFromAddress -Address '100.64.0.1/10'
    Test-SshdFromAddress -Address 'fd7a:115c:a1e0::1/48'
    Test-SshdFromAddress -Address '100.64.0.1/32'
    Test-SshdFromAddress -Address 'fd7a:115c:a1e0::1/128'
}
Test-Case '否定・パターン・区切り・空白・ゾーン・名前・欠けた形・空は断る' 'False False False False False False False False False False' {
    foreach ($a in @('!100.64.0.0/10', '*', '100.64.*', '127.0.0.1,::1', ' 127.0.0.1', '127.0.0.1 ', 'fe80::1%eth0', 'example.com', '1.2.3', '')) {
        Test-SshdFromAddress -Address $a
    }
}
Test-Case '末尾に改行の付いた送り元は断る (CIDR・IPv4・IPv6 とも。\z で終える)' 'False False False False' {
    foreach ($a in @("100.64.0.0/10`n", "127.0.0.1`n", "::1`n", "fd7a:115c:a1e0::/48`r`n")) {
        Test-SshdFromAddress -Address $a
    }
}

# ConvertTo-Lf: CRLF を LF にそろえる
Test-Case 'CRLF を LF にする' "a`nb`n" { ConvertTo-Lf "a`r`nb`r`n" }

# Get-SshdConfigText: 作る sshd_config
$config = Get-SshdConfigText -AllowUser 'alice'
$configLines = @($config -split "`n")
Test-Case 'AllowUsers はユーザーだけ (接続元は Match Address で絞る)' 'AllowUsers alice' {
    $configLines | Where-Object { $_ -like 'AllowUsers *' }
}
# Win32-OpenSSH は sshd_config を読んだ後、AllowUsers・DenyUsers・AllowGroups・DenyGroups の語ごとに最初の / を \ に替える (domain/user の
# ため)。前に書いた alice@100.64.0.0/10 は alice@100.64.0.0\10 になり、tailnet からのログインを全部断った (Windows の実機の sshd -T で
# 見た)。Linux の sshd はこれを再現しないので、語に / と \ が無いことをここで見る
Test-Case 'AllowUsers・DenyUsers・AllowGroups・DenyGroups の語に / も \ も無い (Windows の sshd が / を \ に替える)' 0 {
    $words = @($configLines | Where-Object { $_ -match '^\s*(AllowUsers|DenyUsers|AllowGroups|DenyGroups)\s' } | ForEach-Object { @($_.Trim() -split '\s+' | Select-Object -Skip 1) })
    @($words | Where-Object { $_.Contains('/') -or $_.Contains('\') }).Count
}
Test-Case 'Match Address は tailnet と localhost の外に当たり、中は DenyUsers * だけ' 'Match Address *,!100.64.0.0/10,!fd7a:115c:a1e0::/48,!127.0.0.1,!::1|       DenyUsers *' {
    $i = [array]::FindIndex([string[]]$configLines, [Predicate[string]] { param($l) $l -like 'Match Address *' })
    $block = @($configLines[$i..($configLines.Count - 1)] | Select-Object -Skip 1)
    $end = [array]::FindIndex([string[]]$block, [Predicate[string]] { param($l) $l -like 'Match *' })
    $body = @($block[0..($end - 1)] | Where-Object { $_ -and -not $_.TrimStart().StartsWith('#') })
    (@($configLines[$i]) + $body) -join '|'
}
Test-Case 'Match Address は Match Group administrators より前 (Match は 2 つ)' 'True 2' {
    $configLines.IndexOf(($configLines | Where-Object { $_ -like 'Match Address *' })) -lt $configLines.IndexOf('Match Group administrators')
    @($configLines | Where-Object { $_ -match '^Match ' }).Count
}
Test-Case '鍵だけで入れる (パスワードとキーボード対話を止め、認証の方法を publickey に限る)' 'PubkeyAuthentication yes|PasswordAuthentication no|KbdInteractiveAuthentication no|AuthenticationMethods publickey' {
    ($configLines | Where-Object { $_ -match '^(PubkeyAuthentication|PasswordAuthentication|KbdInteractiveAuthentication|AuthenticationMethods) ' }) -join '|'
}
Test-Case 'AllowUsers は最初の Match より前 (Match の中に入れない)' 'True' {
    $firstMatch = [array]::FindIndex([string[]]$configLines, [Predicate[string]] { param($l) $l -like 'Match *' })
    $configLines.IndexOf(($configLines | Where-Object { $_ -like 'AllowUsers *' })) -lt $firstMatch
}
Test-Case '管理者の鍵は administrators_authorized_keys から読む (Win32-OpenSSH の既定)' '       AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys' {
    $configLines[$configLines.IndexOf('Match Group administrators') + 1]
}
Test-Case 'Match の後ろはその 1 行だけ (ほかの設定を Match の中に入れない)' 2 {
    $after = @($configLines[$configLines.IndexOf('Match Group administrators')..($configLines.Count - 1)] | Where-Object { $_ })
    $after.Count
}
Test-Case 'ListenAddress は書かない (起動のときに Tailscale の IP がまだ無いと落ちる)' 0 {
    @($configLines | Where-Object { $_ -match '^\s*ListenAddress' }).Count
}
Test-Case 'sftp の subsystem は残す (hc machine add の scp が使う)' 'Subsystem sftp sftp-server.exe' {
    $configLines | Where-Object { $_ -like 'Subsystem *' }
}
Test-Case '改行は LF で、CR は無く、末尾は改行' 'False True' { $config.Contains("`r"); $config.EndsWith("`n") }
Test-Case 'ASCII だけ (sshd は設定を byte のまま読む)' 'True' { $config -cmatch '^[\x00-\x7F]*$' }

# ユーザーと送り元をホストの値で持つ前に、Get-SshdConfigText -AllowUser 'alice' が作っていた中身 (そのまま写した)。既定の値 (ユーザー 1 人と
# 既定の送り元の並び) で作る中身は、これと 1 バイトも違わない (揃えたときの記録の sha256 が変わらず、写しを置いた後も Install-Sshd を流し直さずに
# 済む。値の無いホストにもずれが出ない)
$beforeHostValues = @'
# Written by dotfiles (Install-Sshd.ps1). Do not edit by hand: Install-Sshd -Check reports the difference,
# and Install-Sshd moves this file to sshd_config.dotfiles-bak-<time> and writes it again.
# Why it looks like this: dotfiles win/README.md, section "sshd".
#
# Public-key logins only, and only from Tailscale (the tailnet) and localhost. sshd listens on all
# addresses (with ListenAddress bound to the Tailscale IP, sshd fails at boot when that IP is not up yet).
# AllowUsers (this user only), Match Address + DenyUsers and the Windows Firewall block rules limit who and
# where logins can come from.

Port 22

# Public keys only: no passwords, no keyboard-interactive
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
AuthenticationMethods publickey

# Only this user. Where it may come from is limited by "Match Address" below, not by user@CIDR here:
# Win32-OpenSSH turns the first "/" of each AllowUsers word into "\" (for domain/user), so CIDR never matches.
AllowUsers alice

AuthorizedKeysFile .ssh/authorized_keys

Subsystem sftp sftp-server.exe

# Deny everyone unless the connection comes from the tailnet (100.64.0.0/10, fd7a:115c:a1e0::/48) or localhost.
# Match Address reads CIDR as written (also on Windows), and sshd applies Match before AllowUsers/DenyUsers.
Match Address *,!100.64.0.0/10,!fd7a:115c:a1e0::/48,!127.0.0.1,!::1
       DenyUsers *

# Administrators read their keys from ProgramData, not from the user profile (the Win32-OpenSSH default)
Match Group administrators
       AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys
'@ + "`n"
Test-Case '既定の値 (ユーザー 1 人・既定の送り元を同じ並びで) を渡しても、渡さなくても、ホストの値で持つ前の中身と 1 バイトも違わない' 'True True True' {
    [string]::Equals((Get-SshdConfigText -AllowUsers @('alice') -AllowFrom @('100.64.0.0/10', 'fd7a:115c:a1e0::/48', '127.0.0.1', '::1')), $beforeHostValues, [StringComparison]::Ordinal)
    [string]::Equals((Get-SshdConfigText -AllowUser 'alice'), $beforeHostValues, [StringComparison]::Ordinal)
    (Get-TextSha256 (Get-SshdConfigText -AllowUsers @('alice') -AllowFrom $script:DefaultAllowFrom)) -eq (Get-TextSha256 $beforeHostValues)
}
Test-Case '既定の送り元は tailnet の 2 つと localhost の 2 つ (拒否の規則の LocalAddress とは別の値)' '100.64.0.0/10 fd7a:115c:a1e0::/48 127.0.0.1 ::1' {
    $script:DefaultAllowFrom
}
# 例の値: 送り元は tailnet の 1 台 (IPv4) と tailnet の中の /64 (IPv6)、ユーザーは 2 人
$customFrom = @('100.64.0.1', 'fd7a:115c:a1e0:ab12::/64')
$configMulti = Get-SshdConfigText -AllowUsers @('alice', 'bob') -AllowFrom $customFrom
$configNobody = Get-SshdConfigText -AllowUsers @() -AllowFrom $script:DefaultAllowFrom
$configNowhere = Get-SshdConfigText -AllowUsers @('alice') -AllowFrom @()
function Get-ConfigLines { param([string]$Text) @($Text -split "`n") }
Test-Case 'ユーザーが 2 人なら AllowUsers に並べ、送り元は Match Address の否定に並べる' 'AllowUsers alice bob|Match Address *,!100.64.0.1,!fd7a:115c:a1e0:ab12::/64' {
    @(Get-ConfigLines $configMulti | Where-Object { $_ -like 'AllowUsers *' -or $_ -like 'Match Address *' }) -join '|'
}
Test-Case '既定でない値のコメントは値に合わせる (these users・ホストの値の送り元)' 'True True True False' {
    $configMulti.Contains('# AllowUsers (these users only), Match Address')
    $configMulti.Contains('# Only these users. Where they may come from is limited by "Match Address" below')
    $configMulti.Contains('# Deny everyone unless the connection comes from one of the addresses that the host values allow.')
    $configMulti.Contains('the tailnet (100.64.0.0/10, fd7a:115c:a1e0::/48) or localhost')
}
Test-Case 'ユーザーが 0 人なら AllowUsers を書かず (引数の無い AllowUsers は sshd が起動しない)、最初の Match より前に DenyUsers *' '0 True' {
    $lines = Get-ConfigLines $configNobody
    @($lines | Where-Object { $_ -match '^\s*AllowUsers' }).Count
    $firstMatch = [array]::FindIndex([string[]]$lines, [Predicate[string]] { param($l) $l -like 'Match *' })
    $lines.IndexOf('DenyUsers *') -ge 0 -and $lines.IndexOf('DenyUsers *') -lt $firstMatch
}
Test-Case '送り元が 0 なら Match Address * (どこから来ても DenyUsers *)' 'Match Address *' {
    @(Get-ConfigLines $configNowhere | Where-Object { $_ -like 'Match Address *' })
}
Test-Case 'どの値でも、AllowUsers・DenyUsers などの語に / も \ も無く、ASCII と LF だけ' '0 True False 0 True False 0 True False' {
    foreach ($t in @($configMulti, $configNobody, $configNowhere)) {
        $words = @(Get-ConfigLines $t | Where-Object { $_ -match '^\s*(AllowUsers|DenyUsers|AllowGroups|DenyGroups)\s' } | ForEach-Object { @($_.Trim() -split '\s+' | Select-Object -Skip 1) })
        @($words | Where-Object { $_.Contains('/') -or $_.Contains('\') }).Count
        $t -cmatch '^[\x00-\x7F]*$'
        $t.Contains("`r")
    }
}

# PATH に sshd があれば、作る sshd_config を sshd -G (host の鍵が要らない、設定を読んで出すだけの形) で読ませる。
# Match Address の CIDR の書き方の誤りは sshd が読む時点で落とす (起動しなくなる誤りを、ここで見つける)。
# ssh-keygen もあれば、使い捨ての host 鍵で sshd -T -C (接続元を与えて Match を当てた結果を出す形) を流し、どこから来たときに DenyUsers が
# 付くかを見る。Match Address の照らし方は Windows の sshd も同じ (AllowUsers の / の読み替えを通らない)
$sshd = Get-Command sshd -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($sshd) {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "install-sshd-test-$PID"
    $null = New-Item -ItemType Directory -Force -Path $tmp
    try {
        $cfg = Join-Path $tmp 'sshd_config'
        [IO.File]::WriteAllText($cfg, $config, [Text.UTF8Encoding]::new($false))
        Test-Case 'sshd -G が作る sshd_config を読める (終了コード 0)' 0 {
            $null = & $sshd.Source -G -f $cfg 2>&1
            $LASTEXITCODE
        }
        Test-Case 'sshd -G が読んだ AllowUsers は 1 つで、パスワードの認証は no' '1 True' {
            $out = @(& $sshd.Source -G -f $cfg 2>&1 | ForEach-Object { "$_" })
            @($out | Where-Object { $_ -match '^(?i)allowusers alice$' }).Count
            [bool](@($out | Where-Object { $_ -match '^(?i)passwordauthentication no$' }).Count -eq 1)
        }
        $bad = Join-Path $tmp 'bad_config'
        [IO.File]::WriteAllText($bad, "AllowUsers alice`nMatch Address *,!100.64.0.0/33`n       DenyUsers *`n", [Text.UTF8Encoding]::new($false))
        Test-Case 'sshd -G は書き方の誤った Match Address の CIDR を断る (確かめ方が効いている)' 'True' {
            $null = & $sshd.Source -G -f $bad 2>&1
            $LASTEXITCODE -ne 0
        }
        # 長さより後ろのビットが立った CIDR も、sshd は断る (Test-SshdFromAddress が先に止める誤り)
        [IO.File]::WriteAllText($bad, "AllowUsers alice`nMatch Address *,!100.64.0.1/10`n       DenyUsers *`n", [Text.UTF8Encoding]::new($false))
        Test-Case 'sshd -G は後ろのビットが立った Match Address の CIDR も断る (送り元の検めが止める誤り)' 'True' {
            $null = & $sshd.Source -G -f $bad 2>&1
            $LASTEXITCODE -ne 0
        }
        # ユーザーと送り元を渡した中身 (2 人と例の送り元・0 人・送り元 0) も読める
        $variant = @{}
        foreach ($e in @(@('multi', $configMulti), @('nobody', $configNobody), @('nowhere', $configNowhere))) {
            $variant[$e[0]] = Join-Path $tmp "sshd_config_$($e[0])"
            [IO.File]::WriteAllText($variant[$e[0]], $e[1], [Text.UTF8Encoding]::new($false))
        }
        Test-Case 'sshd -G がユーザーと送り元を渡した中身も読める (2 人・0 人・送り元 0)' '0 0 0' {
            foreach ($k in @('multi', 'nobody', 'nowhere')) {
                $null = & $sshd.Source -G -f $variant[$k] 2>&1
                $LASTEXITCODE
            }
        }
        $keygen = Get-Command ssh-keygen -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($keygen) {
            $hostKey = Join-Path $tmp 'host_key'
            $null = & $keygen.Source -q -t ed25519 -N '' -f $hostKey 2>&1
            # 接続元ごとに、sshd -T -C の出す DenyUsers (Match Address が当たったときだけ付く)
            $denied = {
                param([string]$Addr)
                $out = @(& $sshd.Source -T -f $cfg -h $hostKey -C "user=alice,host=$Addr,addr=$Addr" 2>&1 | ForEach-Object { "$_" })
                if ($LASTEXITCODE -ne 0) { return "rc=$LASTEXITCODE $($out -join ' ')" }
                [bool](@($out | Where-Object { $_ -match '^(?i)denyusers \*$' }).Count -eq 1)
            }
            Test-Case 'sshd -T -C: tailnet (/10 の端と中・/48 の中) と localhost から来たら DenyUsers は付かない' 'False False False False False False False' {
                foreach ($a in @('100.64.0.0', '100.100.1.1', '100.127.255.255', 'fd7a:115c:a1e0::1234', 'fd7a:115c:a1e0:ab12:4843:cd96:6258:b240', '127.0.0.1', '::1')) {
                    & $denied $a
                }
            }
            Test-Case 'sshd -T -C: tailnet と localhost の外 (/10 のすぐ外・100/8 の外側・LAN・ほかの IPv6) から来たら DenyUsers *' 'True True True True True True True' {
                foreach ($a in @('100.63.255.255', '100.128.0.0', '100.200.1.1', '192.168.1.10', '127.0.0.2', 'fd7a:115c:a1e1::1', '2001:db8::1')) {
                    & $denied $a
                }
            }
            Test-Case 'sshd -T -C: AllowUsers はどこから来てもユーザーだけ' 'allowusers alice' {
                @(& $sshd.Source -T -f $cfg -h $hostKey -C 'user=alice,host=100.100.1.1,addr=100.100.1.1' 2>&1 | ForEach-Object { "$_" } | Where-Object { $_ -match '^(?i)allowusers ' }) | ForEach-Object { $_.ToLowerInvariant() }
            }
            # 渡した中身ごとに、sshd -T -C の出す DenyUsers
            $deniedIn = {
                param([string]$Config, [string]$Addr)
                $out = @(& $sshd.Source -T -f $Config -h $hostKey -C "user=alice,host=$Addr,addr=$Addr" 2>&1 | ForEach-Object { "$_" })
                if ($LASTEXITCODE -ne 0) { return "rc=$LASTEXITCODE $($out -join ' ')" }
                [bool](@($out | Where-Object { $_ -match '^(?i)denyusers \*$' }).Count -eq 1)
            }
            Test-Case 'sshd -T -C: 例の送り元 (tailnet の 1 台と /64) から来たときだけ DenyUsers は付かない' 'False False False True True True True' {
                foreach ($a in @('100.64.0.1', 'fd7a:115c:a1e0:ab12::1', 'fd7a:115c:a1e0:ab12:ffff:ffff:ffff:ffff', '100.64.0.2', 'fd7a:115c:a1e0:ab13::1', '127.0.0.1', '192.168.1.10')) {
                    & $deniedIn $variant['multi'] $a
                }
            }
            # sshd -T は AllowUsers の値を 1 つ 1 行で出す
            Test-Case 'sshd -T -C: 2 人の AllowUsers' 'allowusers alice|allowusers bob' {
                @(& $sshd.Source -T -f $variant['multi'] -h $hostKey -C 'user=alice,host=100.64.0.1,addr=100.64.0.1' 2>&1 | ForEach-Object { "$_" } | Where-Object { $_ -match '^(?i)allowusers ' } | ForEach-Object { $_.ToLowerInvariant() }) -join '|'
            }
            Test-Case 'sshd -T -C: ユーザーが 0 人・送り元が 0 なら、どこから来ても DenyUsers * (tailnet・localhost も)' 'True True True True' {
                foreach ($k in @('nobody', 'nowhere')) {
                    foreach ($a in @('100.100.1.1', '127.0.0.1')) { & $deniedIn $variant[$k] $a }
                }
            }
            # Invoke-SshdConfigTest を本物の sshd で流す (書き換える前の試し。使い捨てのホストの鍵を -h で渡すので、ホストの鍵の無い所でも試せる)。
            # 改行で割れた中身 (写しの JSON の \n を検めずに通した形) は断る
            $testDir = Join-Path $tmp 'config-test'
            $null = New-Item -ItemType Directory -Force -Path $testDir
            $tried = [ordered]@{
                good       = Invoke-SshdConfigTest -SshdExe $sshd.Source -Text $config -Directory $testDir
                multi      = Invoke-SshdConfigTest -SshdExe $sshd.Source -Text $configMulti -Directory $testDir
                brokenUser = Invoke-SshdConfigTest -SshdExe $sshd.Source -Text (Get-SshdConfigText -AllowUsers @("alice`n", 'bob')) -Directory $testDir
                brokenFrom = Invoke-SshdConfigTest -SshdExe $sshd.Source -Text (Get-SshdConfigText -AllowUsers @('alice') -AllowFrom @("100.64.0.0/10`n", '127.0.0.1')) -Directory $testDir
            }
            Test-Case 'sshd -t で試す: 作った中身は通り、改行で割れた中身 (ユーザー・送り元) は断る。一時のファイルは残さない' 'True True|True True|True False|True False|True|0' {
                @(
                    foreach ($k in $tried.Keys) { "$($tried[$k].Tested) $($tried[$k].Ok)" }
                    "$((@($tried['brokenUser'].Lines) -join ' ').Contains('bob'))"
                    "$(@(Get-ChildItem -LiteralPath $testDir -Force).Count)"
                ) -join '|'
            }
            Test-Case 'sshd -t で試す: sshd が無ければ試せない (Tested が偽で、わけを返す)' 'False True' {
                $r = Invoke-SshdConfigTest -SshdExe (Join-Path $tmp 'none/sshd') -Text $config -Directory $testDir
                $r.Tested; $r.Why.EndsWith('が無い (server を足す前)')
            }
        } else {
            Write-Host 'skip sshd -T -C で Match Address を照らす確かめ (PATH に ssh-keygen が無い)'
        }
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
} else {
    Write-Host 'skip sshd -G で読ませる確かめ (PATH に sshd が無い。nix shell nixpkgs#openssh を足して流すと確かめる)'
}

# Get-KeyLines・Test-AuthorizedKeyLine・ConvertFrom-KeysCopy: 鍵の写しの読み方
Test-Case 'コメントと空の行を除き、前後の空白を落とす' "$key1|$key2" {
    @(Get-KeyLines -Lines @('# 見出し', '', "  $key1  ", '   ', $key2)) -join '|'
}
Test-Case 'from= の付いた ed25519・付かない ed25519・ecdsa は読める' 'True True True' {
    Test-AuthorizedKeyLine -Line $key1; Test-AuthorizedKeyLine -Line $key2; Test-AuthorizedKeyLine -Line $key3
}
Test-Case '鍵の種類が無い・base64 が無い・改行を含む行は読めない' 'False False False' {
    Test-AuthorizedKeyLine -Line 'hello world'
    Test-AuthorizedKeyLine -Line 'ssh-ed25519'
    Test-AuthorizedKeyLine -Line "$key2`n$key2"
}
Test-Case 'DSA の鍵は読まない (OpenSSH 10 は DSA を使えない)' 'False' {
    Test-AuthorizedKeyLine -Line 'ssh-dss AAAAB3NzaC1kc3MAAACBAExampleExampleExample'
}
Test-Case '写しの中身を鍵の行と読めない行に分ける' "2 1 $key2" {
    $c = ConvertFrom-KeysCopy -Lines @('# dotfiles の写し', $key1, 'garbage line', $key2)
    @($c.Lines).Count; @($c.Bad).Count; $c.Lines[1]
}
Test-Case '写しが見出しだけなら鍵は 0 本 (読めない行も 0)' '0 0' {
    $c = ConvertFrom-KeysCopy -Lines @('# dotfiles の写し', '')
    @($c.Lines).Count; @($c.Bad).Count
}

# Resolve-KeysFrom・Read-KeysCopy: 写しを置く受け持ち
Test-Case '受け持ちは -KeysFrom が先、無ければ写しの頭の runner の印、印が無ければ wsl、写しが無ければ分からない' 'wsl runner wsl runner <>' {
    Resolve-KeysFrom -KeysFrom 'wsl' -Exists $true -Lines @($script:RunnerCopyMark)
    Resolve-KeysFrom -KeysFrom '' -Exists $true -Lines @('# x', "  $($script:RunnerCopyMark) ", $key1)
    Resolve-KeysFrom -KeysFrom '' -Exists $true -Lines @('# dotfiles の写し (nix/scripts/bootstrap-windows-sshd.sh が書く)', $key1)
    Resolve-KeysFrom -KeysFrom 'runner' -Exists $false
    "<$(Resolve-KeysFrom -KeysFrom '' -Exists $false)>"
}
Test-Case 'runner の印は鍵の行に数えず、runner が書いた写しを runner と読む' "runner 1 0 $key1 <>" {
    $dir = Join-Path ([IO.Path]::GetTempPath()) ("sshd-copy-" + [guid]::NewGuid())
    $null = New-Item -ItemType Directory -Path $dir
    try {
        $path = Join-Path $dir 'authorized_keys'
        # win/runner/src/steps/sshd_keys.rs の copy_text と同じ形
        [IO.File]::WriteAllText($path, "# dotfiles の写し (Windows の runner の手順 sshd が書く。手で直さない)。`n$($script:RunnerCopyMark)`n$key1`n")
        $c = Read-KeysCopy -Path $path
        $c.From; @($c.Lines).Count; @($c.Bad).Count; $c.Lines[0]
        "<$((Read-KeysCopy -Path (Join-Path $dir 'none')).From)>"
    } finally {
        Remove-Item -LiteralPath $dir -Recurse -Force
    }
}

# ConvertFrom-AllowCopy・Read-AllowCopy・Resolve-SshdAccess: ユーザーと送り元の写し
function Get-Allow { param([string]$Json) ConvertFrom-AllowCopy -Json ($Json | ConvertFrom-Json) }
function Format-Allow {
    param($A)
    $show = { param($v) if ($null -eq $v) { 'null' } else { '[' + (@($v) -join ',') + ']' } }
    "$(& $show $A.Users) $(& $show $A.Addresses) $(@($A.Bad).Count)"
}
Test-Case '欄が無い・null は書いていない ($null)、[] は 0、list はその値' 'null null 0|null null 0|[] [] 0|[alice,bob] [100.64.0.1,fd7a:115c:a1e0::/48] 0' {
    @(
        Format-Allow (Get-Allow '{"version":1}')
        Format-Allow (Get-Allow '{"version":1,"allowUsers":null,"allowFrom":null}')
        Format-Allow (Get-Allow '{"version":1,"allowUsers":[],"allowFrom":[]}')
        Format-Allow (Get-Allow '{"version":1,"allowUsers":["alice","bob"],"allowFrom":["100.64.0.1","fd7a:115c:a1e0::/48"]}')
    ) -join '|'
}
Test-Case '1 つだけの list も list のまま (崩れて文字列にならない)・空の list は空のまま ($null にならない)' 'True 1 True 0' {
    $a = Get-Allow '{"version":1,"allowUsers":["alice"],"allowFrom":[]}'
    $a.Users -is [array]; @($a.Users).Count
    $a.Addresses -is [array]; @($a.Addresses).Count
}
Test-Case '書けない値は、欄と値と理由を読めない値に出す' 'allowUsers の Alice (英小文字・数字・. _ - の名前だけ)|allowFrom の 100.64.0.1/10 (IPv4・IPv6 のアドレスか、範囲の頭のアドレスで書いた CIDR だけ)|allowFrom の !127.0.0.1 (IPv4・IPv6 のアドレスか、範囲の頭のアドレスで書いた CIDR だけ)' {
    @((Get-Allow '{"version":1,"allowUsers":["alice","Alice"],"allowFrom":["100.64.0.1/10","!127.0.0.1"]}').Bad) -join '|'
}
Test-Case '写しの JSON の末尾の改行 (\n) は、ユーザー・送り元のどちらでも読めない値にし、値は改行を \n の字にして出す (※ の行を割らない)' '2|allowUsers の alice\n (英小文字・数字・. _ - の名前だけ)|allowFrom の 100.64.0.0/10\n (IPv4・IPv6 のアドレスか、範囲の頭のアドレスで書いた CIDR だけ)' {
    $bad = @((Get-Allow '{"version":1,"allowUsers":["alice\n","bob"],"allowFrom":["100.64.0.0/10\n","127.0.0.1"]}').Bad)
    (@("$($bad.Count)") + $bad) -join '|'
}
Test-Case '表に出す値は、制御文字を \n・\r・\t・\xNN の字にする' 'a\nb\r\tc\x07d' { ConvertTo-ShownValue "a`nb`r`tc$([char]7)d" }
Test-Case 'version が 1 でない・object でない・list でも null でもない・文字列でない値は読めない' 'version が 1 でない|JSON の object でない|allowUsers が list でも null でもない|allowFrom の 1 (IPv4・IPv6 のアドレスか、範囲の頭のアドレスで書いた CIDR だけ)' {
    @(
        (Get-Allow '{"version":2,"allowUsers":["alice"]}').Bad
        (Get-Allow '["alice"]').Bad
        (Get-Allow '{"version":1,"allowUsers":"alice"}').Bad
        (Get-Allow '{"version":1,"allowFrom":[1]}').Bad
    ) -join '|'
}
Test-Case 'runner の手順 sshd が書く写しを読め、無い写しは Managed が偽 (既定)、壊れた JSON は読めない値' 'True [alice] null 0|False null null 0|True null null 1' {
    $dir = Join-Path ([IO.Path]::GetTempPath()) ("sshd-allow-" + [guid]::NewGuid())
    $null = New-Item -ItemType Directory -Path $dir
    try {
        $path = Join-Path $dir 'allow.json'
        # win/runner/src/steps/sshd_allow.rs の copy_text と同じ形 (2 字下げの JSON と末尾の改行。BOM は付けない)
        [IO.File]::WriteAllText($path, @'
{
  "version": 1,
  "note": "dotfiles の写し (Windows の runner の手順 sshd が書く。手で直さない)。元は dotfiles-private の win/hosts/<ユーザー>@<PC>.toml の [sshd] allowUsers・allowFrom。Install-Sshd が sshd_config の AllowUsers と Match Address に書く (null は既定)",
  "allowUsers": [
    "alice"
  ],
  "allowFrom": null
}
'@ + "`n", [Text.UTF8Encoding]::new($false))
        $r = Read-AllowCopy -Path $path
        $none = Read-AllowCopy -Path (Join-Path $dir 'none.json')
        [IO.File]::WriteAllText($path, '{ broken', [Text.UTF8Encoding]::new($false))
        $broken = Read-AllowCopy -Path $path
        @("$($r.Managed) $(Format-Allow $r)", "$($none.Managed) $(Format-Allow $none)", "$($broken.Managed) $(Format-Allow $broken)") -join '|'
    } finally {
        Remove-Item -LiteralPath $dir -Recurse -Force
    }
}
$allowNone = [pscustomobject]@{ Managed = $false; Users = $null; Addresses = $null; Bad = @(); Path = 'C:\Users\alice\AppData\Local\dotfiles\sshd\allow.json' }
function New-Allow {
    param($Users = $null, $Addresses = $null, [string[]]$Bad = @())
    [pscustomobject]@{ Managed = $true; Users = $Users; Addresses = $Addresses; Bad = @($Bad); Path = $allowNone.Path }
}
Test-Case '使う値は、写しの値があればそれ、無ければ既定 (流したユーザーと、tailnet と localhost)。[] は 0 のまま' 'alice|100.64.0.0/10,fd7a:115c:a1e0::/48,127.0.0.1,::1|False False|bob|192.0.2.1|True True|0 0 True True' {
    $d = Resolve-SshdAccess -Allow $allowNone -User 'alice'
    $s = Resolve-SshdAccess -Allow (New-Allow -Users @('bob') -Addresses @('192.0.2.1')) -User 'alice'
    $z = Resolve-SshdAccess -Allow (New-Allow -Users @() -Addresses @()) -User 'alice'
    @(
        (@($d.Users) -join ','), (@($d.Addresses) -join ','), "$($d.UsersSet) $($d.AddressesSet)"
        (@($s.Users) -join ','), (@($s.Addresses) -join ','), "$($s.UsersSet) $($s.AddressesSet)"
        "$(@($z.Users).Count) $(@($z.Addresses).Count) $($z.UsersSet) $($z.AddressesSet)"
    ) -join '|'
}
Test-Case 'tailnet と localhost の外にかかる送り元を見分ける (拒否の規則が 22 番を止める)' 'False False False False True True True' {
    foreach ($a in @('100.64.0.1', 'fd7a:115c:a1e0:ab12::/64', '127.0.0.1', '::1', '192.0.2.1', '100.0.0.0/8', '2001:db8::/32')) {
        Test-SshdFromOutside -Address $a
    }
}

# Get-KeyLabel・Test-KeyWithoutFrom: 表に出す名札と from= の有無
Test-Case '名札はコメントと鍵の種類 (from= があれば何も添えない)' 'phone (Herdr) (ssh-ed25519)' { Get-KeyLabel -Line $key1 }
Test-Case 'コメントが無ければ base64 の末尾 8 字。from= が無ければ添える' '…xample02 (ssh-ed25519・from= 無し)' { Get-KeyLabel -Line $key2 }
Test-Case 'from= の有無' 'False True' { Test-KeyWithoutFrom -Line $key1; Test-KeyWithoutFrom -Line $key2 }
Test-Case '指紋は ssh-keygen -l と同じ SHA256:<base64> (from= が付いても同じ)' "$realFp $realFp" {
    Get-KeyFingerprint -Line $realKey; Get-KeyFingerprint -Line "from=`"100.64.0.1`" $realKey"
}
Test-Case 'base64 として読めない鍵の指紋は空 (名札には指紋を出さない)' '' { Get-KeyFingerprint -Line $key1 }
Test-Case '名札に指紋を添える' "test-phone (ssh-ed25519 $realFp・from= 無し)" { Get-KeyLabel -Line $realKey }

# Get-AdminKeysText: administrators_authorized_keys に書く中身
Test-Case '写しがあれば、見出しの後ろに鍵の行を並べ、LF で終える' "True $key1 $key3 True" {
    $t = Get-AdminKeysText -KeyLines @($key1, $key3)
    $lines = @(($t -split "`n") | Where-Object { $_ })
    $lines[0].StartsWith('# Written by dotfiles'); @(Get-KeyLines -Lines $lines) -join ' '; $t.EndsWith("`n")
}
Test-Case '写しが無いときに空で作る中身は、見出しだけ (鍵は 0 本)' 'True 0' {
    $t = Get-AdminKeysText -KeyLines @() -Managed $false
    $t.StartsWith('# Created empty by dotfiles'); @(Get-KeyLines -Lines ($t -split "`n")).Count
}
Test-Case '見出しは ASCII だけ' 'True True True' {
    (Get-AdminKeysText -KeyLines @($key1)) -cmatch '^[\x00-\x7F]*$'
    (Get-AdminKeysText -KeyLines @() -Managed $false) -cmatch '^[\x00-\x7F]*$'
    (Get-AdminKeysText -KeyLines @($key1) -From 'runner') -cmatch '^[\x00-\x7F]*$'
}
Test-Case 'runner の写しなら見出しは TOML の [sshd] authorizedKeys を指し、ほかは前からの見出しのまま (揃えたときの記録が変わらない)' "True False $key1 True" {
    $r = Get-AdminKeysText -KeyLines @($key1) -From 'runner'
    $r.Contains('[sshd] authorizedKeys'); $r.Contains('wsl.windowsFiles')
    @(Get-KeyLines -Lines ($r -split "`n")) -join ' '
    (Get-AdminKeysText -KeyLines @($key1) -From 'wsl') -ceq (Get-AdminKeysText -KeyLines @($key1))
}

# Compare-KeyLines: 鍵の行の差
Test-Case '同じ行が同じ並びなら Same' 'True 0 0' {
    $d = Compare-KeyLines -Want @($key1, $key2) -Have @($key1, $key2)
    $d.Same; @($d.Added).Count; @($d.Removed).Count
}
Test-Case '足す行と消す行を数える' "False $key3 $key2" {
    $d = Compare-KeyLines -Want @($key1, $key3) -Have @($key1, $key2)
    $d.Same; $d.Added; $d.Removed
}
Test-Case '並びだけが違っても書き直す (Same ではない。足す・消すは 0)' 'False 0 0' {
    $d = Compare-KeyLines -Want @($key2, $key1) -Have @($key1, $key2)
    $d.Same; @($d.Added).Count; @($d.Removed).Count
}
Test-Case '両方 0 本なら Same' 'True' { (Compare-KeyLines -Want @() -Have @()).Same }

# Get-TextSha256: 書いた中身の記録
Test-Case 'sha256 は小文字の 16 進 (BOM の無い UTF-8 の byte)' 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad' { Get-TextSha256 'abc' }
Test-Case '中身が違えば値も違う' 'True' { (Get-TextSha256 'a') -ne (Get-TextSha256 'b') }

# ConvertTo-AddressInterval・ConvertTo-CanonicalAddressList: Windows Firewall のアドレスを数の区間にそろえる
function Get-Canon { param([string[]]$A) (ConvertTo-CanonicalAddressList -Addresses $A) -join ' ' }
Test-Case 'マスク表記・長さ・範囲の 3 つの書き方が同じになる (Get-NetFirewallAddressFilter は /10 を /255.192.0.0 で返す)' 'True True' {
    (Get-Canon @('100.64.0.0/255.192.0.0')) -eq (Get-Canon @('100.64.0.0/10'))
    (Get-Canon @('100.64.0.0/10')) -eq (Get-Canon @('100.64.0.0-100.127.255.255'))
}
Test-Case '範囲がサブネットの形で返っても同じ (128.0.0.0-255.255.255.255 と 128.0.0.0/128.0.0.0)' 'True' {
    (Get-Canon @('128.0.0.0-255.255.255.255')) -eq (Get-Canon @('128.0.0.0/128.0.0.0'))
}
Test-Case '隣り合う区間はつなぐ・並びは問わない' 'True True' {
    (Get-Canon @('10.0.0.128/25', '10.0.0.0/25')) -eq (Get-Canon @('10.0.0.0/24'))
    (Get-Canon @('0.0.0.0-63.255.255.255', '64.0.0.0-100.63.255.255')) -eq (Get-Canon @('0.0.0.0-100.63.255.255'))
}
Test-Case 'IPv6 は大文字小文字・省略の仕方によらず同じ' 'True True' {
    (Get-Canon @('FD7A:115C:A1E0:0:0:0:0:0/48')) -eq (Get-Canon @('fd7a:115c:a1e0::/48'))
    (Get-Canon @('0:0:0:0:0:0:0:2-FD7A:115C:A1DF:FFFF:FFFF:FFFF:FFFF:FFFF')) -eq (Get-Canon @('::2-fd7a:115c:a1df:ffff:ffff:ffff:ffff:ffff'))
}
Test-Case 'Any などの語は小文字にして重なりを落とす' 'any' { Get-Canon @('Any', 'any') }
Test-Case '違う範囲は違う' 'False' { (Get-Canon @('100.64.0.0/10')) -eq (Get-Canon @('100.64.0.0/11')) }
# 外のアドレス・tailnet・localhost (127.0.0.0/8・::1)・:: を合わせると、IPv4 も IPv6 も全部の空間をちょうど覆う (外のアドレスに
# tailnet と localhost が入らず、ほかの漏れも無い)
Test-Case '外のアドレスは、tailnet と localhost の補集合 (合わせると全部の空間)' 'True' {
    $all = @($script:OutsideAddresses) + @($script:TailnetAddresses) + @('127.0.0.0/8', '::1', '::')
    (Get-Canon $all) -eq (Get-Canon @('0.0.0.0-255.255.255.255', '::-ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff'))
}
Test-Case '外のアドレスと tailnet・localhost は重ならない (区間の大きさの和が、空間の大きさとちょうど同じ)' 'True True' {
    $sum = {
        param($list, $family)
        $total = [System.Numerics.BigInteger]::Zero
        foreach ($a in $list) {
            $iv = ConvertTo-AddressInterval -Address $a
            if ($iv.Family -eq $family) { $total = $total + ($iv.Hi - $iv.Lo + 1) }
        }
        $total
    }
    $all = @($script:OutsideAddresses) + @($script:TailnetAddresses) + @('127.0.0.0/8', '::1', '::')
    (& $sum $all 'InterNetwork') -eq [System.Numerics.BigInteger]::Pow(2, 32)
    (& $sum $all 'InterNetworkV6') -eq [System.Numerics.BigInteger]::Pow(2, 128)
}

# Get-SshdFirewallSpecs・Test-FirewallRuleMatch: 拒否の規則
$specs = @(Get-SshdFirewallSpecs)
Test-Case '拒否の規則は 3 つ' 'dotfiles-sshd-tailnet-tcp dotfiles-sshd-tailnet-udp dotfiles-sshd-outside-tcp22' { $specs | ForEach-Object { $_.Name } }
Test-Case 'tailnet の TCP は 22 番以外 (1-21 と 23-65535)、宛先は tailnet のアドレス' 'TCP 1-21,23-65535 100.64.0.0/10,fd7a:115c:a1e0::/48 Any' {
    $s = $specs[0]; $s.Protocol; $s.LocalPort -join ','; $s.LocalAddress -join ','; $s.RemoteAddress -join ','
}
Test-Case 'tailnet の UDP は全ポート' 'UDP Any 100.64.0.0/10,fd7a:115c:a1e0::/48' {
    $s = $specs[1]; $s.Protocol; $s.LocalPort -join ','; $s.LocalAddress -join ','
}
Test-Case '外からの 22 番は、接続元が tailnet と localhost の外' 'TCP 22 Any 5' {
    $s = $specs[2]; $s.Protocol; $s.LocalPort -join ','; $s.LocalAddress -join ','; @($s.RemoteAddress).Count
}
# 外のアドレスに、tailnet と localhost が入っていないこと (範囲の端を並べて見る)
Test-Case '外のアドレスの範囲は、100.64.0.0/10・127.0.0.0/8・fd7a:115c:a1e0::/48・::1 の手前と後ろで切れる' '100.63.255.255 100.128.0.0 126.255.255.255 128.0.0.0 ::2 fd7a:115c:a1df:ffff:ffff:ffff:ffff:ffff fd7a:115c:a1e1::' {
    $r = $specs[2].RemoteAddress
    ($r[0] -split '-')[1]; ($r[1] -split '-')[0]; ($r[1] -split '-')[1]; ($r[2] -split '-')[0]
    ($r[3] -split '-')[0]; ($r[3] -split '-')[1]; ($r[4] -split '-')[0]
}
# Get-NetFirewallRule・Get-NetFirewallPortFilter・Get-NetFirewallAddressFilter が返す形 (IPv4 のサブネットはマスク表記)
function New-RuleFacts {
    param($Spec, [hashtable]$Change = @{})
    $local = @($Spec.LocalAddress | ForEach-Object { if ($_ -eq '100.64.0.0/10') { '100.64.0.0/255.192.0.0' } else { $_ } })
    $r = [ordered]@{
        Name = $Spec.Name; DisplayName = $Spec.DisplayName; Enabled = 'True'; Direction = 'Inbound'; Action = 'Block'; Profile = 'Any'
        Protocol = $Spec.Protocol; LocalPort = @($Spec.LocalPort); LocalAddress = $local; RemoteAddress = @($Spec.RemoteAddress)
        Program = 'Any'; Service = 'Any'; InterfaceAlias = @('Any'); InterfaceType = 'Any'
    }
    # GetEnumerator で回す ($Change.Keys は、Keys という名前の項目があるとその値を返す)
    foreach ($e in $Change.GetEnumerator()) { $r[$e.Key] = $e.Value }
    [pscustomobject]$r
}
Test-Case '作ったとおりの規則は同じ (マスク表記のアドレスでも)' 'True True True' {
    $specs | ForEach-Object { Test-FirewallRuleMatch -Spec $_ -Rule (New-RuleFacts -Spec $_) }
}
Test-Case '無い規則は同じでない' 'False' { Test-FirewallRuleMatch -Spec $specs[0] -Rule $null }
Test-Case 'program・サービス・インターフェイスで絞られた規則は同じでない (sshd に効かないことがある)' 'False False False False' {
    Test-FirewallRuleMatch -Spec $specs[2] -Rule (New-RuleFacts -Spec $specs[2] -Change @{ Program = 'C:\x\other.exe' })
    Test-FirewallRuleMatch -Spec $specs[2] -Rule (New-RuleFacts -Spec $specs[2] -Change @{ Service = 'Spooler' })
    Test-FirewallRuleMatch -Spec $specs[2] -Rule (New-RuleFacts -Spec $specs[2] -Change @{ InterfaceAlias = @('Wi-Fi') })
    Test-FirewallRuleMatch -Spec $specs[2] -Rule (New-RuleFacts -Spec $specs[2] -Change @{ InterfaceType = 'Wireless' })
}
Test-Case '範囲がサブネットの形で返った規則も同じ' 'True' {
    $remote = @($specs[2].RemoteAddress | ForEach-Object { if ($_ -eq '128.0.0.0-255.255.255.255') { '128.0.0.0/128.0.0.0' } else { $_ } })
    Test-FirewallRuleMatch -Spec $specs[2] -Rule (New-RuleFacts -Spec $specs[2] -Change @{ RemoteAddress = $remote })
}
Test-Case '無効・許可・Private だけ・22 番を含むポート・別の宛先は同じでない' 'False False False False False' {
    Test-FirewallRuleMatch -Spec $specs[0] -Rule (New-RuleFacts -Spec $specs[0] -Change @{ Enabled = 'False' })
    Test-FirewallRuleMatch -Spec $specs[0] -Rule (New-RuleFacts -Spec $specs[0] -Change @{ Action = 'Allow' })
    Test-FirewallRuleMatch -Spec $specs[0] -Rule (New-RuleFacts -Spec $specs[0] -Change @{ Profile = 'Private' })
    Test-FirewallRuleMatch -Spec $specs[0] -Rule (New-RuleFacts -Spec $specs[0] -Change @{ LocalPort = @('1-65535') })
    Test-FirewallRuleMatch -Spec $specs[0] -Rule (New-RuleFacts -Spec $specs[0] -Change @{ LocalAddress = @('Any') })
}

# Test-AdminOnlyAcl: 鍵のファイルの権限
function New-Acl {
    param([bool]$Protected = $true, [string]$Owner = 'S-1-5-32-544', $Rules)
    if ($null -eq $Rules) {
        $Rules = @(
            [pscustomobject]@{ Sid = 'S-1-5-32-544'; Rights = 'FullControl'; Type = 'Allow'; Inherited = $false }
            [pscustomobject]@{ Sid = 'S-1-5-18'; Rights = 'FullControl'; Type = 'Allow'; Inherited = $false }
        )
    }
    [pscustomobject]@{ Protected = $Protected; Owner = $Owner; Rules = @($Rules) }
}
Test-Case '継承を切り、管理者と SYSTEM だけに FullControl なら通す' 'True' { Test-AdminOnlyAcl -Acl (New-Acl) }
Test-Case '持ち主が SYSTEM でも通す' 'True' { Test-AdminOnlyAcl -Acl (New-Acl -Owner 'S-1-5-18') }
Test-Case '継承している・持ち主がユーザー・ユーザーにも許す・片方しか無い・読むだけは断る' 'False False False False False' {
    Test-AdminOnlyAcl -Acl (New-Acl -Protected $false)
    Test-AdminOnlyAcl -Acl (New-Acl -Owner 'S-1-5-21-1-2-3-1001')
    Test-AdminOnlyAcl -Acl (New-Acl -Rules @(
            [pscustomobject]@{ Sid = 'S-1-5-32-544'; Rights = 'FullControl'; Type = 'Allow'; Inherited = $false }
            [pscustomobject]@{ Sid = 'S-1-5-18'; Rights = 'FullControl'; Type = 'Allow'; Inherited = $false }
            [pscustomobject]@{ Sid = 'S-1-5-11'; Rights = 'ReadAndExecute, Synchronize'; Type = 'Allow'; Inherited = $false }
        ))
    Test-AdminOnlyAcl -Acl (New-Acl -Rules @([pscustomobject]@{ Sid = 'S-1-5-18'; Rights = 'FullControl'; Type = 'Allow'; Inherited = $false }))
    Test-AdminOnlyAcl -Acl (New-Acl -Rules @(
            [pscustomobject]@{ Sid = 'S-1-5-32-544'; Rights = 'Read'; Type = 'Allow'; Inherited = $false }
            [pscustomobject]@{ Sid = 'S-1-5-18'; Rights = 'FullControl'; Type = 'Allow'; Inherited = $false }
        ))
}
Test-Case '権限が読めなかった ($null) は断る' 'False' { Test-AdminOnlyAcl -Acl $null }

# AdminDirSddl: 取り直した MSI を落とすディレクトリの権限。Linux の .NET は SDDL を読めない (ACL の API が Windows だけ) ので、
# 使っている形 (持ち主・継承を切る P・ACE の並び) だけを読む小さな読み手で、Test-AdminOnlyAcl に渡す形にする
function ConvertFrom-TestSddl {
    param([string]$Sddl)
    $sids = @{ SY = 'S-1-5-18'; BA = 'S-1-5-32-544'; AU = 'S-1-5-11' }
    if (-not ($Sddl -cmatch '^O:([A-Z]{2})D:(P?)(?:AI)?((?:\([^()]*\))+)$')) { throw "読めない SDDL: $Sddl" }
    $owner = $sids[$Matches[1]]
    $protected = $Matches[2] -ceq 'P'
    $aces = $Matches[3]
    $rules = @(foreach ($m in [regex]::Matches($aces, '\(([^()]*)\)')) {
            # 種類;フラグ;権利;オブジェクト;継ぐオブジェクト;SID
            $f = $m.Groups[1].Value -split ';'
            if ($f.Count -ne 6) { throw "読めない ACE: $($m.Value)" }
            $rights = $f[2]
            if ($rights -ceq 'FA') { $rights = 'FullControl' }
            $type = $f[0]
            if ($type -ceq 'A') { $type = 'Allow' }
            [pscustomobject]@{ Sid = $sids[$f[5]]; Rights = $rights; Type = $type; Inherited = $f[1].Contains('ID'); Flags = $f[1] }
        })
    [pscustomobject]@{ Protected = $protected; Owner = $owner; Rules = $rules }
}
Test-Case 'MSI を落とすディレクトリの SDDL は、継承を切り、管理者と SYSTEM だけに FullControl (鍵のファイルと同じ判定を通る)' 'True' {
    Test-AdminOnlyAcl -Acl (ConvertFrom-TestSddl -Sddl $script:AdminDirSddl)
}
Test-Case 'その 2 つは中に落ちるファイルにも継ぐ (OICI)。持ち主は管理者で、グループと SACL は書かない' 'OICI OICI S-1-5-32-544 False' {
    $a = ConvertFrom-TestSddl -Sddl $script:AdminDirSddl
    @($a.Rules | ForEach-Object { $_.Flags }); $a.Owner; ($script:AdminDirSddl -cmatch 'G:|S:')
}
Test-Case '読み手の確かめ: C:\ProgramData\ssh の SDDL (認証したユーザーも読める) は通さない' 'False' {
    Test-AdminOnlyAcl -Acl (ConvertFrom-TestSddl -Sddl $script:SshDirSddl)
}

# $script: の変数の代入漏れ: 本体は Set-StrictMode -Version Latest で流すので、代入の無い $script: の変数を読むと、そこで止まる
# (管理者の段で $script:AdminDirSddl が無く、MSI を落とす前に止まった)。構文木で、読んでいる $script: の変数がどれも script の
# どこかで代入されているかを見る。script の一番外での代入と param も script の変数になる。関数の中の $script: の無い代入は数えない
function Get-UnassignedScriptVariables {
    param([System.Management.Automation.Language.ScriptBlockAst]$Ast)
    $assigned = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    if ($Ast.ParamBlock) {
        foreach ($p in $Ast.ParamBlock.Parameters) { [void]$assigned.Add($p.Name.VariablePath.UserPath) }
    }
    foreach ($a in $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
        $left = $a.Left
        while ($left -is [System.Management.Automation.Language.AttributedExpressionAst]) { $left = $left.Child }
        if ($left -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
        $inFunction = $false
        for ($q = $a.Parent; $null -ne $q; $q = $q.Parent) {
            if ($q -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $inFunction = $true; break }
        }
        if ($left.VariablePath.IsScript) {
            [void]$assigned.Add(($left.VariablePath.UserPath -replace '^script:', ''))
        } elseif ((-not $inFunction) -and $left.VariablePath.IsUnqualified) {
            [void]$assigned.Add($left.VariablePath.UserPath)
        }
    }
    @($Ast.FindAll({ param($n) ($n -is [System.Management.Automation.Language.VariableExpressionAst]) -and $n.VariablePath.IsScript }, $true) |
            ForEach-Object { $_.VariablePath.UserPath -replace '^script:', '' } |
            Where-Object { -not $assigned.Contains($_) } | Sort-Object -Unique)
}
Test-Case '読み手の確かめ: 代入の無い $script: の変数と、関数の中だけで代入した変数を拾う (一番外・$script: の代入・param は拾わない)' 'D Missing' {
    $text = 'param($P) $script:A = 1; $B = 2; [int]$E = 5; function f { $script:C = 3; $D = 4; $script:A; $script:B; $script:C; $script:D; $script:E; $script:P; $script:Missing }'
    Get-UnassignedScriptVariables -Ast ([System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$null))
}
Test-Case 'Install-Sshd.ps1 が読む $script: の変数は、どれも代入されている' '' {
    Get-UnassignedScriptVariables -Ast ([System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Install-Sshd.ps1'), [ref]$null, [ref]$null))
}

# Get-IneffectiveFirewallProfiles: 拒否の規則が効かないプロファイル
function New-Profiles {
    param([hashtable]$Change = @{})
    foreach ($n in @('Domain', 'Private', 'Public')) {
        $p = [ordered]@{ Name = $n; Enabled = 'True'; AllowLocal = 'NotConfigured' }
        if ($Change.ContainsKey($n)) { foreach ($e in $Change[$n].GetEnumerator()) { $p[$e.Key] = $e.Value } }
        [pscustomobject]$p
    }
}
Test-Case '3 つとも有効で GPO がローカルの規則を止めていなければ無い' 0 { @(Get-IneffectiveFirewallProfiles -Profiles (New-Profiles)).Count }
Test-Case '無効なプロファイルと、ローカルの規則を止めた (AllowLocal が False) プロファイルを出す' 'Private Public' {
    Get-IneffectiveFirewallProfiles -Profiles (New-Profiles -Change @{ Private = @{ Enabled = 'False' }; Public = @{ AllowLocal = 'False' } })
}

# Select-SshdAllowRules: 22 番を許す受信の規則を選ぶ。規則は COM (HNetCfg.FwPolicy2 の Rules) が返す形で渡す: Direction は 1 が受信・2 が送信、
# Action は 1 が許可・0 が拒否、Protocol は 6 が TCP・17 が UDP・256 がすべて。LocalPorts は , 区切りで、すべてなら空か *。値が無ければ $null
function New-ComRule {
    param([string]$Name, [hashtable]$Change = @{})
    $r = [ordered]@{ Name = $Name; Enabled = $true; Direction = 1; Action = 1; Protocol = 6; LocalPorts = '22'; ApplicationName = $null }
    foreach ($e in $Change.GetEnumerator()) { $r[$e.Key] = $e.Value }
    [pscustomobject]$r
}
function Get-Picked {
    param([object[]]$Rules)
    @(Select-SshdAllowRules -Rules $Rules | ForEach-Object { "$($_.DisplayName):$($_.Disable)" })
}
$msiRule = New-ComRule -Name 'OpenSSH SSH Server Preview (sshd)' -Change @{ ApplicationName = 'C:\Program Files\OpenSSH\sshd.exe' }
Test-Case 'MSI の規則 (sshd.exe の TCP 22) と Windows の機能の規則 (%SystemRoot% の sshd.exe) は無効にする。並びは名前の順' 'OpenSSH SSH Server (sshd):True OpenSSH SSH Server Preview (sshd):True' {
    Get-Picked @($msiRule, (New-ComRule -Name 'OpenSSH SSH Server (sshd)' -Change @{ ApplicationName = '%SystemRoot%\system32\OpenSSH\sshd.exe' }))
}
Test-Case 'program を問わず TCP の 22 番だけを許す規則は無効にし、22 番とほかのポートを並べた規則は残す (空白があっても読む)' 'only22:True ssh-rdp:False ssh-rdp-space:False' {
    Get-Picked @(
        (New-ComRule -Name 'only22')
        (New-ComRule -Name 'ssh-rdp' -Change @{ LocalPorts = '22,3389' })
        (New-ComRule -Name 'ssh-rdp-space' -Change @{ LocalPorts = '3389, 22' })
    )
}
Test-Case 'sshd.exe の規則は、プロトコルとポートが何でも無効にする (大文字小文字も問わない)' 'any-port:True upper:True' {
    Get-Picked @(
        (New-ComRule -Name 'any-port' -Change @{ Protocol = 256; LocalPorts = ''; ApplicationName = 'C:\Program Files\OpenSSH\sshd.exe' })
        (New-ComRule -Name 'upper' -Change @{ LocalPorts = '2222'; ApplicationName = 'C:\PROGRAM FILES\OPENSSH\SSHD.EXE' })
    )
}
Test-Case '数えない: 無効・送信・拒否・UDP の 22 番・2222 番・範囲・全ポート (空・*・$null)・OpenSSH の外の sshd.exe・ssh.exe' 0 {
    @(Select-SshdAllowRules -Rules @(
            (New-ComRule -Name 'disabled' -Change @{ Enabled = $false })
            (New-ComRule -Name 'outbound' -Change @{ Direction = 2 })
            (New-ComRule -Name 'block' -Change @{ Action = 0 })
            (New-ComRule -Name 'udp22' -Change @{ Protocol = 17 })
            (New-ComRule -Name 'port2222' -Change @{ LocalPorts = '2222' })
            (New-ComRule -Name 'range' -Change @{ LocalPorts = '1-1024' })
            (New-ComRule -Name 'Tailscale-In' -Change @{ Protocol = 256; LocalPorts = '' })
            (New-ComRule -Name 'all-tcp' -Change @{ LocalPorts = '*' })
            (New-ComRule -Name 'null-ports' -Change @{ LocalPorts = $null })
            (New-ComRule -Name 'other-sshd' -Change @{ LocalPorts = '2222'; ApplicationName = 'C:\tools\sshd.exe' })
            (New-ComRule -Name 'ssh-client' -Change @{ Protocol = 256; LocalPorts = ''; ApplicationName = 'C:\Program Files\OpenSSH\ssh.exe' })
        )).Count
}
Test-Case '規則が無い・$null が混ざっても落ちない' '0 0 1' {
    @(Select-SshdAllowRules -Rules @()).Count
    @(Select-SshdAllowRules -Rules @($null)).Count
    @(Select-SshdAllowRules -Rules @($null, $msiRule)).Count
}
Test-Case 'Rule に元の規則を持つ (無効にするときは、その COM の規則の Enabled を書く)' 'True' {
    [object]::ReferenceEquals(@(Select-SshdAllowRules -Rules @($msiRule))[0].Rule, $msiRule)
}

# Get-ErrorSummary: 「読めない」の行に出す、落ちたコマンドと理由
Test-Case 'コマンドの失敗は「<コマンド>: <文>」' 'True' {
    try {
        Get-Item -LiteralPath (Join-Path ([IO.Path]::GetTempPath()) "install-sshd-missing-$PID") -ErrorAction Stop
        'no error'
    } catch {
        (Get-ErrorSummary -ErrorRecord $_ -Fallback 'HNetCfg.FwPolicy2').StartsWith('Get-Item: ')
    }
}
Test-Case 'コマンドが分からない例外は、読み方の名前を頭に付け、文は 1 行目だけ (渡さなければ文だけ)' 'HNetCfg.FwPolicy2: denied|denied' {
    try {
        throw [System.UnauthorizedAccessException]::new("denied`r`n  second line")
    } catch {
        (Get-ErrorSummary -ErrorRecord $_ -Fallback 'HNetCfg.FwPolicy2') + '|' + (Get-ErrorSummary -ErrorRecord $_)
    }
}

# Get-WingetDownloadArgs・Get-MsiAddServerArgs・Get-MsiexecResultText: Server を足す
Test-Case 'winget download は同じ版を、決めた場所へ取り直す (pin を越える引数は付けない)' 'download Microsoft.OpenSSH.Preview 10.4.0.0 D:\tmp\msi False' {
    $a = Get-WingetDownloadArgs -PackageId 'Microsoft.OpenSSH.Preview' -Version '10.4.0.0' -Directory 'D:\tmp\msi'
    $a[0]; $a[$a.IndexOf('--id') + 1]; $a[$a.IndexOf('--version') + 1]; $a[$a.IndexOf('--download-directory') + 1]; $a -contains '--include-pinned'
}
Test-Case 'msiexec は取り直した MSI に Client と Server を並べ、黙って流してログを取る (パスは "" で囲む)' '/i "D:\m x\o.msi" ADDLOCAL=Client,Server /qn /norestart /l*v "D:\l.log"' {
    (Get-MsiAddServerArgs -Msi 'D:\m x\o.msi' -Log 'D:\l.log') -join ' '
}
Test-Case 'msiexec の 0 と 3010 は足せた、1618 は別のインストールが進んでいる' 'True True True' {
    $null -eq (Get-MsiexecResultText -ExitCode 0)
    $null -eq (Get-MsiexecResultText -ExitCode 3010)
    (Get-MsiexecResultText -ExitCode 1618).Contains('別のインストール')
}

# ConvertTo-PackedGuid・Test-MsiPackageName・Get-MsiSourcePlan: 保守の install に渡す MSI の名前
Test-Case 'GUID を Windows Installer のレジストリの詰めた形にする ({} の有無・大文字小文字によらない)' '68AB67CA7DA73301B7449A0000000010 76543210BA98FEDC1032547698BADCFE 76543210BA98FEDC1032547698BADCFE' {
    ConvertTo-PackedGuid -Guid '{AC76BA86-7AD7-1033-7B44-A90000000001}'
    ConvertTo-PackedGuid -Guid '{01234567-89AB-CDEF-0123-456789ABCDEF}'
    ConvertTo-PackedGuid -Guid '01234567-89ab-cdef-0123-456789abcdef'
}
Test-Case 'GUID として読めなければ $null (末尾に改行が付いた値も。.NET の $ は末尾の改行の前でも当たるので \z で終える)' 'True True True' {
    $null -eq (ConvertTo-PackedGuid -Guid '')
    $null -eq (ConvertTo-PackedGuid -Guid '{C3DFF1A5-DB4C-4B49-9FC7}')
    $null -eq (ConvertTo-PackedGuid -Guid "{01234567-89AB-CDEF-0123-456789ABCDEF}`n")
}
Test-Case 'MSI の名前はディレクトリの中に置ける名前だけ (区切り・ドライブ・.msi で終わらない名前・末尾の改行は断る)' 'True True False False False False False False' {
    Test-MsiPackageName -Name 'OpenSSH-Win64-v10.4.0.0.msi'
    Test-MsiPackageName -Name 'OpenSSH Preview_10.4.0.0_Machine_X64_msi_en-US.msi'
    Test-MsiPackageName -Name '..\x.msi'
    Test-MsiPackageName -Name 'C:x.msi'
    Test-MsiPackageName -Name 'a/b.msi'
    Test-MsiPackageName -Name 'x.exe'
    Test-MsiPackageName -Name ''
    Test-MsiPackageName -Name "OpenSSH-Win64-v10.4.0.0.msi`n"
}
$pc = '{C3DFF1A5-DB4C-4B49-9FC7-346BAA182D99}'
$pkg = '{01234567-89AB-CDEF-0123-456789ABCDEF}'
$pkgPacked = '76543210BA98FEDC1032547698BADCFE'
function New-MsiFacts {
    param([string]$Name = 'OpenSSH Preview_10.4.0.0_Machine_X64_msi_en-US.msi', $ProductCode = $pc, $PackageCode = $pkg)
    [pscustomobject]@{ Name = $Name; ProductCode = $ProductCode; PackageCode = $PackageCode }
}
function New-InstalledFacts {
    param([bool]$Exists = $true, $PackageName = 'OpenSSH-Win64-v10.4.0.0.msi', $PackageCode = $pkgPacked)
    [pscustomobject]@{ Exists = $Exists; PackageName = $PackageName; PackageCode = $PackageCode }
}
function Format-Plan { param($Plan) "$($Plan.Name)|$($Plan.Copy)|$($Plan.Error)" }
Test-Case 'winget download が別の名前で保存した MSI は、登録された PackageName に写して渡す' 'OpenSSH-Win64-v10.4.0.0.msi|True|' {
    Format-Plan (Get-MsiSourcePlan -Msi (New-MsiFacts) -Installed (New-InstalledFacts))
}
Test-Case '名前が同じ (大文字小文字だけ違う) なら写さない' 'OpenSSH-Win64-v10.4.0.0.msi|False| OpenSSH-Win64-v10.4.0.0.msi|False|' {
    Format-Plan (Get-MsiSourcePlan -Msi (New-MsiFacts -Name 'OpenSSH-Win64-v10.4.0.0.msi') -Installed (New-InstalledFacts))
    Format-Plan (Get-MsiSourcePlan -Msi (New-MsiFacts -Name 'openssh-win64-v10.4.0.0.MSI') -Installed (New-InstalledFacts))
}
Test-Case '入れたときの PackageCode が登録に無ければ、PackageCode は照らさない' 'OpenSSH-Win64-v10.4.0.0.msi|True|' {
    Format-Plan (Get-MsiSourcePlan -Msi (New-MsiFacts -PackageCode $null) -Installed (New-InstalledFacts -PackageCode $null))
}
Test-Case 'ProductCode が読めない・製品が入っていない・PackageName が読めない・PackageCode が違うときは止まる' @(
    '||落とした MSI の ProductCode が読めない'
    "||落とした MSI の製品 ($pc) がこの PC に入っていない (入っている OpenSSH と製品が違う)"
    "||入っている製品 ($pc) の、登録された MSI の名前 (SourceList の PackageName) が読めない ()"
    "||入っている製品 ($pc) の、登録された MSI の名前 (SourceList の PackageName) が読めない (..\OpenSSH.msi)"
    "||落とした MSI のパッケージ (PackageCode {11111111-89AB-CDEF-0123-456789ABCDEF}) が、入れたときのものと違う (同じ版を作り直した MSI は、保守の install の原本にならない)"
    "||落とした MSI のパッケージ (PackageCode ) が、入れたときのものと違う (同じ版を作り直した MSI は、保守の install の原本にならない)"
) {
    $bad = { param($p) (Format-Plan $p) -replace '\|False\|', '||' }
    & $bad (Get-MsiSourcePlan -Msi (New-MsiFacts -ProductCode $null) -Installed (New-InstalledFacts))
    & $bad (Get-MsiSourcePlan -Msi (New-MsiFacts) -Installed (New-InstalledFacts -Exists $false))
    & $bad (Get-MsiSourcePlan -Msi (New-MsiFacts) -Installed (New-InstalledFacts -PackageName $null))
    & $bad (Get-MsiSourcePlan -Msi (New-MsiFacts) -Installed (New-InstalledFacts -PackageName '..\OpenSSH.msi'))
    & $bad (Get-MsiSourcePlan -Msi (New-MsiFacts -PackageCode '{11111111-89AB-CDEF-0123-456789ABCDEF}') -Installed (New-InstalledFacts))
    & $bad (Get-MsiSourcePlan -Msi (New-MsiFacts -PackageCode $null) -Installed (New-InstalledFacts))
}

# Read-TextFile・Write-TextReplacing: BOM を見分ける・一時ファイルから差し替える (一時のディレクトリで流す)
$ftmp = Join-Path ([IO.Path]::GetTempPath()) "install-sshd-files-$PID"
$null = New-Item -ItemType Directory -Force -Path $ftmp
try {
    $f = Join-Path $ftmp 'sshd_config'
    Test-Case '無いファイルは Exists が偽' 'False False' { $r = Read-TextFile -Path $f; $r.Exists; $r.Readable }
    [IO.File]::WriteAllText($f, "Port 22`n", [Text.UTF8Encoding]::new($true))
    Test-Case 'BOM の付いたファイルは HasBom が真で、中身は BOM を除いて読む' "True True Port 22`n" { $r = Read-TextFile -Path $f; $r.Readable; $r.HasBom; $r.Text }
    Write-TextReplacing -Path $f -Text "Port 2222`n" -Backup "$f.bak"
    Test-Case '在れば元を退避して差し替え、BOM を付けない (一時ファイルは残さない)' "False Port 2222`n True False" {
        $r = Read-TextFile -Path $f; $r.HasBom; $r.Text; (Test-Path -LiteralPath "$f.bak"); (Test-Path -LiteralPath "$f.dotfiles-tmp")
    }
    $g = Join-Path $ftmp 'new_file'
    Write-TextReplacing -Path $g -Text "x`n" -Backup "$g.bak"
    Test-Case '無ければそのまま置く (退避は作らない)' "x`n False" { (Read-TextFile -Path $g).Text; (Test-Path -LiteralPath "$g.bak") }
} finally {
    Remove-Item -LiteralPath $ftmp -Recurse -Force -ErrorAction SilentlyContinue
}

# Get-SshdVerdict・Format-SshdState・Get-SshdExitCode・Get-SshdCheckMessage: 判定と表
$copyPath = 'C:\Users\alice\AppData\Local\dotfiles\sshd\authorized_keys'
function New-Facts {
    param([hashtable]$Change = @{})
    $rules = @{}
    foreach ($s in @(Get-SshdFirewallSpecs)) { $rules[$s.Name] = New-RuleFacts -Spec $s }
    $f = [ordered]@{
        InstallDir       = 'C:\Program Files\OpenSSH'
        User             = 'alice'
        OpenSsh          = $true
        Server           = $true
        Inbox            = $false
        Service          = [pscustomobject]@{ Exists = $true; Status = 'Running'; StartType = 'Automatic' }
        Config           = [pscustomobject]@{ Exists = $true; Readable = $true; HasBom = $false; Text = (Get-SshdConfigText -AllowUser 'alice') }
        Keys             = [pscustomobject]@{ Exists = $true; Readable = $true; HasBom = $false; Text = (Get-AdminKeysText -KeyLines @($key1)) }
        Acl              = [pscustomobject]@{ Readable = $true; Value = (New-Acl) }
        Record           = [pscustomobject]@{ ConfigSha = $null; KeysSha = $null }
        Copy             = [pscustomobject]@{ Managed = $true; Lines = @($key1); Bad = @(); Path = $copyPath; From = 'wsl' }
        Allow            = $allowNone
        FirewallReadable = $true
        FirewallError    = $null
        FirewallProfiles = @(New-Profiles)
        Rules            = $rules
        AllowReadable    = $true
        AllowError       = $null
        AllowRules       = @()
        Tailscale        = $true
    }
    # GetEnumerator で回す ($Change.Keys は、Keys という名前の項目 (鍵のファイルの事実) があるとその値を返す)
    foreach ($e in $Change.GetEnumerator()) { $f[$e.Key] = $e.Value }
    [pscustomobject]$f
}
function Get-WarnRows {
    param($Facts)
    @(Format-SshdState -Verdict (Get-SshdVerdict -Facts $Facts) | Where-Object Warn | ForEach-Object Text)
}
function Get-Notes {
    param($Facts)
    @(Format-SshdState -Verdict (Get-SshdVerdict -Facts $Facts) | Where-Object { $_.Text.StartsWith('※') } | ForEach-Object Text)
}

$ok = New-Facts
Test-Case '揃っていれば 0 で、⚠ の行は無く、締めは「揃っている」' '0 0 揃っている' {
    $v = Get-SshdVerdict -Facts $ok
    Get-SshdExitCode -Verdict $v; @(Get-WarnRows $ok).Count; Get-SshdCheckMessage -Verdict $v
}
Test-Case '表の見出しは sshd (OpenSSH Server、<置き場所>) (wrapper と runner がこれで表を見分ける)' 'sshd (OpenSSH Server、C:\Program Files\OpenSSH)' {
    @(Format-SshdState -Verdict (Get-SshdVerdict -Facts $ok))[0].Text
}
Test-Case '揃っていれば、鍵の名札を ※ で添える' '※ 鍵: phone (Herdr) (ssh-ed25519)' { Get-Notes $ok | Where-Object { $_ -like '※ 鍵*' } }

# 判定のユーザーと送り元 (※ の行と、写しの値で作る sshd_config との比べ方)
function Get-AccessNotes { param($Facts) @(Get-Notes $Facts | Where-Object { $_ -notlike '※ 鍵*' }) -join '|' }
Test-Case '写しが無ければ、使うユーザーと送り元を既定と ※ で出し、受け持ち (wsl) の言い方を添える (揃っている)' @(
    '0'
    '※ AllowUsers: alice (ホストの値に書いていない。既定: Install-Sshd を流したユーザー)|※ 送り元: 100.64.0.0/10・fd7a:115c:a1e0::/48・127.0.0.1・::1 (ホストの値に書いていない。既定: tailnet と localhost)|※ 受け持ちが WSL の setup のホストでは、ユーザー・送り元は既定のまま (ホストの値の [sshd] allowUsers・allowFrom で変えられるのは、受け持ちが runner のホストだけ)'
) {
    Get-SshdExitCode -Verdict (Get-SshdVerdict -Facts $ok)
    Get-AccessNotes $ok
}
Test-Case '変え方は受け持ちごと (runner なら TOML と dotfiles apply・Install-Sshd、分からなければ両方)' 'True False True True' {
    $hint = { param($from) @(Get-Notes (New-Facts -Change @{ Copy = [pscustomobject]@{ Managed = $true; Lines = @($key1); Bad = @(); Path = $copyPath; From = $from } }) | Where-Object { $_ -like '※ *ユーザー・送り元*' })[0] }
    (& $hint 'runner').Contains('[sshd] allowUsers・allowFrom) に書いて dotfiles apply を流し、Install-Sshd で揃える')
    (& $hint 'runner').Contains('WSL')
    (& $hint '').Contains('受け持ちが runner のホストなら')
    (& $hint '').Contains('受け持ちが WSL の setup のホストは既定のまま')
}
Test-Case '写しの値が既定と同じなら、sshd_config は写しが無いときと同じで揃っている (※ はホストの値。変え方は出さない)' @(
    '0'
    '※ AllowUsers: alice (ホストの値)|※ 送り元: 100.64.0.0/10・fd7a:115c:a1e0::/48・127.0.0.1・::1 (ホストの値)'
) {
    $f = New-Facts -Change @{ Allow = (New-Allow -Users @('alice') -Addresses @('100.64.0.0/10', 'fd7a:115c:a1e0::/48', '127.0.0.1', '::1')) }
    Get-SshdExitCode -Verdict (Get-SshdVerdict -Facts $f)
    Get-AccessNotes $f
}
Test-Case '写しの値が違えば sshd_config は違う (1)。読めない sshd_config は、写しの値で作った中身の記録と比べる' '1 ⚠ sshd_config     : dotfiles の中身と違う → 退避して書き直す 0' {
    $allow = New-Allow -Users @('alice', 'bob') -Addresses $customFrom
    $f = New-Facts -Change @{ Allow = $allow }
    Get-SshdExitCode -Verdict (Get-SshdVerdict -Facts $f)
    Get-WarnRows $f
    $record = [pscustomobject]@{ ConfigSha = (Get-TextSha256 $configMulti); KeysSha = $null }
    Get-SshdExitCode -Verdict (Get-SshdVerdict -Facts (New-Facts -Change @{ Allow = $allow; Config = [pscustomobject]@{ Exists = $true; Readable = $false; HasBom = $false; Text = $null }; Record = $record }))
}
Test-Case '写しの値は ※ で並べ、ホストの値と出す (2 人・例の送り元)' '※ AllowUsers: alice・bob (ホストの値)|※ 送り元: 100.64.0.1・fd7a:115c:a1e0:ab12::/64 (ホストの値)' {
    Get-AccessNotes (New-Facts -Change @{ Allow = (New-Allow -Users @('alice', 'bob') -Addresses $customFrom); Config = [pscustomobject]@{ Exists = $true; Readable = $true; HasBom = $false; Text = $configMulti } })
}
Test-Case '[] なら誰も・どこからも入れないと出す (揃っている扱い)' '0 ※ AllowUsers: 無し (ホストの値が []。誰も入れない)|※ 送り元: 無し (ホストの値が []。どこからも入れない)' {
    $f = New-Facts -Change @{ Allow = (New-Allow -Users @() -Addresses @()); Config = [pscustomobject]@{ Exists = $true; Readable = $true; HasBom = $false; Text = (Get-SshdConfigText -AllowUsers @() -AllowFrom @()) } }
    Get-SshdExitCode -Verdict (Get-SshdVerdict -Facts $f)
    Get-AccessNotes $f
}
Test-Case 'tailnet と localhost の外にかかる送り元は、拒否の規則が止めると ※ で添える (既定の値には出さない)' '1 True 0' {
    $f = New-Facts -Change @{ Allow = (New-Allow -Addresses @('100.64.0.1', '192.0.2.0/24')) }
    $n = @(Get-Notes $f | Where-Object { $_ -like '※ 送り元 *拒否の規則*' })
    $n.Count; $n[0].StartsWith('※ 送り元 192.0.2.0/24 は tailnet と localhost の外を含む')
    @(Get-Notes $ok | Where-Object { $_ -like '※ 送り元 *拒否の規則*' }).Count
}
Test-Case '写しに allowUsers だけがあれば、送り元は既定で、変え方を添える' '※ AllowUsers: bob (ホストの値)|※ 送り元: 100.64.0.0/10・fd7a:115c:a1e0::/48・127.0.0.1・::1 (ホストの値に書いていない。既定: tailnet と localhost)|※ ユーザー・送り元を変えるなら、ホストの値 (dotfiles-private の win/hosts/<ユーザー>@<PC>.toml の [sshd] allowUsers・allowFrom) に書いて dotfiles apply を流し、Install-Sshd で揃える' {
    Get-AccessNotes (New-Facts -Change @{ Allow = (New-Allow -Users @('bob')); Copy = [pscustomobject]@{ Managed = $true; Lines = @($key1); Bad = @(); Path = $copyPath; From = 'runner' } })
}
Test-Case '写しに読めない値があれば 1 で止まり (server が無くても 3 にしない)、sshd_config は比べず、読めない値と直し方を出す' @(
    '1'
    '⚠️ ユーザーと送り元の写しに読めない値がある → ホストの値 (dotfiles-private の win/hosts の TOML の [sshd] allowUsers・allowFrom) を直して dotfiles apply を流し直す ⚠️'
    '⚠ sshd_config     : ユーザーと送り元の写しに読めない値があるので、比べない'
    '※ ユーザーと送り元の写し (C:\Users\alice\AppData\Local\dotfiles\sshd\allow.json) の読めない値: allowFrom の 100.64.0.1/10 (IPv4・IPv6 のアドレスか、範囲の頭のアドレスで書いた CIDR だけ)'
) {
    $f = New-Facts -Change @{ Server = $false; Allow = (New-Allow -Bad @('allowFrom の 100.64.0.1/10 (IPv4・IPv6 のアドレスか、範囲の頭のアドレスで書いた CIDR だけ)')) }
    $v = Get-SshdVerdict -Facts $f
    Get-SshdExitCode -Verdict $v
    Get-SshdCheckMessage -Verdict $v
    @(Get-WarnRows $f | Where-Object { $_ -like '⚠ sshd_config*' })
    Get-AccessNotes $f
}
Test-Case '写しに allowUsers があれば、流したユーザーの名前は検めない (書けない名前でも止めない)' '0' {
    $f = New-Facts -Change @{ User = 'john doe'; Allow = (New-Allow -Users @('alice')) }
    Get-SshdExitCode -Verdict (Get-SshdVerdict -Facts $f)
}

$notInstalled = New-Facts -Change @{
    Server  = $false
    Service = [pscustomobject]@{ Exists = $false; Status = $null; StartType = $null }
    Config  = [pscustomobject]@{ Exists = $false; Readable = $false; HasBom = $false; Text = $null }
    Keys    = [pscustomobject]@{ Exists = $false; Readable = $false; HasBom = $false; Text = $null }
    Acl     = [pscustomobject]@{ Readable = $false; Value = $null }
    Rules   = @{}
}
Test-Case 'server が無ければ 3 で、締めは -IfMissing で入れる (UAC が出る)' '3 True True' {
    $v = Get-SshdVerdict -Facts $notInstalled
    Get-SshdExitCode -Verdict $v
    (Get-SshdCheckMessage -Verdict $v).Contains('sshd が入っていない → Install-Sshd -IfMissing で入れる')
    (Get-SshdCheckMessage -Verdict $v).StartsWith('⚠️')
}
Test-Case 'server が無いときの ⚠ の行: server・サービス・sshd_config・鍵・拒否の規則 (鍵の権限は作るときに揃えるので出さない)' 'server サービス sshd_config 鍵 拒否の規則' {
    (Get-WarnRows $notInstalled) | ForEach-Object { ($_.Substring(2) -split '\s*:')[0] }
}

$drift = New-Facts -Change @{
    Service    = [pscustomobject]@{ Exists = $true; Status = 'Stopped'; StartType = 'Manual' }
    AllowRules = @(Select-SshdAllowRules -Rules @($msiRule))
}
Test-Case 'ずれていれば 1 で、締めは Install-Sshd で揃える (起こし直すと SSH が切れうる)' '1 True True' {
    $v = Get-SshdVerdict -Facts $drift
    Get-SshdExitCode -Verdict $v
    (Get-SshdCheckMessage -Verdict $v).Contains('dotfiles の形と揃っていない → Install-Sshd で揃える')
    (Get-SshdCheckMessage -Verdict $v).Contains('SSH が切れる')
}
Test-Case 'サービスが止まっている・MSI の 22 番の許可が有効なら、その 2 行だけ ⚠' '⚠ サービス        : Stopped / Manual → 自動で起こし、動かす|⚠ 22 番の受信の許可: 有効 (OpenSSH SSH Server Preview (sshd)) → 無効にする' {
    (Get-WarnRows $drift) -join '|'
}
Test-Case 'sshd_config が違えば ⚠ (CRLF だけの違いは数えない)' "1 0" {
    Get-SshdExitCode -Verdict (Get-SshdVerdict -Facts (New-Facts -Change @{ Config = [pscustomobject]@{ Exists = $true; Readable = $true; HasBom = $false; Text = (Get-SshdConfigText -AllowUser 'alice').Replace('PasswordAuthentication no', 'PasswordAuthentication yes') } }))
    Get-SshdExitCode -Verdict (Get-SshdVerdict -Facts (New-Facts -Change @{ Config = [pscustomobject]@{ Exists = $true; Readable = $true; HasBom = $false; Text = (Get-SshdConfigText -AllowUser 'alice').Replace("`n", "`r`n") } }))
}
Test-Case '別のユーザーの AllowUsers の sshd_config は違う' 1 {
    Get-SshdExitCode -Verdict (Get-SshdVerdict -Facts (New-Facts -Change @{ Config = [pscustomobject]@{ Exists = $true; Readable = $true; HasBom = $false; Text = (Get-SshdConfigText -AllowUser 'bob') } }))
}
Test-Case '鍵が写しと違えば、足す・消す本数を出す' '⚠ 鍵              : 写しと違う (足す 1 本・消す 1 本) → 写しどおりに書く' {
    Get-WarnRows (New-Facts -Change @{ Copy = [pscustomobject]@{ Managed = $true; Lines = @($key3); Bad = @(); Path = $copyPath; From = 'wsl' } })
}
Test-Case '鍵が写しと違えば、足す鍵と消す鍵を ※ で名札と指紋つきで出す (UAC の前に見分ける)' "※ 鍵を足す: test-phone (ssh-ed25519 $realFp・from= 無し)|※ 鍵を消す: phone (Herdr) (ssh-ed25519)" {
    $f = New-Facts -Change @{ Copy = [pscustomobject]@{ Managed = $true; Lines = @($realKey); Bad = @(); Path = $copyPath; From = 'wsl' } }
    @(Get-Notes $f | Where-Object { $_ -like '※ 鍵を*' }) -join '|'
}
Test-Case 'BOM の付いた sshd_config はずれ (sshd は読めずに起きない)' '⚠ sshd_config     : 先頭に BOM が付いている (sshd は読めずに起きない) → 退避して書き直す' {
    Get-WarnRows (New-Facts -Change @{ Config = [pscustomobject]@{ Exists = $true; Readable = $true; HasBom = $true; Text = (Get-SshdConfigText -AllowUser 'alice') } })
}
Test-Case 'BOM の付いた鍵のファイルもずれ (鍵の行が同じでも)' '⚠ 鍵              : 先頭に BOM が付いている → 写しどおりに書き直す' {
    Get-WarnRows (New-Facts -Change @{ Keys = [pscustomobject]@{ Exists = $true; Readable = $true; HasBom = $true; Text = (Get-AdminKeysText -KeyLines @($key1)) } })
}
Test-Case '22 番とほかのポートを許す規則は無効にせず、※ で添えるだけ (揃っている扱い)' '0 True' {
    $f = New-Facts -Change @{ AllowRules = @(Select-SshdAllowRules -Rules @(New-ComRule -Name 'ssh と rdp' -Change @{ LocalPorts = '22,3389' })) }
    Get-SshdExitCode -Verdict (Get-SshdVerdict -Facts $f)
    [bool](@(Get-Notes $f | Where-Object { $_.Contains('22 番とほかのポートを許す受信の規則 (ssh と rdp) は無効にしない') }).Count -eq 1)
}
Test-Case '鍵の見出しのコメントだけが違っても、鍵の行が同じなら揃っている' 0 {
    $keys = [pscustomobject]@{ Exists = $true; Readable = $true; HasBom = $false; Text = "# old header`r`n$key1`r`n" }
    Get-SshdExitCode -Verdict (Get-SshdVerdict -Facts (New-Facts -Change @{ Keys = $keys }))
}
Test-Case '鍵の権限がユーザーにも許していれば ⚠' '⚠ 鍵の権限        : 管理者と SYSTEM のほかにも許している (か継承している) → 管理者と SYSTEM だけにする' {
    Get-WarnRows (New-Facts -Change @{ Acl = [pscustomobject]@{ Readable = $true; Value = (New-Acl -Protected $false) } })
}
Test-Case '拒否の規則が無い・違えば、その名前を出す' '⚠ 拒否の規則      : 無い・違うものが 2 つ (dotfiles-sshd-tailnet-udp・dotfiles-sshd-outside-tcp22) → 作り直す' {
    $f = New-Facts
    $f.Rules['dotfiles-sshd-tailnet-udp'] = $null
    $f.Rules['dotfiles-sshd-outside-tcp22'] = New-RuleFacts -Spec $specs[2] -Change @{ Enabled = 'False' }
    Get-WarnRows $f
}
Test-Case '拒否の規則が読めなければ ⚠ で、落ちたコマンドと理由を出す (22 番の許可は別に読むので、その行は出る)' '⚠ 拒否の規則      : 読めない (Get-NetFirewallRule: アクセスが拒否されました。) True' {
    $f = New-Facts -Change @{ FirewallReadable = $false; FirewallError = 'Get-NetFirewallRule: アクセスが拒否されました。' }
    Get-WarnRows $f
    [bool](@(Format-SshdState -Verdict (Get-SshdVerdict -Facts $f) | Where-Object { $_.Text -eq '  22 番の受信の許可: 有効なものは無い' }).Count -eq 1)
}
Test-Case '22 番の許可が読めなければ、その行だけ ⚠ で読めないと出し (「無い」と読まない)、拒否の規則の行はそのまま出す' '⚠ 22 番の受信の許可: 読めない (HNetCfg.FwPolicy2: Access is denied.) 1 True' {
    $f = New-Facts -Change @{ AllowReadable = $false; AllowError = 'HNetCfg.FwPolicy2: Access is denied.' }
    Get-WarnRows $f
    Get-SshdExitCode -Verdict (Get-SshdVerdict -Facts $f)
    [bool](@(Format-SshdState -Verdict (Get-SshdVerdict -Facts $f) | Where-Object { $_.Text -eq '  拒否の規則      : 3 つとも揃っている (グループ dotfiles (sshd))' }).Count -eq 1)
}
Test-Case 'server が無くても、22 番の許可が読めないのは 3 のまま (入れる前の確かめを止めない)' 3 {
    Get-SshdExitCode -Verdict (Get-SshdVerdict -Facts (New-Facts -Change @{
                Server = $false; Service = [pscustomobject]@{ Exists = $false; Status = $null; StartType = $null }
                AllowReadable = $false; AllowError = 'HNetCfg.FwPolicy2: Access is denied.'
            }))
}

# 管理者でないと読めないファイル: 揃えたときの記録 (sha256) と比べる
$unreadable = [pscustomobject]@{ Exists = $true; Readable = $false; HasBom = $false; Text = $null }
$noAcl = [pscustomobject]@{ Readable = $false; Value = $null }
$record = [pscustomobject]@{
    ConfigSha = (Get-TextSha256 (Get-SshdConfigText -AllowUser 'alice'))
    KeysSha   = (Get-TextSha256 (Get-AdminKeysText -KeyLines @($key1)))
}
Test-Case '読めないファイルは、揃えたときの記録と同じなら揃っている (権限が読めないのは管理者だけの形とみる)' 0 {
    Get-SshdExitCode -Verdict (Get-SshdVerdict -Facts (New-Facts -Change @{ Config = $unreadable; Keys = $unreadable; Acl = $noAcl; Record = $record }))
}
Test-Case '読めない鍵は、写しが変わって記録と違えば ⚠' '⚠ 鍵              : 読めない (管理者だけが読める)。揃えたときの記録と違う (か記録が無い) → 写しどおりに書く' {
    Get-WarnRows (New-Facts -Change @{ Keys = $unreadable; Acl = $noAcl; Record = $record; Copy = [pscustomobject]@{ Managed = $true; Lines = @($key1, $key3); Bad = @(); Path = $copyPath; From = 'wsl' } })
}
Test-Case '鍵のファイルを読めない (管理者でない) ときは、足す・消すに分けず、写しの鍵を全部 ※ で名札と指紋つきで出す (UAC の前の表)' "※ 鍵: phone (Herdr) (ssh-ed25519)|※ 鍵: test-phone (ssh-ed25519 $realFp・from= 無し) 0" {
    $f = New-Facts -Change @{ Keys = $unreadable; Acl = $noAcl; Record = $record; Copy = [pscustomobject]@{ Managed = $true; Lines = @($key1, $realKey); Bad = @(); Path = $copyPath; From = 'wsl' } }
    @(Get-Notes $f | Where-Object { $_ -like '※ 鍵: *' }) -join '|'
    @(Get-Notes $f | Where-Object { $_ -like '※ 鍵を*' }).Count
}
Test-Case '記録が無ければ、読めない sshd_config は ⚠' '⚠ sshd_config     : 読めない (管理者だけが読める)。揃えたときの記録と違う (か記録が無い) → 退避して書き直す' {
    Get-WarnRows (New-Facts -Change @{ Config = $unreadable })
}

# 鍵の写しが無い (ホストの値が null): 鍵の中身は見ない
$unmanaged = [pscustomobject]@{ Managed = $false; Lines = @(); Bad = @(); Path = $copyPath; From = 'wsl' }
Test-Case '写しが無いとき、鍵を置かない ※ は受け持ちごとに足し方を出す (分からなければ両方)' 'True True True True' {
    $hint = { param($from) @(Get-Notes (New-Facts -Change @{ Copy = [pscustomobject]@{ Managed = $false; Lines = @(); Bad = @(); Path = $copyPath; From = $from } }) | Where-Object { $_.Contains('dotfiles は鍵を置かない') })[0] }
    (& $hint 'wsl').Contains('wsl.windowsFiles.sshd.authorizedKeys が null')
    (& $hint 'runner').Contains('[sshd] authorizedKeys が無い。書いて dotfiles apply を流すと runner が写しを置く')
    (& $hint '').Contains('[sshd] authorizedKeys が無い。WSL の setup')
    -not (& $hint 'runner').Contains('wsl.windowsFiles')
}
Test-Case '写しが無ければ、鍵のファイルの中身が何でも揃っている扱い (※ で、鍵を置かないと添える)' "0 True" {
    $f = New-Facts -Change @{ Copy = $unmanaged; Keys = [pscustomobject]@{ Exists = $true; Readable = $true; HasBom = $false; Text = "$key2`n$key3`n" } }
    Get-SshdExitCode -Verdict (Get-SshdVerdict -Facts $f)
    [bool](@(Get-Notes $f | Where-Object { $_.Contains('dotfiles は鍵を置かない') }).Count -eq 1)
}
Test-Case '写しが無く鍵のファイルも無ければ、空で作る ⚠' '⚠ 鍵              : ファイルが無い → 空で作る (鍵の写しが無いので、鍵は手で置く)' {
    Get-WarnRows (New-Facts -Change @{ Copy = $unmanaged; Keys = [pscustomobject]@{ Exists = $false; Readable = $false; HasBom = $false; Text = $null } })
}

# ※ の補足
Test-Case '鍵が 0 本なら ※ で、誰も入れないことと足し方を添える (揃っている扱い)' '0 True' {
    $f = New-Facts -Change @{ Copy = [pscustomobject]@{ Managed = $true; Lines = @(); Bad = @(); Path = $copyPath; From = 'wsl' }; Keys = [pscustomobject]@{ Exists = $true; Readable = $true; HasBom = $false; Text = (Get-AdminKeysText -KeyLines @()) } }
    Get-SshdExitCode -Verdict (Get-SshdVerdict -Facts $f)
    [bool](@(Get-Notes $f | Where-Object { $_.Contains('鍵が 0 本 (誰も入れない)') }).Count -eq 1)
}
Test-Case '鍵が 0 本の ※ は、runner の写しなら TOML の [sshd] authorizedKeys と dotfiles apply・Install-Sshd を案内する' 'True False' {
    $f = New-Facts -Change @{ Copy = [pscustomobject]@{ Managed = $true; Lines = @(); Bad = @(); Path = $copyPath; From = 'runner' }; Keys = [pscustomobject]@{ Exists = $true; Readable = $true; HasBom = $false; Text = (Get-AdminKeysText -KeyLines @() -From 'runner') } }
    $n = @(Get-Notes $f | Where-Object { $_.Contains('鍵が 0 本 (誰も入れない)') })[0]
    $n.Contains('[sshd] authorizedKeys) に足して dotfiles apply を流し、Install-Sshd で揃える'); $n.Contains('setup')
}
Test-Case 'from= の無い鍵があれば ※ で本数を添える' 'True' {
    $f = New-Facts -Change @{ Copy = [pscustomobject]@{ Managed = $true; Lines = @($key1, $key2); Bad = @(); Path = $copyPath; From = 'wsl' }; Keys = [pscustomobject]@{ Exists = $true; Readable = $true; HasBom = $false; Text = (Get-AdminKeysText -KeyLines @($key1, $key2)) } }
    [bool](@(Get-Notes $f | Where-Object { $_.Contains('from= の無い鍵が 1 本ある') }).Count -eq 1)
}
Test-Case 'Tailscale が無ければ ※ で添える (揃っている扱いのまま)' '0 True' {
    $f = New-Facts -Change @{ Tailscale = $false }
    Get-SshdExitCode -Verdict (Get-SshdVerdict -Facts $f)
    [bool](@(Get-Notes $f | Where-Object { $_.Contains('Tailscale が入っていない') }).Count -eq 1)
}

# 揃える前に人が直すこと: 1 で止まり、締めの行で直し方を出す (-IfMissing でも入れない)
Test-Case 'OpenSSH が無ければ 1 で、先に Install-OpenSSH -IfMissing' '1 True' {
    $v = Get-SshdVerdict -Facts (New-Facts -Change @{ OpenSsh = $false; Server = $false })
    Get-SshdExitCode -Verdict $v
    (Get-SshdCheckMessage -Verdict $v).Contains('OpenSSH が入っていない → 先に Install-OpenSSH -IfMissing で入れる')
}
Test-Case 'Windows の機能の OpenSSH Server があれば 1 で、外し方を ※ で出す' '1 True True' {
    $f = New-Facts -Change @{ Inbox = $true }
    $v = Get-SshdVerdict -Facts $f
    Get-SshdExitCode -Verdict $v
    (Get-SshdCheckMessage -Verdict $v).Contains('Windows の機能の OpenSSH Server が入っている → 先に外す')
    [bool](@(Get-Notes $f | Where-Object { $_.Contains('Remove-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0') }).Count -eq 1)
}
Test-Case 'AllowUsers に書けないユーザー名なら 1 (server が無くても 3 にしない)。別の名前を渡す道は勧めない' '1 True False' {
    $v = Get-SshdVerdict -Facts (New-Facts -Change @{ User = 'john doe'; Server = $false })
    Get-SshdExitCode -Verdict $v
    (Get-SshdCheckMessage -Verdict $v).Contains('AllowUsers に書けないユーザー名')
    (Get-SshdCheckMessage -Verdict $v).Contains('-AllowUser')
}
Test-Case '鍵の写しに読めない行があれば 1 で、ホストの値を直させる' '1 True True' {
    $f = New-Facts -Change @{ Copy = [pscustomobject]@{ Managed = $true; Lines = @($key1); Bad = @('garbage line'); Path = $copyPath; From = 'wsl' } }
    $v = Get-SshdVerdict -Facts $f
    Get-SshdExitCode -Verdict $v
    (Get-SshdCheckMessage -Verdict $v).Contains('鍵の写しに読めない行がある → ホストの値')
    [bool](@(Get-Notes $f | Where-Object { $_.Contains('鍵の写しの読めない行: garbage line') }).Count -eq 1)
}
Test-Case '鍵の写しの読めない行の締めの行は、runner の写しなら TOML と dotfiles apply、wsl なら Nix の値と setup' 'True True' {
    $msg = { param($from) Get-SshdCheckMessage -Verdict (Get-SshdVerdict -Facts (New-Facts -Change @{ Copy = [pscustomobject]@{ Managed = $true; Lines = @($key1); Bad = @('garbage line'); Path = $copyPath; From = $from } })) }
    (& $msg 'runner') -ceq '⚠️ 鍵の写しに読めない行がある → ホストの値 (dotfiles-private の win/hosts の TOML の [sshd] authorizedKeys) を直して dotfiles apply を流し直す ⚠️'
    (& $msg 'wsl') -ceq '⚠️ 鍵の写しに読めない行がある → ホストの値 (wsl.windowsFiles.sshd.authorizedKeys) を直して setup を流し直す ⚠️'
}

Test-Case '拒否の規則が効かないプロファイルがあれば 1 で止まり (server が無くても 3 にしない)、有効にするコマンドを ※ で出す' '1 True True' {
    $f = New-Facts -Change @{ Server = $false; FirewallProfiles = @(New-Profiles -Change @{ Public = @{ Enabled = 'False' } }) }
    $v = Get-SshdVerdict -Facts $f
    Get-SshdExitCode -Verdict $v
    (Get-SshdCheckMessage -Verdict $v).Contains('Windows Firewall が効いていないプロファイルがある → 先に有効にする')
    [bool](@(Get-Notes $f | Where-Object { $_.Contains('Public') -and $_.Contains('Set-NetFirewallProfile -Profile Domain,Private,Public -Enabled True') }).Count -eq 1)
}
Test-Case 'sshd.exe はあるがサービスが無ければ 1 で止まり、Server を外して入れ直すよう出す' '1 True True' {
    $f = New-Facts -Change @{ Service = [pscustomobject]@{ Exists = $false; Status = $null; StartType = $null } }
    $v = Get-SshdVerdict -Facts $f
    Get-SshdExitCode -Verdict $v
    (Get-SshdCheckMessage -Verdict $v).Contains('sshd.exe はあるがサービス sshd が無い')
    [bool](@(Get-Notes $f | Where-Object { $_.Contains('sshd を止める・外す') }).Count -eq 1)
}

# Invoke-SshdFix (管理者の段) を、Windows に触る cmdlet と関数を偽物に替えて流す (StrictMode のまま、実機で通っていない行も通す)。
# 始めの形は、管理者の段が MSI を落とす前に止まった後: 拒否の規則・sshd_config・空の鍵 (管理者と SYSTEM だけ) は揃い、sshd.exe と
# サービス sshd が無い。ファイルは一時のディレクトリに置き、ProgramData をそこへ向ける。偽物は Invoke-FixScenario の中で定義する
# (PowerShell は呼んだ側のスコープから名前を引くので、Invoke-SshdFix の中の呼び出しにも効き、外には残らない)
$fixRoot = Join-Path ([IO.Path]::GetTempPath()) "install-sshd-fix-$PID"
function Invoke-FixScenario {
    # $ServerInstalled: 始めから sshd.exe とサービス sshd (動いていて自動) がある形 (入った後に値を変えて揃え直す)。$ConfigTest: sshd -t の試し
    # (Invoke-SshdConfigTest) を偽物にして、ok (通す)・reject (断る) を返す。空なら本物 (sshd.exe が無ければ試せないと返す)
    param([int]$MsiExit = 0, [switch]$Plant, $Installed = (New-InstalledFacts), [string]$AllowJson, [switch]$ServerInstalled, [string]$ConfigTest)
    Remove-Item -LiteralPath $fixRoot -Recurse -Force -ErrorAction SilentlyContinue
    $pd = Join-Path $fixRoot 'ProgramData'
    $sshDir = Join-Path $pd 'ssh'
    $install = Join-Path $fixRoot 'OpenSSH'
    $state = Join-Path $fixRoot 'state'
    $null = New-Item -ItemType Directory -Force -Path $sshDir, $install, $state
    [IO.File]::WriteAllText((Join-Path $install 'ssh.exe'), '')
    if ($ServerInstalled) { [IO.File]::WriteAllText((Join-Path $install 'sshd.exe'), '') }
    # ユーザーと送り元の写し (渡したときだけ置く)
    if ($AllowJson) { [IO.File]::WriteAllText((Join-Path $state 'allow.json'), $AllowJson, [Text.UTF8Encoding]::new($false)) }
    Write-TextNoBom -Path (Join-Path $sshDir 'sshd_config') -Text (Get-SshdConfigText -AllowUser 'alice')
    Write-TextNoBom -Path (Join-Path $sshDir 'administrators_authorized_keys') -Text (Get-AdminKeysText -KeyLines @() -Managed $false)
    $world = @{
        Steps    = [System.Collections.Generic.List[string]]::new()
        Calls    = [System.Collections.Generic.List[string]]::new()
        Acls     = @{}
        Services = @{ 'ssh-agent' = [pscustomobject]@{ Status = 'Running'; StartType = 'Automatic' } }
        FwRules  = [System.Collections.Generic.List[object]]::new()
        Result   = $null
    }
    if ($ServerInstalled) { $world.Services['sshd'] = [pscustomobject]@{ Status = 'Running'; StartType = 'Automatic' } }

    if ($ConfigTest) {
        function Invoke-SshdConfigTest {
            param([string]$SshdExe, [string]$Text, [string]$Directory)
            $world.Calls.Add("sshd -t で試した: $(Split-Path -Leaf $SshdExe) $(Split-Path -Leaf $Directory)")
            if ($ConfigTest -eq 'reject') {
                return [pscustomobject]@{ Tested = $true; Ok = $false; Lines = @('sshd_config line 21: no argument after keyword "bob"'); Why = $null }
            }
            [pscustomobject]@{ Tested = $true; Ok = $true; Lines = @(); Why = $null }
        }
    }
    function Write-Step { param([string]$Message) $world.Steps.Add($Message) }
    function Test-InSshSession { $false }
    function Get-NetFirewallProfile {
        [CmdletBinding()] param($PolicyStore)
        foreach ($n in @('Domain', 'Private', 'Public')) { [pscustomobject]@{ Name = $n; Enabled = 'True'; AllowLocalFirewallRules = 'True' } }
    }
    function Read-FirewallRuleFacts {
        param([string]$Name)
        New-RuleFacts -Spec (@(Get-SshdFirewallSpecs) | Where-Object { $_.Name -eq $Name })
    }
    function Get-Acl {
        [CmdletBinding()] param([string]$LiteralPath)
        $o = [pscustomobject]@{ Sddl = $null }
        $o | Add-Member -MemberType ScriptMethod -Name SetSecurityDescriptorSddlForm -Value { param($s) $this.Sddl = $s }
        $o
    }
    function Set-Acl {
        [CmdletBinding()] param([string]$LiteralPath, $AclObject)
        $world.Acls[$LiteralPath] = $AclObject.Sddl
        # 作ってから権限を替えるまでの間に、利用者の権限で何かが置かれた形
        if ($Plant) { [IO.File]::WriteAllText((Join-Path $LiteralPath 'planted.msi'), '') }
    }
    function Read-AclFacts {
        param([string]$Path)
        if ($world.Acls.ContainsKey($Path)) { return [pscustomobject]@{ Readable = $true; Value = (ConvertFrom-TestSddl -Sddl $world.Acls[$Path]) } }
        [pscustomobject]@{ Readable = $true; Value = (New-Acl) }
    }
    function Get-Item {
        [CmdletBinding()] param([string]$LiteralPath)
        if ($LiteralPath -eq (Join-Path $install 'ssh.exe')) { return [pscustomobject]@{ VersionInfo = [pscustomobject]@{ FileVersion = '10.4.0.0' } } }
        Microsoft.PowerShell.Management\Get-Item -LiteralPath $LiteralPath -ErrorAction Stop
    }
    function Get-Command {
        [CmdletBinding()] param([string]$Name)
        if ($Name -eq 'winget') { return [pscustomobject]@{ Name = 'winget' } }
        Microsoft.PowerShell.Core\Get-Command -Name $Name
    }
    function Invoke-Winget {
        param([string[]]$Arguments)
        $dir = $Arguments[$Arguments.IndexOf('--download-directory') + 1]
        $world.Calls.Add("winget の時の落とす先の権限: $($world.Acls[$dir])")
        # winget download は、入れたときの名前 (PackageName) とは違う名前で保存する
        [IO.File]::WriteAllText((Join-Path $dir 'OpenSSH Preview_10.4.0.0_Machine_X64_msi_en-US.msi'), 'msi')
        [pscustomobject]@{ ExitCode = 0; Lines = @('Installer downloaded') }
    }
    function Read-MsiPackageFacts {
        param([string]$Path)
        $world.Calls.Add("MSI を読んだ: $(Split-Path -Leaf $Path)")
        [pscustomobject]@{ ProductCode = $pc; PackageCode = $pkg }
    }
    function Read-InstalledMsiProduct {
        param([string]$ProductCode)
        $world.Calls.Add("登録を読んだ: $ProductCode")
        $Installed
    }
    function Start-Process {
        param([string]$FilePath, [string[]]$ArgumentList, [switch]$Wait, [switch]$PassThru)
        $world.Calls.Add("$FilePath の時に MSI がある: $(Split-Path -Leaf $ArgumentList[1].Trim('"')) $(Test-Path -LiteralPath $ArgumentList[1].Trim('"'))")
        if ($MsiExit -eq 0) {
            # MSI が Server を足すと、sshd.exe とサービス (手動・止まっている) と 22 番の許可ができ、ssh-agent は動いたまま
            [IO.File]::WriteAllText((Join-Path $install 'sshd.exe'), '')
            $world.Services['sshd'] = [pscustomobject]@{ Status = 'Stopped'; StartType = 'Manual' }
            $world.FwRules.Add((New-ComRule -Name 'OpenSSH SSH Server Preview (sshd)' -Change @{ ApplicationName = (Join-Path $install 'sshd.exe') }))
        }
        [pscustomobject]@{ ExitCode = $MsiExit }
    }
    function Get-SshdAllowRules { @(Select-SshdAllowRules -Rules @($world.FwRules)) }
    function Get-Service {
        [CmdletBinding()] param([string]$Name)
        $s = $world.Services[$Name]
        if (-not $s) { return }
        $o = [pscustomobject]@{ Name = $Name; Status = $s.Status; StartType = $s.StartType }
        $o | Add-Member -MemberType ScriptMethod -Name WaitForStatus -Value { param($want, $timeout) if ("$($this.Status)" -ne "$want") { throw "$($this.Name) が $want にならない" } }
        $o
    }
    function Set-Service { param([string]$Name, [string]$StartupType) $world.Services[$Name].StartType = $StartupType }
    function Stop-Service { param([string]$Name, [switch]$Force) $world.Services[$Name].Status = 'Stopped' }
    function Start-Service { param([string]$Name) $world.Services[$Name].Status = 'Running' }
    function Restart-Service { param([string]$Name, [switch]$Force) $world.Calls.Add("Restart-Service $Name") }

    $saved = $env:ProgramData
    $env:ProgramData = $pd
    try {
        $world.Result = Invoke-SshdFix -InstallDir $install -User 'alice' -CopyPath (Join-Path $state 'authorized_keys') -StateDir $state -AllowPath (Join-Path $state 'allow.json')
    } catch {
        $world.Result = "ERROR: $($_.Exception.Message)"
    } finally {
        $env:ProgramData = $saved
    }
    # 一時のディレクトリと、毎回変わる名前を伏せる (Windows で流しても同じ文になるよう、区切りも / にそろえる)
    $mask = { param($s) ("$s".Replace($fixRoot, '<tmp>') -replace 'dotfiles-sshd-msi-[0-9a-f]{32}', 'dotfiles-sshd-msi-<guid>').Replace('\', '/') }
    [pscustomobject]@{
        Result   = $world.Result
        Steps    = @($world.Steps | ForEach-Object { & $mask $_ })
        Calls    = @($world.Calls | ForEach-Object { & $mask $_ })
        Left     = @(Get-ChildItem -LiteralPath $pd -Filter 'dotfiles-sshd-msi-*' | ForEach-Object { & $mask $_.Name })
        Services = $world.Services
        FwRules  = @($world.FwRules)
        Record   = Read-SshdRecord -Dir $state
        Keys     = Read-TextFile -Path (Join-Path $sshDir 'administrators_authorized_keys')
        Config   = Read-TextFile -Path (Join-Path $sshDir 'sshd_config')
    }
}
try {
    $run = Invoke-FixScenario
    $msiDir = '<tmp>/ProgramData/dotfiles-sshd-msi-<guid>'
    Test-Case '途中で止まった形から: 規則・設定・鍵には触らず、MSI で Server を足し、22 番の許可を無効にし、ssh-agent を戻し、sshd を自動で起こす' @(
        'True'
        "winget download --id Microsoft.OpenSSH.Preview --exact --source winget --version 10.4.0.0 --download-directory $msiDir --accept-source-agreements --accept-package-agreements --disable-interactivity"
        '  Installer downloaded'
        'MSI を、入っている製品の登録された名前 (OpenSSH-Win64-v10.4.0.0.msi) に写した (保守の install は、この名前で原本を探す)'
        "msiexec /i `"$msiDir/OpenSSH-Win64-v10.4.0.0.msi`" ADDLOCAL=Client,Server /qn /norestart /l*v `"<tmp>/state/msiexec-add-server.log`""
        'MSI に Server の機能を足した (10.4.0.0)'
        '22 番の受信の許可を無効にした: OpenSSH SSH Server Preview (sshd)'
        'ssh-agent を止めた (MSI が起こした)'
        'ssh-agent を無効にした (MSI が戻した)'
        'sshd を自動で起こすようにした'
        'sshd を起こした'
    ) { $run.Result; $run.Steps }
    Test-Case 'MSI は毎回新しい名前の、管理者と SYSTEM だけのディレクトリに落とし、登録された名前に写して msiexec に渡し、後で消す (起こし直しはしない)' @(
        "winget の時の落とす先の権限: $script:AdminDirSddl"
        'MSI を読んだ: OpenSSH Preview_10.4.0.0_Machine_X64_msi_en-US.msi'
        "登録を読んだ: $pc"
        'msiexec.exe の時に MSI がある: OpenSSH-Win64-v10.4.0.0.msi True'
    ) { $run.Calls; $run.Left }
    Test-Case '揃えた後: sshd は動いて自動、ssh-agent は止まって無効、22 番の許可は無効、記録は sshd_config だけ、空の鍵はそのまま' @(
        'Running Automatic Stopped Disabled False True True'
    ) {
        $s = $run.Services
        "$($s['sshd'].Status) $($s['sshd'].StartType) $($s['ssh-agent'].Status) $($s['ssh-agent'].StartType) $($run.FwRules[0].Enabled) $($run.Record.ConfigSha -eq (Get-TextSha256 (Get-SshdConfigText -AllowUser 'alice'))) $($run.Keys.Text -ceq (Get-AdminKeysText -KeyLines @() -Managed $false))"
    }
    Test-Case '揃えた後の -Check の判定は 0 (揃っている)' '0' {
        $f = New-Facts -Change @{
            Copy       = $unmanaged
            Keys       = $run.Keys
            Service    = [pscustomobject]@{ Exists = $true; Status = $run.Services['sshd'].Status; StartType = $run.Services['sshd'].StartType }
            AllowRules = @(Select-SshdAllowRules -Rules $run.FwRules)
            Record     = [pscustomobject]@{ ConfigSha = $run.Record.ConfigSha; KeysSha = $run.Record.KeysSha }
        }
        Get-SshdExitCode -Verdict (Get-SshdVerdict -Facts $f)
    }

    $failed = Invoke-FixScenario -MsiExit 1603
    Test-Case 'msiexec が落ちたら $false で止まり (サービスに触らない)、落とした MSI のディレクトリは消す' @(
        'False'
        'msiexec が失敗した (終了コード 1603。ログ: <tmp>/state/msiexec-add-server.log)'
        '|'
    ) { $failed.Result; @($failed.Steps | Select-Object -Last 1); '|'; $failed.Left }

    $noName = Invoke-FixScenario -Installed (New-InstalledFacts -PackageName $null)
    Test-Case '登録された PackageName が読めなければ、msiexec を流さずに $false で止まり (サービスに触らない)、ディレクトリは消す' @(
        'False'
        "入っている製品 ($pc) の、登録された MSI の名前 (SourceList の PackageName) が読めない ()。msiexec を流さない"
        '|'
    ) { $noName.Result; @($noName.Steps | Select-Object -Last 1); '|'; $noName.Left; @($noName.Calls | Where-Object { $_.StartsWith('msiexec') }) }
    $otherProduct = Invoke-FixScenario -Installed (New-InstalledFacts -Exists $false)
    Test-Case '落とした MSI の製品が入っていなければ、msiexec を流さずに $false で止まる' @(
        'False'
        "落とした MSI の製品 ($pc) がこの PC に入っていない (入っている OpenSSH と製品が違う)。msiexec を流さない"
    ) { $otherProduct.Result; @($otherProduct.Steps | Select-Object -Last 1); @($otherProduct.Calls | Where-Object { $_.StartsWith('msiexec') }) }

    # ユーザーと送り元の写しがあれば、その値で sshd_config を書き直し、書いた値をログに出す (記録も写しの値で作った中身)
    $withAllow = Invoke-FixScenario -AllowJson '{"version":1,"allowUsers":["alice","bob"],"allowFrom":["100.64.0.1","fd7a:115c:a1e0:ab12::/64"]}'
    Test-Case '写しの値で sshd_config を書き直し (前の中身は退避)、書いたユーザーと送り元をログに出す。記録も写しの値の中身' @(
        'True'
        'sshd_config を dotfiles の中身にした'
        '  AllowUsers: alice・bob'
        '  送り元: 100.64.0.1・fd7a:115c:a1e0:ab12::/64'
        'True True'
    ) {
        $withAllow.Result
        @($withAllow.Steps | Where-Object { $_ -eq 'sshd_config を dotfiles の中身にした' -or $_.StartsWith('  AllowUsers:') -or $_.StartsWith('  送り元:') })
        "$($withAllow.Config.Text -ceq $configMulti) $($withAllow.Record.ConfigSha -eq (Get-TextSha256 $configMulti))"
    }
    $badAllow = Invoke-FixScenario -AllowJson '{"version":1,"allowFrom":["100.64.0.1/10"]}'
    Test-Case '写しに読めない値があれば、何も変えずに $false で止まる (sshd_config は前のまま)' @(
        'False'
        'ユーザーと送り元の写し (<tmp>/state/allow.json) に読めない値がある。何もしない'
        'True 0'
    ) {
        $badAllow.Result
        $badAllow.Steps
        "$($badAllow.Config.Text -ceq $beforeHostValues) $(@($badAllow.Calls).Count)"
    }
    # 写しの JSON に末尾の改行 (\n) を入れた値も同じ (通すと sshd_config の行が割れ、sshd が起動しなくなる)
    $newlineUser = Invoke-FixScenario -AllowJson '{"version":1,"allowUsers":["alice\n","bob"]}'
    $newlineFrom = Invoke-FixScenario -AllowJson '{"version":1,"allowFrom":["100.64.0.0/10\n","127.0.0.1"]}'
    Test-Case '写しのユーザー・送り元に末尾の改行があれば、sshd_config を書かずに $false で止まる' 'False True 0|False True 0' {
        @($newlineUser, $newlineFrom | ForEach-Object { "$($_.Result) $($_.Config.Text -ceq $beforeHostValues) $(@($_.Calls).Count)" }) -join '|'
    }

    # 書き換える前の sshd -t の試し (Invoke-SshdConfigTest)。sshd.exe が入った後に値を変えて揃え直す形で、試しを偽物にする
    $rejected = Invoke-FixScenario -ServerInstalled -ConfigTest reject -AllowJson '{"version":1,"allowUsers":["alice","bob"]}'
    Test-Case 'sshd -t が断ったら、sshd_config を書き換えず・起こし直さずに $false で止まり、sshd -t の出力を出す (記録も書かない)' @(
        'False'
        'sshd_config の中身を sshd -t が断った。sshd_config を書き換えずに止める (今の sshd_config と sshd はそのまま)'
        '  sshd -t: sshd_config line 21: no argument after keyword "bob"'
        '|'
        'sshd -t で試した: sshd.exe ssh'
        '|'
        'True True Running'
    ) {
        $rejected.Result; $rejected.Steps; '|'; $rejected.Calls; '|'
        "$($rejected.Config.Text -ceq $beforeHostValues) $($null -eq $rejected.Record.ConfigSha) $($rejected.Services['sshd'].Status)"
    }
    $accepted = Invoke-FixScenario -ServerInstalled -ConfigTest ok -AllowJson '{"version":1,"allowUsers":["alice","bob"],"allowFrom":["100.64.0.1","fd7a:115c:a1e0:ab12::/64"]}'
    Test-Case 'sshd -t が通したら、書き換えて起こし直す (試すのは管理者だけが書ける ProgramData の ssh の下)' 'True|sshd_config の中身を sshd -t で試した (通った)|sshd_config を dotfiles の中身にした|sshd -t で試した: sshd.exe ssh|Restart-Service sshd|True' {
        @(
            "$($accepted.Result)"
            @($accepted.Steps | Where-Object { $_ -like 'sshd_config の中身を*' -or $_ -eq 'sshd_config を dotfiles の中身にした' })
            @($accepted.Calls)
            "$($accepted.Config.Text -ceq $configMulti)"
        ) -join '|'
    }
    Test-Case 'sshd.exe がまだ無い (server を足す前) ときは試せないと出し、止めずに書く' 'True|sshd_config の中身を sshd -t で試せなかった (<tmp>/OpenSSH/sshd.exe が無い (server を足す前))。試さずに書く|sshd_config を dotfiles の中身にした' {
        (@("$($withAllow.Result)") + @($withAllow.Steps | Where-Object { $_ -like 'sshd_config の中身を*' -or $_ -eq 'sshd_config を dotfiles の中身にした' })) -join '|'
    }

    $planted = Invoke-FixScenario -Plant
    Test-Case '権限を替えるまでの間にディレクトリへ何か置かれたら、MSI を落とさずに $false で止まり、消さずに残す (ジャンクションをたどらない)' @(
        'False'
        "$msiDir を、管理者と SYSTEM だけが読み書きできる空のディレクトリにできなかった (中に 1 個)。MSI を落とさない。中を確かめてから手で消す"
        '|'
        'dotfiles-sshd-msi-<guid>'
    ) { $planted.Result; @($planted.Steps); '|'; $planted.Left; $planted.Calls }

    Test-Case 'New-AdminOnlyDir は在るディレクトリには作らない (New-Item で止まり、前もって置かれたものを使わず、中も消さない)' 'New-Item True' {
        $d = Join-Path $fixRoot 'existing'
        $null = New-Item -ItemType Directory -Force -Path $d
        [IO.File]::WriteAllText((Join-Path $d 'keep.msi'), '')
        try {
            $null = New-AdminOnlyDir -Path $d
            'New-AdminOnlyDir が止まらなかった'
        } catch {
            "$($_.InvocationInfo.MyCommand.Name)"
        }
        Test-Path -LiteralPath (Join-Path $d 'keep.msi')
    }
} finally {
    Remove-Item -LiteralPath $fixRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# Invoke-Elevated: 管理者で起動し直す子に、鍵の写しとユーザーと送り元の写しの場所・流したユーザー・受け持ちを渡す (別の管理者のアカウントで
# 昇格すると、子の LOCALAPPDATA と USERNAME は親と違う)。Start-Process を偽物に替え、渡す引数を控える
function Invoke-ElevatedScenario {
    $captured = @{ Args = @() }
    function Start-Process {
        param([string]$FilePath, [string[]]$ArgumentList, [string]$Verb, [switch]$Wait, [switch]$PassThru)
        $captured.Args = @($ArgumentList)
        [pscustomobject]@{ ExitCode = 0 }
    }
    function Write-Host { param($Object, $ForegroundColor) }
    $state = Join-Path ([IO.Path]::GetTempPath()) "install-sshd-elevated-$PID"
    try {
        $result = Invoke-Elevated -User 'alice' -CopyPath 'C:\k\authorized_keys' -StateDir $state -KeysFrom 'runner' -AllowPath 'C:\k\allow.json'
    } finally {
        Remove-Item -LiteralPath $state -Recurse -Force -ErrorAction SilentlyContinue
    }
    [pscustomobject]@{ Result = $result; Args = $captured.Args }
}
$elevated = Invoke-ElevatedScenario
Test-Case '管理者の子に、鍵の写し・ユーザーと送り元の写しの場所 ("" で囲む)・流したユーザー・受け持ちを渡す' 'True "C:\k\authorized_keys" "C:\k\allow.json" alice runner' {
    $a = @($elevated.Args)
    $elevated.Result
    $a[$a.IndexOf('-KeysCopy') + 1]; $a[$a.IndexOf('-AllowCopy') + 1]; $a[$a.IndexOf('-AllowUser') + 1]; $a[$a.IndexOf('-KeysFrom') + 1]
}

# 本体の入口: 思わぬ例外でも、終了コード 2 で止まる (成功に見せない)。
# Linux の pwsh には $env:ProgramFiles が無く、本体の最初で例外になるのを使う (Install-OpenSSH.Tests.ps1 と同じ)
Test-Case '思わぬ例外では終了コード 2 で止まる' '2' {
    $pwsh = (Get-Process -Id $PID).Path
    $null = & $pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Install-Sshd.ps1') -Check 2>&1
    $LASTEXITCODE
}

if ($script:Failures -gt 0) {
    Write-Host "$($script:Failures) 件失敗"
    exit 1
}
Write-Host 'すべて通った'
