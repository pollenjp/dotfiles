# win/port-forward/Start-PortForward.ps1 (pf) のうち、副作用の無い関数のテスト。Pester は使わない。
# キーを読む・画面に描く・ssh を動かす外側は、tmux の中の pwsh で動かして確かめる (win/README.md の「port forwarding (pf)」)。
#
# WSL から流す (Linux の pwsh で動かすので、Windows 側には触らない):
#   nix shell nixpkgs#powershell -c pwsh -NoProfile -File win/port-forward/Start-PortForward.Tests.ps1
#
# BOM 付きの UTF-8 で保存すること (win/README.md の「dotfiles.ps1 を書くときの注意」)。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# dot-source すると関数だけを読み、本体は走らない (Start-PortForward.ps1 の末尾)
. (Join-Path $PSScriptRoot 'Start-PortForward.ps1')

$script:Failures = 0

# Actual の scriptblock を走らせ、文字列にして Expected と比べる。
# 関数が無いなどで例外になったら、その文面を結果として比べる (誤りを確かめるケースは 'ERROR: …' を期待する)。
function Test-Case {
    param([string]$Name, $Expected, [scriptblock]$Actual)
    try {
        $got = & $Actual
    } catch {
        $got = "ERROR: $($_.Exception.Message)"
    }
    $e = @($Expected | ForEach-Object { "$_" }) -join ' '
    $a = @($got | ForEach-Object { "$_" }) -join ' '
    if ($e -ceq $a) {
        Write-Host "ok   $Name"
    } else {
        Write-Host "FAIL $Name"
        Write-Host "     expected: [$e]"
        Write-Host "     actual:   [$a]"
        $script:Failures++
    }
}

# 行を 1 つの文字列にする (手元 → つなぎ先:向こう | メモ)
function Show-Row {
    param($Row)
    "$($Row.LocalPort)>$($Row.RemoteHost):$($Row.RemotePort)|$($Row.Memo)"
}

# ---------------------------------------------------------------------------
# 書き方の解釈と ssh の引数
# ---------------------------------------------------------------------------

Test-Case '3000 は手元と向こうが同じ localhost' '3000>localhost:3000|' { Show-Row (ConvertFrom-PortSpec '3000') }
Test-Case '13000:3000 は向こうの localhost:3000' '13000>localhost:3000|' { Show-Row (ConvertFrom-PortSpec '13000:3000') }
Test-Case '13000:db:5432 はつなぎ先とメモ' '13000>db:5432|postgres' { Show-Row (ConvertFrom-PortSpec '13000:db:5432 postgres') }
Test-Case 'IPv6 のつなぎ先は [ ] で囲む' '13000>[::1]:5432|' { Show-Row (ConvertFrom-PortSpec '13000:[::1]:5432') }
Test-Case 'メモの前後の空白を落とし、中の空白は残す' '3000>localhost:3000|ポスグレ の 管理' { Show-Row (ConvertFrom-PortSpec '  3000   ポスグレ の 管理  ') }
Test-Case 'タブでもメモを区切る' '3000>localhost:3000|front' { Show-Row (ConvertFrom-PortSpec "3000`tfront") }
Test-Case '空は誤り' 'ERROR: 空です' { ConvertFrom-PortSpec '  ' }
# 全角の数字 (IME を入れたまま打ったもの) も書き方の誤りにする (.NET の \d は Unicode の数字に合う)
foreach ($bad in 'abc', '3000:', ':3000', '1:2:3:4', '127.0.0.1:3000:localhost:3000', '999999', '3000:db', '３０００', '3000:db:５４３２') {
    Test-Case "書き方の誤り: $bad" $true { (& { try { ConvertFrom-PortSpec $bad; 'no error' } catch { $_.Exception.Message } }).StartsWith('書き方が違います') }
}
foreach ($bad in '0', '65536', '3000:0', '1:db:70000') {
    Test-Case "port の範囲の誤り: $bad" $true { (& { try { ConvertFrom-PortSpec $bad; 'no error' } catch { $_.Exception.Message } }).StartsWith('port は 1〜65535') }
}

Test-Case '短い形に戻す: 3000' '3000' { ConvertTo-PortSpec (ConvertFrom-PortSpec '3000') }
Test-Case '短い形に戻す: 13000:3000' '13000:3000' { ConvertTo-PortSpec (ConvertFrom-PortSpec '13000:3000') }
Test-Case '短い形に戻す: メモ付き' '13000:db:5432 postgres' { ConvertTo-PortSpec (ConvertFrom-PortSpec '13000:db:5432   postgres ') }
Test-Case '短い形に戻す: IPv6' '13000:[::1]:5432' { ConvertTo-PortSpec (ConvertFrom-PortSpec '13000:[::1]:5432') }
Test-Case '3000:localhost:3000 は 3000 に縮む' '3000 front' { ConvertTo-PortSpec (ConvertFrom-PortSpec '3000:localhost:3000 front') }

Test-Case 'ssh -L の値' '13000:db:5432' { Get-ForwardArgument (ConvertFrom-PortSpec '13000:db:5432 postgres') }
$twoRows = @((ConvertFrom-PortSpec '3000'), (ConvertFrom-PortSpec '13000:db:5432 postgres'))
Test-Case 'ssh の引数' '-NT -o ExitOnForwardFailure=yes -L 3000:localhost:3000 -L 13000:db:5432 example-a' {
    Get-SshArgumentList -HostName 'example-a' -Rows $twoRows
}
Test-Case '1 行でも引数は配列' 6 { @(Get-SshArgumentList -HostName 'example-a' -Rows @((ConvertFrom-PortSpec '3000'))).Count }
Test-Case '打つコマンドの 1 行' 'ssh -NT -o ExitOnForwardFailure=yes -L 3000:localhost:3000 example-a' {
    Format-CommandLine -Ssh 'ssh' -Arguments (Get-SshArgumentList -HostName 'example-a' -Rows @((ConvertFrom-PortSpec '3000')))
}
Test-Case '空白を含む引数は囲む' "'C:\Program Files\OpenSSH\ssh.exe' -NT" { Format-CommandLine -Ssh 'C:\Program Files\OpenSSH\ssh.exe' -Arguments @('-NT') }

# ---------------------------------------------------------------------------
# ssh の設定の読み取り
# ---------------------------------------------------------------------------

# テストごとの家 (.ssh を持つ一時ディレクトリ)。最後にまとめて消す
$script:TempDirs = [System.Collections.Generic.List[string]]::new()
function New-TestHome {
    $d = Join-Path ([System.IO.Path]::GetTempPath()) ('pf-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $d '.ssh') -Force | Out-Null
    $script:TempDirs.Add($d)
    $d
}
# ファイルを書く (親のディレクトリも作る)。$Bom を付けると BOM 付きの UTF-8
function Write-TestFile {
    param([string]$Path, [string]$Text, [switch]$Bom)
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new([bool]$Bom))
}

$h = New-TestHome
Write-TestFile (Join-Path $h '.ssh/config') "Host a b`nHost=c`n  host  d # コメント`nHOST `"e`"`n  HostName e.example.test`n"
Test-Case 'Host の行の語を順に (= の形・小文字・コメント・"…")' 'a b c d e' { Get-SshConfigHost -HomeDir $h }

$h = New-TestHome
Write-TestFile (Join-Path $h '.ssh/config') "Host * !x y-* z q?`nHost -bad ok`n"
Test-Case 'ワイルドカードと - で始まる語は出さない' 'z ok' { Get-SshConfigHost -HomeDir $h }

$h = New-TestHome
Write-TestFile (Join-Path $h '.ssh/config') "Include config.d/*.ssh_config`nHost last`n"
Write-TestFile (Join-Path $h '.ssh/config.d/20-a.ssh_config') "Host a2`n"
Write-TestFile (Join-Path $h '.ssh/config.d/10-b.ssh_config') "Host b1`n"
Write-TestFile (Join-Path $h '.ssh/config.d/other.txt') "Host not-included`n"
Test-Case 'Include の相対パスは .ssh から、ワイルドカードは名前の順' 'b1 a2 last' { Get-SshConfigHost -HomeDir $h }

$h = New-TestHome
Write-TestFile (Join-Path $h '.ssh/config') "Include ~/.ssh/extra one`nInclude missing.ssh_config nothing/*.ssh_config`nMatch host foo`n  Include matched`n"
Write-TestFile (Join-Path $h '.ssh/extra') "Host from-extra`n"
Write-TestFile (Join-Path $h '.ssh/one') "Host from-one`n"
Write-TestFile (Join-Path $h '.ssh/matched') "Host from-match`n"
Test-Case '~ の Include・1 行に 2 つ・無いファイル・Match の中の Include' 'from-extra from-one from-match' { Get-SshConfigHost -HomeDir $h }

$h = New-TestHome
Write-TestFile (Join-Path $h '.ssh/config') "Host loop-a`nInclude config`nInclude config.d/*`n"
Write-TestFile (Join-Path $h '.ssh/config.d/x') "Host loop-b`nInclude ~/.ssh/config.d/x`nInclude ../config`n"
Test-Case 'Include の輪でも止まり、Host は 1 回だけ' 'loop-a loop-b' { Get-SshConfigHost -HomeDir $h }

$h = New-TestHome
Write-TestFile (Join-Path $h '.ssh/config') "Host crlf-1`r`n  HostName x`r`nHost crlf-2`r`n" -Bom
Test-Case 'CRLF・BOM のファイル' 'crlf-1 crlf-2' { Get-SshConfigHost -HomeDir $h }

$h = New-TestHome
Test-Case 'config が無ければ空' 0 { @(Get-SshConfigHost -HomeDir $h).Count }

$h = New-TestHome
Write-TestFile (Join-Path $h '.ssh/config') "Host Example-A`nHost example-a example-b`n"
Test-Case '大文字小文字だけ違う名前は最初のものだけ' 'Example-A example-b' { Get-SshConfigHost -HomeDir $h }

# ---------------------------------------------------------------------------
# 共有と手元の重ね方・手元の組の変更・Host の並び
# ---------------------------------------------------------------------------

# 行の並びを 1 つの文字列にする (書き方(Source), …)
function Show-Rows {
    param($Rows)
    @($Rows | ForEach-Object { "$(ConvertTo-PortSpec $_)($($_.Source))" }) -join ', '
}

$shared = @('3000', '3100', '8080 api')
$entry = [ordered]@{ ports = @('3000 front', '15432:db:5432 pg'); hidden = @(3100); last = @() }
Test-Case '重ね方: 上書き・隠す・手元だけの組' '3000 front(override), 8080 api(shared), 15432:db:5432 pg(local)' { Show-Rows (Merge-PortRow -Shared $shared -Entry $entry) }
Test-Case '重ね方: 手元が共有と同じ中身なら shared' '3000(shared), 3100(shared)' {
    Show-Rows (Merge-PortRow -Shared @('3000', '3100') -Entry ([ordered]@{ ports = @('3000:localhost:3000'); hidden = @(); last = @() }))
}
Test-Case '共有の組の読めない文字列は飛ばし、同じ port は先の行を使う' '3000 a(shared), 8080(shared)' { Show-Rows (Merge-PortRow -Shared @('3000 a', 'oops', '3000 b', '8080') -Entry $null) }
Test-Case '重ね方: 手元の組が無ければ共有のまま' '3000(shared)' { Show-Rows (Merge-PortRow -Shared @('3000') -Entry $null) }
Test-Case '重ね方: どちらも無ければ 0 行' 0 { @(Merge-PortRow -Shared @() -Entry $null).Count }
Test-Case '隠した共有の port' '3100' { Get-HiddenPort -Shared $shared -Entry $entry }
Test-Case '共有に無い port を隠していても出さない' 0 { @(Get-HiddenPort -Shared @('3000') -Entry ([ordered]@{ ports = @(); hidden = @(9999); last = @() })).Count }

# Set-PortSpec・Remove-PortSpec・Register-Connection は store を書き換える
function New-TestStore {
    ConvertTo-LocalStore ([ordered]@{
            version = 1
            recent  = @()
            hosts   = [ordered]@{ 'example-a' = [ordered]@{ ports = @('3000 front', '15432:db:5432 pg'); hidden = @(3100); last = @(3000) } }
        })
}
function Show-Entry {
    param($Store, [string]$Name = 'example-a')
    $e = $Store.hosts[$Name]
    "ports=$($e.ports -join ',') hidden=$($e.hidden -join ',') last=$($e.last -join ',')"
}

Test-Case '足す: 共有に無い port は ports の後ろ' 'ports=3000 front,15432:db:5432 pg,9000 new hidden=3100 last=3000' {
    $s = New-TestStore
    Set-PortSpec -Store $s -HostName 'example-a' -Shared $shared -OldPort $null -Row (ConvertFrom-PortSpec '9000 new')
    Show-Entry $s
}
Test-Case '直す: 同じ port の古いものは同じ位置で置き換える' 'ports=3000 front2,15432:db:5432 pg hidden=3100 last=3000' {
    $s = New-TestStore
    Set-PortSpec -Store $s -HostName 'example-a' -Shared $shared -OldPort 3000 -Row (ConvertFrom-PortSpec '3000 front2')
    Show-Entry $s
}
Test-Case '直す: 共有と同じ中身にすると ports から外れる' 'ports=15432:db:5432 pg hidden=3100 last=3000' {
    $s = New-TestStore
    Set-PortSpec -Store $s -HostName 'example-a' -Shared $shared -OldPort 3000 -Row (ConvertFrom-PortSpec '3000')
    Show-Entry $s
}
Test-Case '足す: 隠した共有の port を同じ中身で足すと戻る' 'ports=3000 front,15432:db:5432 pg hidden= last=3000' {
    $s = New-TestStore
    Set-PortSpec -Store $s -HostName 'example-a' -Shared $shared -OldPort $null -Row (ConvertFrom-PortSpec '3100')
    Show-Entry $s
}
Test-Case '直す: port を変えると、元の共有の port は隠れる' 'ports=15432:db:5432 pg,13000:3000 front hidden=3100,3000 last=3000' {
    $s = New-TestStore
    Set-PortSpec -Store $s -HostName 'example-a' -Shared $shared -OldPort 3000 -Row (ConvertFrom-PortSpec '13000:3000 front')
    Show-Entry $s
}
Test-Case '消す: 共有の port は隠し、上書きは外す' 'ports=15432:db:5432 pg hidden=3100,3000 last=3000' {
    $s = New-TestStore
    Remove-PortSpec -Store $s -HostName 'example-a' -Shared $shared -Port 3000
    Show-Entry $s
}
Test-Case '消す: 手元だけの port は ports から外す' 'ports=3000 front hidden=3100 last=3000' {
    $s = New-TestStore
    Remove-PortSpec -Store $s -HostName 'example-a' -Shared $shared -Port 15432
    Show-Entry $s
}
Test-Case '消す: 隠すのは 1 回だけ' 'ports=3000 front,15432:db:5432 pg hidden=3100 last=3000' {
    $s = New-TestStore
    Remove-PortSpec -Store $s -HostName 'example-a' -Shared $shared -Port 3100
    Show-Entry $s
}
Test-Case '足す: 初めての Host は entry を作る' 'ports=9000 hidden= last=' {
    $s = New-TestStore
    Set-PortSpec -Store $s -HostName 'example-b' -Shared @() -OldPort $null -Row (ConvertFrom-PortSpec '9000')
    Show-Entry $s 'example-b'
}
Test-Case 'つないだら last を置き換え、recent の頭に移す' 'last=3000,8080 recent=example-a example-b' {
    $s = New-TestStore
    $s.recent = @('example-b', 'example-a')
    Register-Connection -Store $s -HostName 'example-a' -Ports @(3000, 8080)
    "last=$($s.hosts['example-a'].last -join ',') recent=$($s.recent -join ' ')"
}
Test-Case 'recent は 20 件まで' 'new h19 20' {
    $s = New-TestStore
    $s.recent = @(1..20 | ForEach-Object { "h$_" })
    Register-Connection -Store $s -HostName 'new' -Ports @(1)
    "$($s.recent[0]) $($s.recent[-1]) $($s.recent.Count)"
}

$map = [ordered]@{ 'example-a' = 1; 'Example-B' = 2 }
Test-Case 'Host のキー: 同じ綴り' 'example-a' { Find-HostKey $map 'example-a' }
Test-Case '共有の組は大文字小文字だけ違う Host 名でも引ける' 'example-a' { Find-HostKey $map 'Example-A' }
Test-Case 'Host のキー: 無ければ空' $true { $null -eq (Find-HostKey $map 'example-c') }
Test-Case '共有の組の配列を Host で引く' '3000 8080 api' { Get-SharedSpecList -Hosts ([ordered]@{ 'example-a' = @('3000', '8080 api') }) -HostName 'EXAMPLE-A' }
Test-Case '共有の組が無い Host は 0 件' 0 { @(Get-SharedSpecList -Hosts ([ordered]@{}) -HostName 'example-a').Count }

$store = ConvertTo-LocalStore ([ordered]@{ recent = @('gone', 'example-c', 'EXAMPLE-A'); hosts = [ordered]@{ 'example-a' = [ordered]@{ last = @(3000, 3001) } } })
Test-Case 'Host の並び: 最近つないだ Host を上に、残りは設定の順' 'example-c example-a example-b' { (Get-HostItem -ConfigHosts @('example-a', 'example-b', 'example-c') -Store $store).Name }
Test-Case 'Host の並び: 前回の port' '3000 3001' { @(Get-HostItem -ConfigHosts @('example-a') -Store $store)[0].Last }

$items = @('web-staging', 'web-prod', 'db-staging') | ForEach-Object { [pscustomobject]@{ Name = $_; Last = @() } }
Test-Case '絞り込み: どの語も含むものだけ (大文字小文字を問わない)' 'web-staging' { (Select-HostItem -Items $items -Query 'web  STAG').Name }
Test-Case '絞り込み: 空なら全部' 3 { @(Select-HostItem -Items $items -Query '').Count }
Test-Case '絞り込み: 合わなければ 0 件' 0 { @(Select-HostItem -Items $items -Query 'zzz').Count }

Test-Case 'local.json の形: 足りないキーは空で補う' 'version=1 recent= ports= hidden= last=1' {
    $s = ConvertTo-LocalStore ([ordered]@{ hosts = [ordered]@{ 'example-a' = [ordered]@{ last = @([long]1) } } })
    "version=$($s.version) recent=$($s.recent -join ',') $(Show-Entry $s)"
}
Test-Case 'local.json の形: 無ければ空の store' 'hosts=0 recent=0' { $s = ConvertTo-LocalStore $null; "hosts=$($s.hosts.Count) recent=$(@($s.recent).Count)" }
$badStores = @(
    @{ Name = 'object でない'; Value = @(1) }
    @{ Name = 'hosts が配列'; Value = [ordered]@{ hosts = @(1) } }
    @{ Name = 'Host の値が配列'; Value = [ordered]@{ hosts = [ordered]@{ a = @(1) } } }
    @{ Name = 'ports に数'; Value = [ordered]@{ hosts = [ordered]@{ a = [ordered]@{ ports = @(1) } } } }
    @{ Name = 'last に文字列'; Value = [ordered]@{ hosts = [ordered]@{ a = [ordered]@{ last = @('x') } } } }
    @{ Name = 'recent が文字列'; Value = [ordered]@{ recent = 'x' } }
)
foreach ($bad in $badStores) {
    Test-Case "local.json の形が違う: $($bad.Name)" $true { (& { try { ConvertTo-LocalStore $bad.Value; 'no error' } catch { $_.Exception.Message } }).StartsWith('local.json の形が違います') }
}

Test-Case '共有の組: Host ごとの配列 (数も文字列にする)' 'example-a=3000,8080 api example-b=8080 warn=' {
    $r = ConvertTo-SharedPort ([ordered]@{ version = 1; hosts = [ordered]@{ 'example-a' = @('3000', '8080 api'); 'example-b' = @([long]8080) } })
    "example-a=$($r.Hosts['example-a'] -join ',') example-b=$($r.Hosts['example-b'] -join ',') warn=$($r.Warning)"
}
Test-Case '共有の組: hosts が無いと注意を出して空' 'n=0 True' {
    $r = ConvertTo-SharedPort ([ordered]@{ version = 1 })
    "n=$($r.Hosts.Count) $($r.Warning.StartsWith('hosts.json の形が違います'))"
}
Test-Case '共有の組: 値が配列でない Host は飛ばして注意を出す' 'n=1 True' {
    $r = ConvertTo-SharedPort ([ordered]@{ hosts = [ordered]@{ 'example-a' = @('3000'); 'example-b' = '8080' } })
    "n=$($r.Hosts.Count) $($r.Warning.Contains('example-b'))"
}
Test-Case '共有の組: 無ければ空で注意なし' 'n=0 warn=' { $r = ConvertTo-SharedPort $null; "n=$($r.Hosts.Count) warn=$($r.Warning)" }

# ---------------------------------------------------------------------------
# 画面の状態とキー
# ---------------------------------------------------------------------------

# キー 1 つ。1 文字ならその文字 (英字はその文字のキー)、ほかは ConsoleKey の名前 (Enter・Escape・UpArrow…)。
# Ctrl を付けると、端末が送る制御文字 (Ctrl+C なら 0x03) と Control の修飾にする
function K {
    param([string]$Name, [switch]$Ctrl)
    if ($Name.Length -eq 1) {
        $key = if ($Name -match '^[A-Za-z]$') {
            [ConsoleKey]$Name.ToUpperInvariant()
        } elseif ($Name -eq ' ') {
            [ConsoleKey]::Spacebar
        } elseif ($Name -match '^[0-9]$') {
            [ConsoleKey]"D$Name"
        } else {
            [ConsoleKey]0
        }
        $char = if ($Ctrl) { [char]([int][char]$Name.ToUpperInvariant() - 64) } else { [char]$Name }
        return [ConsoleKeyInfo]::new($char, $key, $false, $false, [bool]$Ctrl)
    }
    $char = switch ($Name) { 'Enter' { [char]13 } 'Escape' { [char]27 } 'Backspace' { [char]8 } 'Spacebar' { [char]32 } default { [char]0 } }
    [ConsoleKeyInfo]::new($char, [ConsoleKey]$Name, $false, $false, [bool]$Ctrl)
}
# キーを順に送り、最後の返り値を返す。$Keys の文字列は 1 字ずつ K に、ConsoleKeyInfo はそのまま
function Send-Keys {
    param([scriptblock]$Step, [object[]]$Keys)
    $r = $null
    foreach ($k in $Keys) {
        if ($k -is [ConsoleKeyInfo]) {
            $r = & $Step $k
        } else {
            foreach ($c in ([string]$k).ToCharArray()) { $r = & $Step (K ([string]$c)) }
        }
    }
    $r
}

Test-Case '入力の行: 初めは末尾' 'ab 2' { $e = New-LineEdit 'ab'; "$($e.Text) $($e.Pos)" }
Test-Case '入力の行: ← の後に打つと間に入る' 'aXb' { $e = New-LineEdit 'ab'; [void](Send-Keys { Update-LineEdit $e $args[0] } @((K LeftArrow), 'X')); $e.Text }
Test-Case '入力の行: Home・Delete' 'b 0' { $e = New-LineEdit 'ab'; [void](Send-Keys { Update-LineEdit $e $args[0] } @((K Home), (K Delete))); "$($e.Text) $($e.Pos)" }
Test-Case '入力の行: End・Backspace' 'a 1' { $e = New-LineEdit 'ab'; [void](Send-Keys { Update-LineEdit $e $args[0] } @((K Home), (K End), (K Backspace))); "$($e.Text) $($e.Pos)" }
Test-Case '入力の行: 端では止まる' 'ab 0 ab 2' {
    $e = New-LineEdit 'ab'
    [void](Send-Keys { Update-LineEdit $e $args[0] } @((K LeftArrow), (K LeftArrow), (K LeftArrow), (K Backspace)))
    $a = "$($e.Text) $($e.Pos)"
    [void](Send-Keys { Update-LineEdit $e $args[0] } @((K End), (K RightArrow), (K Delete)))
    "$a $($e.Text) $($e.Pos)"
}
Test-Case '入力の行: Ctrl+U で空にする' ' 0' { $e = New-LineEdit 'abc'; [void](Update-LineEdit $e (K 'u' -Ctrl)); "$($e.Text) $($e.Pos)" }
Test-Case '入力の行: 日本語も打てる' '3000 ポスグレ' { $e = New-LineEdit '3000 '; [void](Send-Keys { Update-LineEdit $e $args[0] } @('ポスグレ')); $e.Text }
Test-Case '入力の行: Enter・Esc・ほかの文字' 'enter cancel none' {
    $e = New-LineEdit ''
    "$(Update-LineEdit $e (K Enter)) $(Update-LineEdit $e (K Escape)) $(Update-LineEdit $e (K 'x'))"
}
Test-Case '入力の行: Ctrl と組んだ文字は打たない' '' { $e = New-LineEdit ''; [void](Update-LineEdit $e (K 'a' -Ctrl)); $e.Text }

$hostItems = @('web-staging', 'web-prod', 'db-staging') | ForEach-Object { [pscustomobject]@{ Name = $_; Last = @() } }
Test-Case 'Host の画面: 初めは全部・先頭' '3 0' { $s = New-HostScreen -Items $hostItems -Query ''; "$(@($s.Shown).Count) $($s.Cursor)" }
Test-Case 'Host の画面: pf <引数> の絞り込みで開く' 'web-prod' { (New-HostScreen -Items $hostItems -Query 'prod').Shown.Name }
Test-Case 'Host の画面: 文字で絞る' 'db-staging' { $s = New-HostScreen $hostItems ''; [void](Send-Keys { Step-HostScreen $s $args[0] } @('db')); @($s.Shown).Name -join ' ' }
Test-Case 'Host の画面: Backspace・Ctrl+U で戻す' 'db-stagin 3' {
    $s = New-HostScreen $hostItems ''
    [void](Send-Keys { Step-HostScreen $s $args[0] } @('db-staging', (K Backspace)))
    $q = $s.Query
    [void](Step-HostScreen $s (K 'u' -Ctrl))
    "$q $(@($s.Shown).Count)"
}
Test-Case 'Host の画面: ↓↑ は端で止まる' '2 0' {
    $s = New-HostScreen $hostItems ''
    [void](Send-Keys { Step-HostScreen $s $args[0] } @((K DownArrow), (K DownArrow), (K DownArrow), (K DownArrow)))
    $a = $s.Cursor
    [void](Send-Keys { Step-HostScreen $s $args[0] } @((K UpArrow), (K UpArrow), (K UpArrow)))
    "$a $($s.Cursor)"
}
Test-Case 'Host の画面: Ctrl+N・Ctrl+P でも動く' '1 0' {
    $s = New-HostScreen $hostItems ''
    [void](Step-HostScreen $s (K 'n' -Ctrl))
    $a = $s.Cursor
    [void](Step-HostScreen $s (K 'p' -Ctrl))
    "$a $($s.Cursor)"
}
Test-Case 'Host の画面: 絞り込みを変えるとカーソルは先頭' 0 { $s = New-HostScreen $hostItems ''; [void](Send-Keys { Step-HostScreen $s $args[0] } @((K DownArrow), 'w')); $s.Cursor }
Test-Case 'Host の画面: Enter で選ぶ' 'select web-prod' { $s = New-HostScreen $hostItems ''; $r = Send-Keys { Step-HostScreen $s $args[0] } @((K DownArrow), (K Enter)); "$r $($s.Shown[$s.Cursor].Name)" }
Test-Case 'Host の画面: 0 件で Enter は何もしない' 'none' { $s = New-HostScreen $hostItems 'zzz'; Step-HostScreen $s (K Enter) }
Test-Case 'Host の画面: Esc・Ctrl+C でやめる' 'quit quit' { $s = New-HostScreen $hostItems ''; "$(Step-HostScreen $s (K Escape)) $(Step-HostScreen $s (K 'c' -Ctrl))" }

$portRows = @(Merge-PortRow -Shared @('3000', '3100', '8080 api') -Entry $null)
function New-TestPortScreen {
    param([int[]]$Last = @(), [switch]$BackQuits, $Rows = $portRows)
    New-PortScreen -HostName 'example-a' -Rows $Rows -Hidden @() -Entry ([ordered]@{ ports = @(); hidden = @(); last = $Last }) -BackQuits:$BackQuits
}
function Show-Checked { param($State) (@($State.Checked) | Sort-Object) -join ' ' }
Test-Case 'port の画面: チェックの初めは前回の port' '3000 8080' { Show-Checked (New-TestPortScreen -Last @(3000, 8080)) }
Test-Case 'port の画面: 前回が無ければ全部にチェック' '3000 3100 8080' { Show-Checked (New-TestPortScreen) }
Test-Case 'port の画面: 手元の組が無くても全部にチェック' '3000 3100 8080' { Show-Checked (New-PortScreen -HostName 'example-a' -Rows $portRows -Hidden @() -Entry $null) }
Test-Case 'port の画面: Space で切り替える' '3100 8080' { $s = New-TestPortScreen; [void](Step-PortScreen $s (K Spacebar)); Show-Checked $s }
Test-Case 'port の画面: a → 入力 → Enter で足す' 'set  9000 new' {
    $s = New-TestPortScreen
    $r = Send-Keys { Step-PortScreen $s $args[0] } @('a', '9000 new', (K Enter))
    "$($r.Kind) $($r.OldPort) $($r.Row.LocalPort) $($r.Row.Memo)"
}
Test-Case 'port の画面: 書き方の誤りは理由を出し、入力の行を開いたまま' 'none True True' {
    $s = New-TestPortScreen
    $r = Send-Keys { Step-PortScreen $s $args[0] } @('a', 'x', (K Enter))
    "$($r.Kind) $($null -ne $s.Prompt) $($s.Prompt.Error.StartsWith('書き方が違います'))"
}
Test-Case 'port の画面: 理由は次のキーで消える' '' { $s = New-TestPortScreen; [void](Send-Keys { Step-PortScreen $s $args[0] } @('a', 'x', (K Enter), (K Backspace))); $s.Prompt.Error }
Test-Case 'port の画面: e は今の書き方で開き、OldPort は今の port' '8080 api|set 8080 8080 api2' {
    $s = New-TestPortScreen
    [void](Send-Keys { Step-PortScreen $s $args[0] } @((K DownArrow), (K DownArrow), 'e'))
    $t = $s.Prompt.Edit.Text
    $r = Send-Keys { Step-PortScreen $s $args[0] } @('2', (K Enter))
    "$t|$($r.Kind) $($r.OldPort) $($r.Row.LocalPort) $($r.Row.Memo)"
}
Test-Case 'port の画面: 入力の行の Esc は入力だけをやめる' 'none False' { $s = New-TestPortScreen; $r = Send-Keys { Step-PortScreen $s $args[0] } @('a', '1', (K Escape)); "$($r.Kind) $($null -ne $s.Prompt)" }
Test-Case 'port の画面: 入力の行でも Ctrl+C でやめる' 'quit' { $s = New-TestPortScreen; (Send-Keys { Step-PortScreen $s $args[0] } @('a', '1', (K 'c' -Ctrl))).Kind }
Test-Case 'e で別の行と同じ port に直すと、理由を出して入力の行を開いたまま' 'none True True' {
    $s = New-TestPortScreen
    $r = Send-Keys { Step-PortScreen $s $args[0] } @('e', (K Backspace), (K Backspace), (K Backspace), (K Backspace), '3100 x', (K Enter))
    "$($r.Kind) $($null -ne $s.Prompt) $($s.Prompt.Error.StartsWith('3100 はもう別の行にあります'))"
}
Test-Case 'e で port を変えずにメモだけ直すのはよい' 'set 3000 3000 x' {
    $s = New-TestPortScreen
    $r = Send-Keys { Step-PortScreen $s $args[0] } @('e', ' x', (K Enter))
    "$($r.Kind) $($r.OldPort) $($r.Row.LocalPort) $($r.Row.Memo)"
}
Test-Case 'a で今ある port を足すと、その行を置き換える (spec のとおり)' 'set  3100' {
    $s = New-TestPortScreen
    $r = Send-Keys { Step-PortScreen $s $args[0] } @('a', '3100 x', (K Enter))
    "$($r.Kind) $($r.OldPort) $($r.Row.LocalPort)"
}
Test-Case 'port の画面: d で消す' 'delete 3100' { $s = New-TestPortScreen; $r = Send-Keys { Step-PortScreen $s $args[0] } @((K DownArrow), 'd'); "$($r.Kind) $($r.Port)" }
Test-Case 'port の画面: チェックが 0 件なら Enter でもつながない' 'none True' {
    $s = New-TestPortScreen -Last @(3000)
    $r = Send-Keys { Step-PortScreen $s $args[0] } @((K Spacebar), (K Enter))
    "$($r.Kind) $($s.Message.StartsWith('チェックした組がありません'))"
}
Test-Case '使用中の port にチェックがあると Enter でもつながない' 'none True' {
    $s = New-TestPortScreen
    [void]$s.Busy.Add(8080)
    $r = Step-PortScreen $s (K Enter)
    "$($r.Kind) $($s.Message.StartsWith('使用中の port があります: 8080'))"
}
Test-Case 'port の画面: 使用中でもチェックを外せばつなぐ' 'connect' {
    $s = New-TestPortScreen
    [void]$s.Busy.Add(8080)
    (Send-Keys { Step-PortScreen $s $args[0] } @((K DownArrow), (K DownArrow), (K Spacebar), (K Enter))).Kind
}
Test-Case 'port の画面: Esc で戻る・pf <Host> で開いたならやめる' 'back quit' {
    "$((Step-PortScreen (New-TestPortScreen) (K Escape)).Kind) $((Step-PortScreen (New-TestPortScreen -BackQuits) (K Escape)).Kind)"
}
Test-Case 'port の画面: Ctrl+C でやめる' 'quit' { (Step-PortScreen (New-TestPortScreen) (K 'c' -Ctrl)).Kind }
Test-Case 'port の画面: 組が無ければ e・d・Space は何もしない' 'none none none False' {
    $s = New-TestPortScreen -Rows @()
    "$((Step-PortScreen $s (K 'e')).Kind) $((Step-PortScreen $s (K 'd')).Kind) $((Step-PortScreen $s (K Spacebar)).Kind) $($null -ne $s.Prompt)"
}

Test-Case '足した port はチェックが付き、カーソルがそこへ移る' '3000 9000 3' {
    $s = New-TestPortScreen -Last @(3000)
    $rows = @(Merge-PortRow -Shared @('3000', '3100', '8080 api') -Entry ([ordered]@{ ports = @('9000'); hidden = @(); last = @() }))
    Update-PortRow -State $s -Rows $rows -Hidden @() -Action ([pscustomobject]@{ Kind = 'set'; OldPort = $null; Row = (ConvertFrom-PortSpec '9000'); Port = $null })
    "$(Show-Checked $s) $($s.Cursor)"
}
Test-Case 'port を変えて直した行はチェックを引き継ぐ' '13000' {
    $s = New-TestPortScreen -Last @(3000)
    $rows = @(Merge-PortRow -Shared @('3000', '3100', '8080 api') -Entry ([ordered]@{ ports = @('13000:3000'); hidden = @(3000); last = @() }))
    Update-PortRow -State $s -Rows $rows -Hidden @(3000) -Action ([pscustomobject]@{ Kind = 'set'; OldPort = 3000; Row = (ConvertFrom-PortSpec '13000:3000'); Port = $null })
    Show-Checked $s
}
Test-Case 'チェックの無い行は直してもチェックが無いまま' '3000' {
    $s = New-TestPortScreen -Last @(3000)
    Update-PortRow -State $s -Rows $portRows -Hidden @() -Action ([pscustomobject]@{ Kind = 'set'; OldPort = 8080; Row = (ConvertFrom-PortSpec '8080 api2'); Port = $null })
    Show-Checked $s
}
Test-Case '消した port のチェックは落ち、カーソルは行の中に収まる' '3000 3100 1' {
    $s = New-TestPortScreen
    $s.Cursor = 2
    $rows = @(Merge-PortRow -Shared @('3000', '3100', '8080 api') -Entry ([ordered]@{ ports = @(); hidden = @(8080); last = @() }))
    Update-PortRow -State $s -Rows $rows -Hidden @(8080) -Action ([pscustomobject]@{ Kind = 'delete'; OldPort = $null; Row = $null; Port = 8080 })
    "$(Show-Checked $s) $($s.Cursor)"
}
Test-Case '使用中の port (見る port のうち待ち受けているもの・重ねない)' '8080' { Get-BusyPort -Ports @($portRows.LocalPort) -Listening @(22, 8080, 8080) }

# ssh -G の出力 (OpenSSH の dump の形。2026-11-07 に Linux の OpenSSH で確かめた) から、設定の転送の手元の port
$sshG = @(
    'user tester'
    'localforward 6000 [localhost]:6000'
    'localforward [127.0.0.1]:4100 [db]:4000'
    'localforward [::1]:4000 [::1]:4001'
    'localforward /tmp/local.sock [x]:1'
    'remoteforward 9999 [localhost]:9999'
    'dynamicforward 1080'
)
Test-Case 'ssh -G の出力から設定の LocalForward・DynamicForward の手元の port' '6000 4100 4000 1080' { Get-ConfigForwardPort -Lines $sshG }
Test-Case 'ssh -G の port の全角の数字は読まない' 0 { @(Get-ConfigForwardPort -Lines @('localforward ６０００ [localhost]:6000')).Count }
Test-Case 'ssh の設定の LocalForward の port が使用中ならつながない' 'none True' {
    $s = New-TestPortScreen
    $s.ConfigPorts = [int[]]@(6000)
    [void]$s.Busy.Add(6000)
    $r = Step-PortScreen $s (K Enter)
    "$($r.Kind) $($s.Message.StartsWith('ssh の設定の LocalForward の port が使用中です: 6000'))"
}
Test-Case 'ssh の設定でも張る port にチェックがあるとつながない' 'none True' {
    $s = New-TestPortScreen
    $s.ConfigPorts = [int[]]@(3100)
    $r = Step-PortScreen $s (K Enter)
    "$($r.Kind) $($s.Message.StartsWith('ssh の設定でも張る port にチェックがあります: 3100'))"
}
Test-Case 'ssh の設定の転送があっても、重ならず使用中でなければつなぐ' 'connect' {
    $s = New-TestPortScreen
    $s.ConfigPorts = [int[]]@(6000)
    (Step-PortScreen $s (K Enter)).Kind
}

# ---------------------------------------------------------------------------
# 描く
# ---------------------------------------------------------------------------

# 色のエスケープを外す
function Remove-Escape {
    param([string]$Text)
    $Text -replace "`e\[[0-9;?]*[A-Za-z]", ''
}

Test-Case '桁: 半角は 1・全角は 2・矢印と … は 1・絵文字は 2' '3 4 3 1 1 2 0' {
    @('abc', 'あい', 'aあ', '→', '…', [char]::ConvertFromUtf32(0x1F600), '') | ForEach-Object { Get-DisplayWidth $_ }
}
Test-Case '桁にそろえる: 足りなければ空白で埋める' '[abc  ]' { "[$(Format-Cell 'abc' 5)]" }
Test-Case '桁にそろえる: はみ出せば … で切る' '[abc…] [あい…] [あ… ]' { "[$(Format-Cell 'abcdef' 4)] [$(Format-Cell 'あいう' 5)] [$(Format-Cell 'あいう' 4)]" }

$hs = New-HostScreen -Items @(
    [pscustomobject]@{ Name = 'web-staging'; Last = @(3000, 3001) }
    [pscustomobject]@{ Name = 'web-prod'; Last = @() }
    [pscustomobject]@{ Name = 'db-staging'; Last = @() }
) -Query 'web'
$hf = Format-HostScreen -State $hs -Width 80 -Height 20
$hl = @($hf.Lines | ForEach-Object { Remove-Escape $_ })
Test-Case 'Host の画面: 頭の行に絞り込み' 'pf  Host を選ぶ  › web' { $hl[0] }
Test-Case 'Host の画面: 選んだ行に > と前回の port' $true { $hl[2].StartsWith('> web-staging') -and $hl[2].Contains('前回: 3000 3001') }
Test-Case 'Host の画面: ほかの行' '  web-prod' { $hl[3].TrimEnd() }
Test-Case 'Host の画面: 最後の行はキーの説明' $true { $hl[-1].Contains('Enter 決める') -and $hl[-1].Contains('Esc やめる') }
Test-Case 'Host の画面: カーソルは絞り込みの後ろ' '22 0' { "$($hf.CursorX) $($hf.CursorY)" }
Test-Case 'Host の画面: 合う Host が無いとき' $true {
    @((Format-HostScreen -State (New-HostScreen -Items $hs.Items -Query 'zzz') -Width 80 -Height 20).Lines | ForEach-Object { Remove-Escape $_ }) -contains '  合う Host がありません'
}

$many = New-HostScreen -Items @(1..20 | ForEach-Object { [pscustomobject]@{ Name = "example-$_"; Last = @() } }) -Query ''
$many.Cursor = 15
$mf = Format-HostScreen -State $many -Width 40 -Height 8
Test-Case '選んだ行が見える所までずらす (高さ 8 に Host 20 個)' 'True True' {
    $lines = @($mf.Lines | ForEach-Object { Remove-Escape $_ })
    "$($lines.Count -le 8) $([bool]($lines | Where-Object { $_.StartsWith('> example-16') }))"
}

$prows = @(Merge-PortRow -Shared @('3000', '8080 api') -Entry ([ordered]@{ ports = @('15432:db:5432 ポスグレ'); hidden = @(3100); last = @() }))
$ps = New-PortScreen -HostName 'example-a' -Rows $prows -Hidden @(3100) -Entry $null
[void]$ps.Busy.Add(8080)
$ps.ConfigPorts = [int[]]@(6000)
[void]$ps.Busy.Add(6000)
$pf = Format-PortScreen -State $ps -Width 100 -Height 20
$pl = @($pf.Lines | ForEach-Object { Remove-Escape $_ })
Test-Case 'port の画面: 頭の行は Host' 'pf  example-a' { $pl[0] }
Test-Case 'port の画面: 行の形' '> [x] 3000  → localhost:3000' { $pl[2].Substring(0, 28) }
Test-Case 'port の画面: 使用中・この PC の印' 'True True' { "$($pl[3].Contains('使用中')) $($pl[4].Contains('この PC'))" }
Test-Case '全角のメモでも列がそろう' $true {
    (Get-DisplayWidth $pl[3].Substring(0, $pl[3].IndexOf('使用中'))) -eq (Get-DisplayWidth $pl[4].Substring(0, $pl[4].IndexOf('この PC')))
}
Test-Case 'port の画面: 隠した組と ssh の設定の転送' 'True True' {
    "$([bool]($pl | Where-Object { $_.Contains('この PC で隠した組: 3100') })) $([bool]($pl | Where-Object { $_.Contains('ssh の設定でも張る: 6000 (使用中)') }))"
}
Test-Case 'port の画面: 最後の行はキーの説明 (Esc 戻る)' $true { $pl[-1].Contains('a 足す') -and $pl[-1].Contains('Esc 戻る') }
Test-Case 'port の画面: pf <Host> で開いたなら Esc やめる' $true {
    $s = New-PortScreen -HostName 'example-a' -Rows $prows -Hidden @() -Entry $null -BackQuits
    (Remove-Escape @((Format-PortScreen -State $s -Width 100 -Height 20).Lines)[-1]).Contains('Esc やめる')
}
Test-Case 'port の画面: 組が無いとき' $true {
    $s = New-PortScreen -HostName 'example-a' -Rows @() -Hidden @() -Entry $null
    @((Format-PortScreen -State $s -Width 80 -Height 20).Lines | ForEach-Object { Remove-Escape $_ }) -contains '  組がありません。a で足す'
}
Test-Case '全角を含む入力のカーソルの桁' '足す: あい 10' {
    $s = New-PortScreen -HostName 'example-a' -Rows $prows -Hidden @() -Entry $null
    [void](Send-Keys { Step-PortScreen $s $args[0] } @('a', 'あい'))
    $f = Format-PortScreen -State $s -Width 80 -Height 20
    "$(Remove-Escape $f.Lines[$f.CursorY]) $($f.CursorX)"
}
Test-Case 'port の画面: 入力の誤りとメッセージを出す' 'True True' {
    $s = New-PortScreen -HostName 'example-a' -Rows $prows -Hidden @() -Entry $null
    [void](Send-Keys { Step-PortScreen $s $args[0] } @('a', 'x', (K Enter)))
    $a = [bool](@((Format-PortScreen -State $s -Width 120 -Height 20).Lines | ForEach-Object { Remove-Escape $_ }) | Where-Object { $_.StartsWith('書き方が違います') })
    $s.Prompt = $null
    $s.Message = 'チェックした組がありません (Space で付ける)'
    $b = @((Format-PortScreen -State $s -Width 120 -Height 20).Lines | ForEach-Object { Remove-Escape $_ }) -contains 'チェックした組がありません (Space で付ける)'
    "$a $b"
}
Test-Case 'どの行も幅を超えない (幅 40)' 0 {
    $s = New-PortScreen -HostName 'example-with-a-very-long-host-name.example.test' -Rows $prows -Hidden @(3100) -Entry $null
    $s.Warning = 'hosts.json の形が違います (hosts が object でない)。共有の組なしで出します'
    $lines = @((Format-PortScreen -State $s -Width 40 -Height 20).Lines) + @((Format-HostScreen -State $many -Width 40 -Height 8).Lines)
    @($lines | Where-Object { (Get-DisplayWidth (Remove-Escape $_)) -gt 39 }).Count
}
Test-Case 'port の画面: 低い端末でも高さを超えない' $true { @((Format-PortScreen -State $ps -Width 80 -Height 6).Lines).Count -le 6 }
Test-Case '低い端末でも入力の行は見える (注意が 2 行・高さ 6)' 'True 足す: 9' {
    $s = New-PortScreen -HostName 'example-a' -Rows $prows -Hidden @(3100) -Entry $null
    $s.ConfigPorts = [int[]]@(6000)
    [void](Send-Keys { Step-PortScreen $s $args[0] } @('a', '9'))
    $f = Format-PortScreen -State $s -Width 80 -Height 6
    "$($f.Lines.Count -le 6 -and $f.CursorY -lt 6) $(Remove-Escape $f.Lines[$f.CursorY])"
}

# ---------------------------------------------------------------------------
# 外側のうち、ファイルと ssh -G に触る関数 (Linux の一時ディレクトリと偽の ssh で確かめる)
# ---------------------------------------------------------------------------

$h = New-TestHome
$dataDir = Join-Path $h '.config/port-forward'
Test-Case 'hosts.json が無ければ共有の組なし (注意も無し)' 'n=0 warn=' { $r = Read-SharedPort (Join-Path $dataDir 'hosts.json'); "n=$($r.Hosts.Count) warn=$($r.Warning)" }
Write-TestFile (Join-Path $dataDir 'hosts.json') '{ "hosts": { "example-a": ["3000", "8080 api"] } '
Test-Case 'hosts.json が JSON でなければ注意を出して共有の組なし' 'n=0 True' {
    $r = Read-SharedPort (Join-Path $dataDir 'hosts.json')
    "n=$($r.Hosts.Count) $($r.Warning.StartsWith('hosts.json が読めません'))"
}
Write-TestFile (Join-Path $dataDir 'hosts.json') "{`n  `"version`": 1,`n  `"note`": `"…`",`n  `"hosts`": { `"example-a`": [`"3000`", `"8080 ポスグレ`"] }`n}`n"
Test-Case 'hosts.json を読む (日本語のメモも)' '3000,8080 ポスグレ' { (Read-SharedPort (Join-Path $dataDir 'hosts.json')).Hosts['example-a'] -join ',' }

$localPath = Join-Path $dataDir 'local.json'
Test-Case 'local.json が無ければ空の store' 'hosts=0' { "hosts=$((Read-LocalStore $localPath).hosts.Count)" }
Test-Case 'local.json に書いて読み直すと同じ (日本語のメモ・BOM なし)' 'ports=3000 ポスグレ hidden=3100 last=3000 recent=example-a bom=False' {
    $s = Read-LocalStore $localPath
    Set-PortSpec -Store $s -HostName 'example-a' -Shared @('3100') -OldPort $null -Row (ConvertFrom-PortSpec '3000 ポスグレ')
    Remove-PortSpec -Store $s -HostName 'example-a' -Shared @('3100') -Port 3100
    Register-Connection -Store $s -HostName 'example-a' -Ports @(3000)
    Write-LocalStore $localPath $s
    $back = Read-LocalStore $localPath
    $bytes = [System.IO.File]::ReadAllBytes($localPath)
    "$(Show-Entry $back) recent=$($back.recent -join ',') bom=$($bytes[0] -eq 0xEF)"
}
Test-Case 'local.json を読み直してから書くと、前の変更も残る' 'ports=3000 ポスグレ,9000 hidden=3100 last=3000' {
    $s = Read-LocalStore $localPath
    Set-PortSpec -Store $s -HostName 'example-a' -Shared @('3100') -OldPort $null -Row (ConvertFrom-PortSpec '9000')
    Write-LocalStore $localPath $s
    Show-Entry (Read-LocalStore $localPath)
}
Test-Case '1 件だけの配列も配列のまま書く' $true { (Get-Content -LiteralPath $localPath -Raw).Contains('"recent": [') }
Write-TestFile $localPath '{ "hosts": '
Test-Case 'local.json が JSON でなければ止まる' $true { (& { try { Read-LocalStore $localPath; 'no error' } catch { $_.Exception.Message } }).StartsWith('local.json が読めません') }
Write-TestFile $localPath '{ "hosts": [] }'
Test-Case 'local.json の形が違えば止まる' $true { (& { try { Read-LocalStore $localPath; 'no error' } catch { $_.Exception.Message } }).StartsWith('local.json の形が違います') }

# 偽の ssh (bash の script)。-G を受けたら ssh -G の形で設定の転送を出す。FAKE_SSH_FAIL があれば 255 で落ちる
$fakeSsh = Join-Path $h 'fake-ssh'
Write-TestFile $fakeSsh "#!/usr/bin/env bash`nif [[ -n `${FAKE_SSH_FAIL-} ]]; then exit 255; fi`nif [[ `$1 == -G ]]; then`n  echo 'user tester'`n  echo 'localforward 6000 [localhost]:6000'`n  echo 'localforward [127.0.0.1]:4100 [db]:4000'`nfi`n"
& chmod +x $fakeSsh
Test-Case 'ssh -G で設定の転送の port を読む' '6000 4100' { Read-ConfigForward -Ssh $fakeSsh -HostName 'example-a' }
Test-Case 'ssh -G が落ちたら設定の転送は無いものとする' 0 {
    $env:FAKE_SSH_FAIL = '1'
    try { @(Read-ConfigForward -Ssh $fakeSsh -HostName 'example-a').Count } finally { Remove-Item Env:FAKE_SSH_FAIL }
}
Test-Case 'ssh が無ければ設定の転送は無いものとする' 0 { @(Read-ConfigForward -Ssh (Join-Path $h 'no-such-ssh') -HostName 'example-a').Count }

# 本体の入口: 画面を開く前に止まるもの (別の pwsh で -File で流す)
$pwsh = (Get-Process -Id $PID).Path
$pfScript = Join-Path $PSScriptRoot 'Start-PortForward.ps1'
Test-Case 'ssh が見つからなければ、画面を開かずに終了コード 1' '1 True' {
    $home0 = New-TestHome
    Write-TestFile (Join-Path $home0 '.ssh/config') "Host example-a`n"
    $out = & $pwsh -NoProfile -File $pfScript -HomeDir $home0 -Ssh (Join-Path $home0 'no-such-ssh') 2>&1 | Out-String
    "$LASTEXITCODE $($out.Contains('ssh が見つかりません'))"
}
Test-Case 'ssh の設定に Host が無ければ終了コード 1' '1 True' {
    $home1 = New-TestHome
    $out = & $pwsh -NoProfile -File $pfScript -HomeDir $home1 2>&1 | Out-String
    "$LASTEXITCODE $($out.Contains('ssh の設定に Host がありません'))"
}
Test-Case 'local.json が読めなければ終了コード 1 (上書きしない)' '1 True True' {
    $home2 = New-TestHome
    Write-TestFile (Join-Path $home2 '.ssh/config') "Host example-a`n"
    Write-TestFile (Join-Path $home2 '.config/port-forward/local.json') '{ broken'
    $out = & $pwsh -NoProfile -File $pfScript -HomeDir $home2 'example-a' 2>&1 | Out-String
    "$LASTEXITCODE $($out.Contains('local.json が読めません')) $((Get-Content -LiteralPath (Join-Path $home2 '.config/port-forward/local.json') -Raw) -eq '{ broken')"
}

foreach ($d in $script:TempDirs) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
if ($script:Failures -gt 0) {
    Write-Host "$($script:Failures) 件失敗"
    exit 1
}
Write-Host 'すべて通った'
