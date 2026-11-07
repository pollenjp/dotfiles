#Requires -Version 7.0
<#
.SYNOPSIS
ssh の Host と port の組を選んで、port forwarding (ssh -NT -L …) をいまの PowerShell の中で張る (pf)。

.DESCRIPTION
dotfiles の win/port-forward/Start-PortForward.ps1 を %USERPROFILE%\.config\powershell\ へ配り、
PowerShell では dotfiles.ps1 の pf から呼ぶ (win/README.md の「port forwarding (pf)」)。

Host を選ぶ画面と port を選ぶ画面 (タスクリスト) を PowerShell だけで描き、選んだ組で
ssh -NT -o ExitOnForwardFailure=yes -L … <Host> を動かす。Ctrl+C で止める。

  Host の一覧   %USERPROFILE%\.ssh\config と、そこから Include するファイルの Host
  共有の組      %USERPROFILE%\.config\port-forward\hosts.json。setup の bootstrap-windows-port-forward.sh が
                dotfiles-private の ssh/port-forward.toml から書く。pf は書かない
  手元の組      %USERPROFILE%\.config\port-forward\local.json。この PC で足した・直した・隠した組と、
                前回つないだ port・最近つないだ Host。pf が書く

組の書き方は ssh -L と同じ形 (3000・13000:3000・13000:db:5432) に、空白を空けてメモを続ける。

BOM 付きの UTF-8 で保存すること (win/README.md の「dotfiles.ps1 を書くときの注意」)。

.PARAMETER HostName
ssh の設定の Host 名。一覧のどれかと同じ (大文字小文字は問わない) なら Host を選ぶ画面を飛ばす。
違えば、絞り込みに入れて Host を選ぶ画面を開く。語を並べたとき (pf web prod) は空白でつないで絞り込みに入れる。

.PARAMETER HomeDir
テストと Linux で試すとき用。.ssh/config と .config/port-forward/ を探す家 (既定は $HOME)。

.PARAMETER Ssh
テストと Linux で試すとき用。動かす ssh (既定は PATH の ssh)。
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$HostName,
    [string]$HomeDir = $HOME,
    [string]$Ssh = 'ssh'
)

# ---------------------------------------------------------------------------
# 副作用の無い関数 (Start-PortForward.Tests.ps1 で確かめる)
# ---------------------------------------------------------------------------

# 組の書き方 (ssh -L と同じ形に、空白を空けてメモを続ける) を読む。合わなければ理由を throw する。
#   3000                 手元の 3000 → 向こうの localhost:3000
#   13000:3000           手元の 13000 → 向こうの localhost:3000
#   13000:db:5432 メモ   手元の 13000 → 向こうのマシンから見た db:5432
# bind_address (127.0.0.1:3000:…) と Unix ソケットは書けない。つなぎ先の IPv6 は [::1] のように囲む。
# 行は手元の port で見分ける (ssh -L は同じ手元の port を 2 つ張れない)
function ConvertFrom-PortSpec {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { throw '空です' }
    # 数字は [0-9] で書く (.NET の \d は全角などの Unicode の数字にも合い、[int] にできずに落ちる)
    $m = [regex]::Match($Text, '^\s*([0-9]{1,5})(?::(?:(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9._-]+):)?([0-9]{1,5}))?(?:\s+(.*?))?\s*$')
    if (-not $m.Success) {
        throw "書き方が違います: $($Text.Trim()) (3000・13000:3000・13000:db:5432 のどれかに、空白を空けてメモを続ける)"
    }
    $local = [int]$m.Groups[1].Value
    $remote = if ($m.Groups[3].Success) { [int]$m.Groups[3].Value } else { $local }
    if ($local -lt 1 -or $local -gt 65535 -or $remote -lt 1 -or $remote -gt 65535) {
        throw "port は 1〜65535 で書いてください: $($Text.Trim())"
    }
    [pscustomobject]@{
        LocalPort  = $local
        RemoteHost = if ($m.Groups[2].Success) { $m.Groups[2].Value } else { 'localhost' }
        RemotePort = $remote
        Memo       = $m.Groups[4].Value
    }
}

# 行を書き方に戻す。つなぎ先が localhost なら短い形 (port が同じなら 3000、違えば 13000:3000) にする
function ConvertTo-PortSpec {
    param($Row)
    $spec = if ($Row.RemoteHost -ne 'localhost') {
        "$($Row.LocalPort):$($Row.RemoteHost):$($Row.RemotePort)"
    } elseif ($Row.RemotePort -ne $Row.LocalPort) {
        "$($Row.LocalPort):$($Row.RemotePort)"
    } else {
        "$($Row.LocalPort)"
    }
    if ($Row.Memo) { "$spec $($Row.Memo)" } else { $spec }
}

# ssh -L の値 (<手元>:<つなぎ先>:<向こう>)
function Get-ForwardArgument {
    param($Row)
    "$($Row.LocalPort):$($Row.RemoteHost):$($Row.RemotePort)"
}

# ssh に渡す引数。-o ExitOnForwardFailure=yes を付けないと、手元の port が使われていても
# ssh はその転送を落としたまま動き続ける
function Get-SshArgumentList {
    param([string]$HostName, $Rows)
    $list = [System.Collections.Generic.List[string]]::new()
    $list.AddRange([string[]]@('-NT', '-o', 'ExitOnForwardFailure=yes'))
    foreach ($row in $Rows) {
        $list.Add('-L')
        $list.Add((Get-ForwardArgument $row))
    }
    $list.Add($HostName)
    $list.ToArray()
}

# 打つコマンドを 1 行にする (画面に出すだけ)。空白を含む語だけ '…' で囲む
function Format-CommandLine {
    param([string]$Ssh, [string[]]$Arguments)
    $words = foreach ($w in @($Ssh) + $Arguments) {
        if ($w -match '\s') { "'$w'" } else { $w }
    }
    $words -join ' '
}

# ssh の設定の 1 行を、キーワード (小文字) と引数の語に分ける。空行とコメントの行は $null。
# OpenSSH (readconf.c) と同じく、キーワードの後ろは空白か = で区切り、"…" は囲みを外し、
# # で始まる語から後ろはコメントとして捨てる
function Split-SshConfigLine {
    param([string]$Line)
    $text = $Line.Trim()
    if ($text -eq '' -or $text.StartsWith('#')) { return $null }
    $m = [regex]::Match($text, '^([^\s=]+)\s*(?:=\s*)?(.*)$')
    if (-not $m.Success) { return $null }
    $words = [System.Collections.Generic.List[string]]::new()
    foreach ($t in [regex]::Matches($m.Groups[2].Value, '"([^"]*)"|(\S+)')) {
        if ($t.Groups[1].Success) {
            $words.Add($t.Groups[1].Value)
            continue
        }
        if ($t.Groups[2].Value.StartsWith('#')) { break }
        $words.Add($t.Groups[2].Value)
    }
    [pscustomobject]@{ Keyword = $m.Groups[1].Value.ToLowerInvariant(); Words = $words.ToArray() }
}

# Include の 1 語を、読むファイルのパスに広げる。相対パスは <家>/.ssh から、~ は家 (OpenSSH のユーザーの
# 設定と同じ)。ワイルドカードは最後の要素だけを、名前の順に広げる。無いものは何も返さない
function Resolve-SshInclude {
    param([string]$Pattern, [string]$HomeDir)
    $path = if ($Pattern -eq '~') {
        $HomeDir
    } elseif ($Pattern.StartsWith('~/') -or $Pattern.StartsWith('~\')) {
        Join-Path $HomeDir $Pattern.Substring(2)
    } elseif ([System.IO.Path]::IsPathRooted($Pattern)) {
        $Pattern
    } else {
        Join-Path $HomeDir '.ssh' $Pattern
    }
    $leaf = Split-Path -Leaf $path
    if (-not [System.Management.Automation.WildcardPattern]::ContainsWildcardCharacters($leaf)) {
        if (Test-Path -LiteralPath $path -PathType Leaf) { $path }
        return
    }
    $dir = Split-Path -Parent $path
    if (-not $dir -or -not (Test-Path -LiteralPath $dir -PathType Container)) { return }
    $names = [string[]]@(Get-ChildItem -LiteralPath $dir -File | Where-Object { $_.Name -like $leaf } | ForEach-Object Name)
    [Array]::Sort($names, [StringComparer]::Ordinal)
    foreach ($n in $names) { Join-Path $dir $n }
}

# ssh の設定 (<家>/.ssh/config と、Include の先) の Host の語を、出てくる順に返す。ワイルドカード (* ? !) を
# 含む語と - で始まる語は出さず (Host foo !bar なら foo だけ)、大文字小文字だけ違う名前は最初のものだけにする
# (ssh は Host の照合で大文字小文字を区別しない)。Match の行は Host を出さないが、その中の Include はたどる
function Get-SshConfigHost {
    param([string]$HomeDir)
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $reading = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $out = [System.Collections.Generic.List[string]]::new()
    Read-SshConfigFile -Path (Join-Path $HomeDir '.ssh' 'config') -HomeDir $HomeDir -Depth 0 -Seen $seen -Reading $reading -Out $out
    $out.ToArray()
}

# Get-SshConfigHost の 1 ファイルぶん。Include は 16 段までたどり (OpenSSH と同じ)、読んでいる途中の
# ファイルをもう一度 Include する輪は飛ばす。読めないファイルも飛ばす
function Read-SshConfigFile {
    param([string]$Path, [string]$HomeDir, [int]$Depth, $Seen, $Reading, $Out)
    if ($Depth -gt 16 -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    $full = [System.IO.Path]::GetFullPath($Path)
    if (-not $Reading.Add($full)) { return }
    try {
        $lines = try { @(Get-Content -LiteralPath $Path -Encoding utf8 -ErrorAction Stop) } catch { @() }
        foreach ($line in $lines) {
            $parsed = Split-SshConfigLine $line
            if ($null -eq $parsed) { continue }
            if ($parsed.Keyword -eq 'host') {
                foreach ($w in $parsed.Words) {
                    if ($w -match '[*?!]' -or $w.StartsWith('-')) { continue }
                    if ($Seen.Add($w)) { $Out.Add($w) }
                }
            } elseif ($parsed.Keyword -eq 'include') {
                foreach ($pattern in $parsed.Words) {
                    foreach ($file in @(Resolve-SshInclude -Pattern $pattern -HomeDir $HomeDir)) {
                        Read-SshConfigFile -Path $file -HomeDir $HomeDir -Depth ($Depth + 1) -Seen $Seen -Reading $Reading -Out $Out
                    }
                }
            }
        }
    } finally {
        [void]$Reading.Remove($full)
    }
}

# 手元の組 (local.json) の空の形。
#   recent            つないだ Host を新しい順に (20 件まで)
#   hosts.<Host>      ports  この PC で足した組と、共有の組を直した組 (短い形の書き方)
#                     hidden この PC で消した共有の組の手元の port
#                     last   前回つないだ手元の port
function New-LocalStore {
    [ordered]@{ version = 1; recent = @(); hosts = [ordered]@{} }
}

function New-HostEntry {
    [ordered]@{ ports = @(); hidden = @(); last = @() }
}

# local.json の値 1 つが、文字列 (Kind = string) か数 (Kind = int) の配列かを確かめて、要素を返す
function Get-CheckedList {
    param($Value, [string]$Kind, [string]$Where)
    if ($Value -isnot [System.Collections.IList]) { throw "local.json の形が違います: $Where は配列にする" }
    foreach ($v in $Value) {
        if ($Kind -eq 'string') {
            if ($v -isnot [string]) { throw "local.json の形が違います: $Where は文字列の配列にする" }
            $v
        } else {
            if ($v -isnot [int] -and $v -isnot [long]) { throw "local.json の形が違います: $Where は数の配列にする" }
            [int]$v
        }
    }
}

# local.json を読んだ値 (ConvertFrom-Json -AsHashtable) を確かめ、足りないキーを空で補った store にする。
# 形が違えば throw する (書き直して手元の組を消さないよう、呼ぶ側は止まる)
function ConvertTo-LocalStore {
    param($Object)
    $store = New-LocalStore
    if ($null -eq $Object) { return $store }
    if ($Object -isnot [System.Collections.IDictionary]) { throw 'local.json の形が違います: JSON の object にする' }
    if ($Object.Contains('recent')) { $store.recent = [string[]]@(Get-CheckedList $Object['recent'] 'string' 'recent') }
    if ($Object.Contains('hosts')) {
        $hosts = $Object['hosts']
        if ($hosts -isnot [System.Collections.IDictionary]) { throw 'local.json の形が違います: hosts は object にする' }
        foreach ($name in @($hosts.Keys)) {
            $e = $hosts[$name]
            if ($e -isnot [System.Collections.IDictionary]) { throw "local.json の形が違います: hosts.$name は object にする" }
            $entry = New-HostEntry
            if ($e.Contains('ports')) { $entry.ports = [string[]]@(Get-CheckedList $e['ports'] 'string' "hosts.$name.ports") }
            if ($e.Contains('hidden')) { $entry.hidden = [int[]]@(Get-CheckedList $e['hidden'] 'int' "hosts.$name.hidden") }
            if ($e.Contains('last')) { $entry.last = [int[]]@(Get-CheckedList $e['last'] 'int' "hosts.$name.last") }
            $store.hosts[[string]$name] = $entry
        }
    }
    $store
}

# 共有の組 (hosts.json) を読んだ値を、Host → 書き方の配列にする。形が違うところは飛ばし、
# Warning に理由を 1 行で入れる (pf は共有の組なしでも動く)。数の要素は文字列にする
function ConvertTo-SharedPort {
    param($Object)
    $hosts = [ordered]@{}
    $bad = [System.Collections.Generic.List[string]]::new()
    if ($null -ne $Object) {
        if ($Object -isnot [System.Collections.IDictionary] -or -not $Object.Contains('hosts') -or $Object['hosts'] -isnot [System.Collections.IDictionary]) {
            return [pscustomobject]@{ Hosts = $hosts; Warning = 'hosts.json の形が違います (hosts が object でない)。共有の組なしで出します' }
        }
        foreach ($name in @($Object['hosts'].Keys)) {
            $value = $Object['hosts'][$name]
            if ($value -isnot [System.Collections.IList]) {
                $bad.Add([string]$name)
                continue
            }
            $hosts[[string]$name] = [string[]]@($value | ForEach-Object { "$_" })
        }
    }
    $warning = if ($bad.Count -gt 0) { "hosts.json の形が違います: $($bad -join ', ') の値が配列でないので飛ばしました" } else { '' }
    [pscustomobject]@{ Hosts = $hosts; Warning = $warning }
}

# 表のキーから Host を引く。同じ綴りが無ければ、大文字小文字だけ違うキーを 1 つ (ssh は Host の照合で
# 大文字小文字を区別しない)。無ければ $null
function Find-HostKey {
    param($Map, [string]$HostName)
    if ($null -eq $Map) { return $null }
    foreach ($k in $Map.Keys) { if ($k -ceq $HostName) { return $k } }
    foreach ($k in $Map.Keys) { if ($k -eq $HostName) { return $k } }
    $null
}

# 共有の組から、その Host の書き方の配列を引く
function Get-SharedSpecList {
    param($Hosts, [string]$HostName)
    $key = Find-HostKey $Hosts $HostName
    if ($null -ne $key) { $Hosts[$key] }
}

# 手元の組の Host の entry。無ければ $null (Create なら作って足す)
function Get-HostEntry {
    param($Store, [string]$HostName, [switch]$Create)
    $key = Find-HostKey $Store.hosts $HostName
    if ($null -ne $key) { return $Store.hosts[$key] }
    if (-not $Create) { return $null }
    $entry = New-HostEntry
    $Store.hosts[$HostName] = $entry
    $entry
}

# 書き方の並びを読む。読めないものは飛ばし、同じ手元の port は先のものだけにする
function Get-ParsedRow {
    param([string[]]$Specs)
    $seen = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($s in $Specs) {
        try { $row = ConvertFrom-PortSpec $s } catch { continue }
        if ($seen.Add($row.LocalPort)) { $row }
    }
}

# 共有の組で、その手元の port の書き方 (短い形)。無ければ $null
function Get-SharedSpec {
    param([string[]]$Shared, [int]$Port)
    foreach ($row in @(Get-ParsedRow $Shared)) {
        if ($row.LocalPort -eq $Port) { return (ConvertTo-PortSpec $row) }
    }
    $null
}

# 共有の組に手元の組を重ねて、画面の行にする。Source は shared (共有のまま)・override (この PC で直した)・
# local (この PC だけ)。共有の行は hosts.json の順に、隠した port を除き、同じ port の手元の組があれば
# 置き換える。共有に無い手元の組は ports の順に後ろへ足す
function Merge-PortRow {
    param([string[]]$Shared, $Entry)
    $hidden = [System.Collections.Generic.HashSet[int]]::new()
    $locals = [System.Collections.Generic.Dictionary[int, object]]::new()
    $order = [System.Collections.Generic.List[int]]::new()
    if ($null -ne $Entry) {
        foreach ($p in $Entry.hidden) { [void]$hidden.Add([int]$p) }
        foreach ($s in $Entry.ports) {
            try { $row = ConvertFrom-PortSpec $s } catch { continue }
            if (-not $locals.ContainsKey($row.LocalPort)) { $order.Add($row.LocalPort) }
            $locals[$row.LocalPort] = $row
        }
    }
    $sharedPorts = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($row in @(Get-ParsedRow $Shared)) {
        [void]$sharedPorts.Add($row.LocalPort)
        if ($hidden.Contains($row.LocalPort)) { continue }
        $source = 'shared'
        if ($locals.ContainsKey($row.LocalPort)) {
            $mine = $locals[$row.LocalPort]
            if ((ConvertTo-PortSpec $mine) -cne (ConvertTo-PortSpec $row)) { $source = 'override' }
            $row = $mine
        }
        $row | Add-Member -NotePropertyName Source -NotePropertyValue $source -Force -PassThru
    }
    foreach ($port in $order) {
        if ($sharedPorts.Contains($port)) { continue }
        $locals[$port] | Add-Member -NotePropertyName Source -NotePropertyValue 'local' -Force -PassThru
    }
}

# 隠した共有の port (共有の組にあるものだけを、共有の順に)
function Get-HiddenPort {
    param([string[]]$Shared, $Entry)
    if ($null -eq $Entry) { return }
    foreach ($row in @(Get-ParsedRow $Shared)) {
        if (@($Entry.hidden) -contains $row.LocalPort) { $row.LocalPort }
    }
}

# 手元の組から、その手元の port の組を外す (読めない書き方は残す)
function Remove-LocalSpec {
    param($Entry, [int]$Port)
    $Entry.ports = [string[]]@($Entry.ports | Where-Object {
            try { (ConvertFrom-PortSpec $_).LocalPort -ne $Port } catch { $true }
        })
}

# a・e で決めた組を手元の組に書く。e で手元の port を変えたら、元の port の行は消す (共有なら隠す)。
# 共有と同じ中身になったら手元からは外す (共有の行に戻る)。同じ port の手元の組は同じ位置で置き換える
function Set-PortSpec {
    param($Store, [string]$HostName, [string[]]$Shared, $OldPort, $Row)
    $entry = Get-HostEntry -Store $Store -HostName $HostName -Create
    if ($null -ne $OldPort -and [int]$OldPort -ne $Row.LocalPort) {
        Remove-PortSpec -Store $Store -HostName $HostName -Shared $Shared -Port ([int]$OldPort)
    }
    $port = $Row.LocalPort
    $spec = ConvertTo-PortSpec $Row
    $keep = $spec -cne (Get-SharedSpec -Shared $Shared -Port $port)
    $entry.hidden = [int[]]@($entry.hidden | Where-Object { $_ -ne $port })
    $ports = [System.Collections.Generic.List[string]]::new()
    $placed = $false
    foreach ($s in $entry.ports) {
        $p = try { (ConvertFrom-PortSpec $s).LocalPort } catch { 0 }
        if ($p -ne $port) {
            $ports.Add($s)
        } elseif (-not $placed) {
            if ($keep) { $ports.Add($spec) }
            $placed = $true
        }
    }
    if (-not $placed -and $keep) { $ports.Add($spec) }
    $entry.ports = $ports.ToArray()
}

# d で消す。共有の組の port なら隠し (この PC で直した組も外す)、手元だけの組なら外す
function Remove-PortSpec {
    param($Store, [string]$HostName, [string[]]$Shared, [int]$Port)
    $entry = Get-HostEntry -Store $Store -HostName $HostName -Create
    Remove-LocalSpec -Entry $entry -Port $Port
    if ($null -ne (Get-SharedSpec -Shared $Shared -Port $Port) -and @($entry.hidden) -notcontains $Port) {
        $entry.hidden = [int[]](@($entry.hidden) + $Port)
    }
}

# つないだ組を前回の選択にし、Host を最近つないだ Host の頭に移す (20 件まで)
function Register-Connection {
    param($Store, [string]$HostName, [int[]]$Ports)
    $entry = Get-HostEntry -Store $Store -HostName $HostName -Create
    $entry.last = [int[]]@($Ports)
    $Store.recent = [string[]]@(@($HostName) + @($Store.recent | Where-Object { $_ -ne $HostName }) | Select-Object -First 20)
}

# Host を選ぶ画面の並び。最近つないだ Host (ssh の設定にあるもの) を上に、残りを ssh の設定の順に。
# Last は前回つないだ手元の port
function Get-HostItem {
    param([string[]]$ConfigHosts, $Store)
    $used = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($r in $Store.recent) {
        $name = $ConfigHosts | Where-Object { $_ -eq $r } | Select-Object -First 1
        if ($name -and $used.Add($name)) { $names.Add($name) }
    }
    foreach ($h in $ConfigHosts) { if ($used.Add($h)) { $names.Add($h) } }
    foreach ($name in $names) {
        $entry = Get-HostEntry -Store $Store -HostName $name
        [pscustomobject]@{ Name = $name; Last = [int[]]@(if ($null -ne $entry) { $entry.last }) }
    }
}

# 打った文字列を空白で区切り、どの語も名前に含む (大文字小文字を問わない) Host だけを残す。並びは変えない
function Select-HostItem {
    param($Items, [string]$Query)
    $terms = @($Query -split '\s+' | Where-Object { $_ })
    foreach ($item in $Items) {
        $miss = $terms | Where-Object { $item.Name.IndexOf($_, [StringComparison]::OrdinalIgnoreCase) -lt 0 }
        if (-not $miss) { $item }
    }
}

# 見る port のうち、手元で待ち受けているもの (どのアドレスでも)
function Get-BusyPort {
    param([int[]]$Ports, [int[]]$Listening)
    $set = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($p in $Listening) { [void]$set.Add($p) }
    $seen = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($p in $Ports) {
        if ($set.Contains($p) -and $seen.Add($p)) { $p }
    }
}

# ssh -G <Host> の出力から、ssh の設定の LocalForward・DynamicForward の手元の port を読む。行は
# localforward <port か [addr]:port> <[host]:port>・dynamicforward <port か [addr]:port> の形 (Unix ソケットは飛ばす)。
# pf の ssh はこれも張る
function Get-ConfigForwardPort {
    param([string[]]$Lines)
    foreach ($line in $Lines) {
        $m = [regex]::Match($line, '^\s*(?:localforward|dynamicforward)\s+(?:\[[^\]]*\]:)?([0-9]+)(?:\s|$)')
        if ($m.Success) { [int]$m.Groups[1].Value }
    }
}

# Ctrl と英字のキーか。端末によって制御文字 (Ctrl+C なら 0x03) でも、Control の修飾付きの英字でも来る
function Test-CtrlKey {
    param([ConsoleKeyInfo]$Key, [char]$Letter)
    $upper = [char]::ToUpperInvariant($Letter)
    if ([int]$Key.KeyChar -eq ([int]$upper - 64)) { return $true }
    (($Key.Modifiers -band [ConsoleModifiers]::Control) -ne 0) -and ($Key.Key -eq [ConsoleKey]"$upper")
}

# 打てる文字のキーか (Ctrl・Alt と組んだものは除く。AltGr は Ctrl+Alt で来るので打てる文字に入れる)
function Test-TextKey {
    param([ConsoleKeyInfo]$Key)
    $c = $Key.KeyChar
    if ($c -eq [char]0 -or [char]::IsControl($c)) { return $false }
    $ctrl = ($Key.Modifiers -band [ConsoleModifiers]::Control) -ne 0
    $alt = ($Key.Modifiers -band [ConsoleModifiers]::Alt) -ne 0
    -not ($ctrl -xor $alt)
}

# 入力の行 (a・e で開く)。Pos はカーソルの前の文字数
function New-LineEdit {
    param([string]$Text)
    [pscustomobject]@{ Text = $Text; Pos = $Text.Length }
}

# 入力の行にキーを 1 つ渡す。返りは enter (決める)・cancel (やめる)・none
function Update-LineEdit {
    param($Edit, [ConsoleKeyInfo]$Key)
    switch ($Key.Key) {
        'Enter' { return 'enter' }
        'Escape' { return 'cancel' }
        'LeftArrow' { if ($Edit.Pos -gt 0) { $Edit.Pos-- }; return 'none' }
        'RightArrow' { if ($Edit.Pos -lt $Edit.Text.Length) { $Edit.Pos++ }; return 'none' }
        'Home' { $Edit.Pos = 0; return 'none' }
        'End' { $Edit.Pos = $Edit.Text.Length; return 'none' }
        'Backspace' {
            if ($Edit.Pos -gt 0) {
                $Edit.Text = $Edit.Text.Remove($Edit.Pos - 1, 1)
                $Edit.Pos--
            }
            return 'none'
        }
        'Delete' {
            if ($Edit.Pos -lt $Edit.Text.Length) { $Edit.Text = $Edit.Text.Remove($Edit.Pos, 1) }
            return 'none'
        }
    }
    if (Test-CtrlKey $Key 'u') {
        $Edit.Text = ''
        $Edit.Pos = 0
    } elseif (Test-TextKey $Key) {
        $Edit.Text = $Edit.Text.Insert($Edit.Pos, [string]$Key.KeyChar)
        $Edit.Pos++
    }
    'none'
}

# Host を選ぶ画面の状態。Shown は絞り込んだ並び、Cursor はその中の位置、Offset は描くときの先頭
function New-HostScreen {
    param($Items, [string]$Query)
    $state = [pscustomobject]@{ Items = @($Items); Query = $Query; Shown = @(); Cursor = 0; Offset = 0 }
    $state.Shown = @(Select-HostItem -Items $state.Items -Query $Query)
    $state
}

# Host を選ぶ画面にキーを 1 つ渡す。返りは select (Shown[Cursor] に決めた)・quit・none
function Step-HostScreen {
    param($State, [ConsoleKeyInfo]$Key)
    if ($Key.Key -eq 'Escape' -or (Test-CtrlKey $Key 'c')) { return 'quit' }
    $count = @($State.Shown).Count
    if ($Key.Key -eq 'Enter') {
        if ($count -gt 0) { return 'select' }
        return 'none'
    }
    if ($Key.Key -eq 'UpArrow' -or (Test-CtrlKey $Key 'p')) {
        if ($State.Cursor -gt 0) { $State.Cursor-- }
        return 'none'
    }
    if ($Key.Key -eq 'DownArrow' -or (Test-CtrlKey $Key 'n')) {
        if ($State.Cursor -lt $count - 1) { $State.Cursor++ }
        return 'none'
    }
    $query = $State.Query
    if ($Key.Key -eq 'Backspace') {
        if ($query.Length -gt 0) { $query = $query.Substring(0, $query.Length - 1) }
    } elseif (Test-CtrlKey $Key 'u') {
        $query = ''
    } elseif (Test-TextKey $Key) {
        $query += $Key.KeyChar
    }
    if ($query -cne $State.Query) {
        $State.Query = $query
        $State.Shown = @(Select-HostItem -Items $State.Items -Query $query)
        $State.Cursor = 0
        $State.Offset = 0
    }
    'none'
}

# port を選ぶ画面の状態。チェックの初めは前回つないだ port、前回が無ければ全部の行。
#   Busy        手元で待ち受けている port (行と ConfigPorts のうち。外側がキーのたびに読み直す)
#   ConfigPorts ssh の設定の LocalForward の手元の port (pf の ssh も張る)
#   Prompt      a・e の入力の行 (Kind・Edit・OldPort・Error)。閉じているときは $null
#   BackQuits   Esc でやめる (pf <Host> で Host の画面を飛ばしたとき)
function New-PortScreen {
    param([string]$HostName, $Rows, [int[]]$Hidden, $Entry, [switch]$BackQuits)
    $checked = [System.Collections.Generic.HashSet[int]]::new()
    $last = @(if ($null -ne $Entry -and $null -ne $Entry.last) { $Entry.last })
    foreach ($row in $Rows) {
        if ($last.Count -eq 0 -or $last -contains $row.LocalPort) { [void]$checked.Add($row.LocalPort) }
    }
    [pscustomobject]@{
        HostName    = $HostName
        Rows        = @($Rows)
        Hidden      = @($Hidden)
        Checked     = $checked
        Busy        = [System.Collections.Generic.HashSet[int]]::new()
        ConfigPorts = [int[]]@()
        Cursor      = 0
        Offset      = 0
        Prompt      = $null
        Message     = ''
        Warning     = ''
        BackQuits   = [bool]$BackQuits
    }
}

# port を選ぶ画面の返り。Kind は none・back・quit・connect・set (OldPort → Row に書く)・delete (Port を消す)
function New-PortAction {
    param([string]$Kind, $OldPort = $null, $Row = $null, $Port = $null)
    [pscustomobject]@{ Kind = $Kind; OldPort = $OldPort; Row = $Row; Port = $Port }
}

# port を選ぶ画面にキーを 1 つ渡す。組を変える (set・delete) のは呼ぶ側で、変えたら Update-PortRow で行を差し替える
function Step-PortScreen {
    param($State, [ConsoleKeyInfo]$Key)
    $State.Message = ''
    if (Test-CtrlKey $Key 'c') { return New-PortAction 'quit' }
    if ($null -ne $State.Prompt) {
        $prompt = $State.Prompt
        $prompt.Error = ''
        $r = Update-LineEdit $prompt.Edit $Key
        if ($r -eq 'cancel') {
            $State.Prompt = $null
        } elseif ($r -eq 'enter') {
            try {
                $row = ConvertFrom-PortSpec $prompt.Edit.Text
            } catch {
                $prompt.Error = $_.Exception.Message
                return New-PortAction 'none'
            }
            # e で手元の port を、ほかの行と同じ番号に変えると、その行が黙って置き換わる。止めて知らせる
            # (a で今ある port を足したときは、その行を置き換える)
            if ($prompt.Kind -eq 'edit' -and $row.LocalPort -ne $prompt.OldPort -and
                @($State.Rows | Where-Object { $_.LocalPort -eq $row.LocalPort }).Count -gt 0) {
                $prompt.Error = "$($row.LocalPort) はもう別の行にあります (その行を e で直すか、d で消してから直す)"
                return New-PortAction 'none'
            }
            $State.Prompt = $null
            return New-PortAction 'set' -OldPort $prompt.OldPort -Row $row
        }
        return New-PortAction 'none'
    }
    $rows = @($State.Rows)
    $current = if ($rows.Count -gt 0) { $rows[$State.Cursor] } else { $null }
    $letter = if (Test-TextKey $Key) { ([string]$Key.KeyChar).ToLowerInvariant() } else { '' }
    if ($Key.Key -eq 'Escape') {
        if ($State.BackQuits) { return New-PortAction 'quit' }
        return New-PortAction 'back'
    } elseif ($Key.Key -eq 'UpArrow') {
        if ($State.Cursor -gt 0) { $State.Cursor-- }
    } elseif ($Key.Key -eq 'DownArrow') {
        if ($State.Cursor -lt $rows.Count - 1) { $State.Cursor++ }
    } elseif ($Key.Key -eq 'Spacebar') {
        if ($null -ne $current -and -not $State.Checked.Remove($current.LocalPort)) { [void]$State.Checked.Add($current.LocalPort) }
    } elseif ($letter -eq 'a') {
        $State.Prompt = [pscustomobject]@{ Kind = 'add'; Edit = (New-LineEdit ''); OldPort = $null; Error = '' }
    } elseif ($letter -eq 'e') {
        if ($null -ne $current) {
            $State.Prompt = [pscustomobject]@{ Kind = 'edit'; Edit = (New-LineEdit (ConvertTo-PortSpec $current)); OldPort = $current.LocalPort; Error = '' }
        }
    } elseif ($letter -eq 'd') {
        if ($null -ne $current) { return New-PortAction 'delete' -Port $current.LocalPort }
    } elseif ($Key.Key -eq 'Enter') {
        return Test-PortConnect $State
    }
    New-PortAction 'none'
}

# Enter で、つないでよいかを確かめる。だめなら Message に理由を入れて none
function Test-PortConnect {
    param($State)
    $selected = @($State.Rows | Where-Object { $State.Checked.Contains($_.LocalPort) })
    if ($selected.Count -eq 0) {
        $State.Message = 'チェックした組がありません (Space で付ける)'
        return New-PortAction 'none'
    }
    $busy = @($selected | Where-Object { $State.Busy.Contains($_.LocalPort) } | ForEach-Object LocalPort)
    if ($busy.Count -gt 0) {
        $State.Message = "使用中の port があります: $($busy -join ' ') (チェックを外すか、使っているものを止める)"
        return New-PortAction 'none'
    }
    $configBusy = @($State.ConfigPorts | Where-Object { $State.Busy.Contains($_) })
    if ($configBusy.Count -gt 0) {
        $State.Message = "ssh の設定の LocalForward の port が使用中です: $($configBusy -join ' ') (pf の ssh も張るので落ちます)"
        return New-PortAction 'none'
    }
    $twice = @($selected | Where-Object { $State.ConfigPorts -contains $_.LocalPort } | ForEach-Object LocalPort)
    if ($twice.Count -gt 0) {
        $State.Message = "ssh の設定でも張る port にチェックがあります: $($twice -join ' ') (チェックを外す)"
        return New-PortAction 'none'
    }
    New-PortAction 'connect'
}

# 組を変えた (set・delete) あとに行を差し替える。足した行はチェックを付け、直した行はチェックを保ち
# (port を変えたら新しい port へ引き継ぐ)、行に無くなった port のチェックは落とす。カーソルは変えた行へ
function Update-PortRow {
    param($State, $Rows, [int[]]$Hidden, $Action)
    $State.Rows = @($Rows)
    $State.Hidden = @($Hidden)
    $focus = $null
    if ($Action.Kind -eq 'set') {
        $new = $Action.Row.LocalPort
        $wasChecked = ($null -eq $Action.OldPort) -or $State.Checked.Contains([int]$Action.OldPort)
        if ($null -ne $Action.OldPort) { [void]$State.Checked.Remove([int]$Action.OldPort) }
        if ($wasChecked) { [void]$State.Checked.Add($new) }
        $focus = $new
    }
    $ports = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($row in $State.Rows) { [void]$ports.Add($row.LocalPort) }
    foreach ($p in @($State.Checked)) {
        if (-not $ports.Contains($p)) { [void]$State.Checked.Remove($p) }
    }
    if ($null -ne $focus) {
        for ($i = 0; $i -lt $State.Rows.Count; $i++) {
            if ($State.Rows[$i].LocalPort -eq $focus) { $State.Cursor = $i }
        }
    }
    $State.Cursor = [Math]::Max(0, [Math]::Min($State.Cursor, $State.Rows.Count - 1))
}

# 色。NO_COLOR があれば付けない (Format-Line が見る)
$script:Styles = @{ Reset = "`e[0m"; Bold = "`e[1m"; Dim = "`e[2m"; Rev = "`e[7m"; Red = "`e[31m"; Yellow = "`e[33m"; Cyan = "`e[36m" }

# 端末に出したときの桁数。全角 (東アジアの幅が W・F の主な範囲) と、BMP の外の文字 (絵文字など) は 2 桁、
# ほかは 1 桁。幅が曖昧な文字 (→・…・─) は Windows Terminal と同じく 1 桁に数える
function Get-DisplayWidth {
    param([string]$Text)
    $w = 0
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $c = [int]$Text[$i]
        if ([char]::IsHighSurrogate($Text[$i])) {
            $w += 2
            $i++
        } elseif (($c -ge 0x1100 -and $c -le 0x115F) -or ($c -ge 0x2E80 -and $c -le 0x303E) -or ($c -ge 0x3041 -and $c -le 0x33FF) -or
            ($c -ge 0x3400 -and $c -le 0x4DBF) -or ($c -ge 0x4E00 -and $c -le 0x9FFF) -or ($c -ge 0xA000 -and $c -le 0xA4CF) -or
            ($c -ge 0xAC00 -and $c -le 0xD7A3) -or ($c -ge 0xF900 -and $c -le 0xFAFF) -or ($c -ge 0xFE30 -and $c -le 0xFE4F) -or
            ($c -ge 0xFF00 -and $c -le 0xFF60) -or ($c -ge 0xFFE0 -and $c -le 0xFFE6)) {
            $w += 2
        } else {
            $w += 1
        }
    }
    $w
}

# 頭から $Cols 桁に収まるだけの文字列 (サロゲートの組は分けない)
function Get-TextPrefix {
    param([string]$Text, [int]$Cols)
    $w = 0
    $i = 0
    while ($i -lt $Text.Length) {
        $len = if ([char]::IsHighSurrogate($Text[$i]) -and $i + 1 -lt $Text.Length) { 2 } else { 1 }
        $cw = Get-DisplayWidth $Text.Substring($i, $len)
        if ($w + $cw -gt $Cols) { break }
        $w += $cw
        $i += $len
    }
    $Text.Substring(0, $i)
}

# ちょうど $Width 桁にする。足りなければ空白で埋め、はみ出せば … で切る
function Format-Cell {
    param([string]$Text, [int]$Width)
    if ($Width -le 0) { return '' }
    $w = Get-DisplayWidth $Text
    if ($w -le $Width) { return $Text + (' ' * ($Width - $w)) }
    $head = (Get-TextPrefix $Text ($Width - 1)) + '…'
    $head + (' ' * ($Width - (Get-DisplayWidth $head)))
}

# 1 行の区切り (文字列と色の名前)
function New-Seg {
    param([string]$Text, [string]$Style = '')
    [pscustomobject]@{ Text = $Text; Style = $Style }
}

# 区切りを並べて 1 行にし、$Width 桁に収める (はみ出す分は … で切る)。Selected なら行の幅いっぱいを反転する
function Format-Line {
    param([object[]]$Segments, [int]$Width, [switch]$Selected)
    $color = -not $env:NO_COLOR
    $total = 0
    foreach ($seg in $Segments) { $total += Get-DisplayWidth $seg.Text }
    $room = if ($total -gt $Width) { $Width - 1 } else { $Width }
    $base = if ($Selected -and $color) { $script:Styles.Rev } else { '' }
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append($base)
    foreach ($seg in $Segments) {
        if ($room -le 0) { break }
        $text = $seg.Text
        $w = Get-DisplayWidth $text
        if ($w -gt $room) {
            $text = Get-TextPrefix $text $room
            $w = Get-DisplayWidth $text
        }
        if ($color -and $seg.Style) {
            [void]$sb.Append($script:Styles[$seg.Style]).Append($text).Append($script:Styles.Reset).Append($base)
        } else {
            [void]$sb.Append($text)
        }
        $room -= $w
    }
    if ($total -gt $Width) {
        [void]$sb.Append('…')
    } elseif ($Selected) {
        [void]$sb.Append(' ' * ($Width - $total))
    }
    if ($base) { [void]$sb.Append($script:Styles.Reset) }
    $sb.ToString()
}

# 選んだ行が見えるよう、描く先頭 (Offset) をずらす
function Set-ScrollOffset {
    param($State, [int]$Count, [int]$Visible)
    if ($State.Cursor -lt $State.Offset) { $State.Offset = $State.Cursor }
    if ($State.Cursor -ge $State.Offset + $Visible) { $State.Offset = $State.Cursor - $Visible + 1 }
    $State.Offset = [Math]::Max(0, [Math]::Min($State.Offset, [Math]::Max(0, $Count - $Visible)))
}

# 描いた画面。Lines は 1 行ずつ (色のエスケープ付き。どれも Width - 1 桁以内で、数は Height 以内)、
# CursorX・CursorY は文字を打つ位置 (0 始まり。打たない画面では $null)
function New-Frame {
    param([string[]]$Lines, [int]$Height, $CursorX, $CursorY)
    if ($Height -gt 0 -and $Lines.Count -gt $Height) {
        # 下から切る。文字を打つ行 (入力の行) が切られるときは、その行が最後に来るよう上から切る
        $start = if ($null -ne $CursorY -and $CursorY -ge $Height) { $CursorY - $Height + 1 } else { 0 }
        $Lines = $Lines[$start..($start + $Height - 1)]
        if ($null -ne $CursorY) { $CursorY -= $start }
    }
    if ($null -ne $CursorY -and ($CursorY -lt 0 -or $CursorY -ge $Lines.Count)) { $CursorX = $null; $CursorY = $null }
    [pscustomobject]@{ Lines = $Lines; CursorX = $CursorX; CursorY = $CursorY }
}

# Host を選ぶ画面を描く
#   pf  Host を選ぶ  › <絞り込み>
#   ──────────
#   > <Host>   前回: 3000 3001
#   ──────────
#   ↑↓ 選ぶ  Enter 決める  Esc やめる
function Format-HostScreen {
    param($State, [int]$Width, [int]$Height)
    $w = [Math]::Max(10, $Width - 1)
    $prefix = 'pf  Host を選ぶ  › '
    $rule = Format-Line @(New-Seg ('─' * $w) 'Dim') $w
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add((Format-Line @((New-Seg $prefix 'Bold'), (New-Seg $State.Query)) $w))
    $lines.Add($rule)
    $shown = @($State.Shown)
    $visible = [Math]::Max(1, $Height - 4)
    if ($shown.Count -eq 0) {
        $lines.Add((Format-Line @(New-Seg '  合う Host がありません' 'Dim') $w))
    } else {
        Set-ScrollOffset -State $State -Count $shown.Count -Visible $visible
        $longest = ($shown | ForEach-Object { Get-DisplayWidth $_.Name } | Measure-Object -Maximum).Maximum
        $nameWidth = [Math]::Min([int]$longest, [Math]::Max(10, [int]($w / 2)))
        $end = [Math]::Min($shown.Count, $State.Offset + $visible)
        for ($i = $State.Offset; $i -lt $end; $i++) {
            $item = $shown[$i]
            $selected = $i -eq $State.Cursor
            $segs = @((New-Seg $(if ($selected) { '> ' } else { '  ' })), (New-Seg (Format-Cell $item.Name $nameWidth)))
            if (@($item.Last).Count -gt 0) { $segs += New-Seg ('   前回: ' + ($item.Last -join ' ')) 'Dim' }
            $lines.Add((Format-Line $segs $w -Selected:$selected))
        }
    }
    $lines.Add($rule)
    $lines.Add((Format-Line @(New-Seg '↑↓ 選ぶ  Enter 決める  Esc やめる  (文字を打つと絞り込む)' 'Dim') $w))
    $x = [Math]::Min($w, (Get-DisplayWidth $prefix) + (Get-DisplayWidth $State.Query))
    New-Frame -Lines $lines.ToArray() -Height $Height -CursorX $x -CursorY 0
}

# port を選ぶ画面を描く
#   pf  <Host>
#   ──────────
#   > [x] 3000  → localhost:3000   front   使用中  この PC
#     この PC で隠した組: 3100 (同じ port を a で足すと戻る)
#     ssh の設定でも張る: 6000 (使用中)
#   ──────────
#   <メッセージ、または入力の行 (足す: … / 直す: …)>
#   Space 切り替え  a 足す  e 直す  d 消す  Enter つなぐ  Esc 戻る
function Format-PortScreen {
    param($State, [int]$Width, [int]$Height)
    $w = [Math]::Max(10, $Width - 1)
    $rule = Format-Line @(New-Seg ('─' * $w) 'Dim') $w
    $top = @((Format-Line @((New-Seg 'pf  ' 'Bold'), (New-Seg $State.HostName 'Bold')) $w), $rule)

    $notes = [System.Collections.Generic.List[string]]::new()
    if (@($State.Hidden).Count -gt 0) {
        $notes.Add((Format-Line @(New-Seg "  この PC で隠した組: $($State.Hidden -join ' ') (同じ port を a で足すと戻る)" 'Dim') $w))
    }
    if (@($State.ConfigPorts).Count -gt 0) {
        $text = @($State.ConfigPorts | ForEach-Object { if ($State.Busy.Contains($_)) { "$_ (使用中)" } else { "$_" } }) -join ' '
        $notes.Add((Format-Line @(New-Seg "  ssh の設定でも張る: $text" 'Dim') $w))
    }
    if ($State.Warning) { $notes.Add((Format-Line @(New-Seg "  $($State.Warning)" 'Yellow') $w)) }

    $x = $null
    if ($null -ne $State.Prompt) {
        $label = if ($State.Prompt.Kind -eq 'add') { '足す: ' } else { '直す: ' }
        $edit = $State.Prompt.Edit
        $message = Format-Line @((New-Seg $label 'Bold'), (New-Seg $edit.Text)) $w
        $x = [Math]::Min($w, (Get-DisplayWidth $label) + (Get-DisplayWidth $edit.Text.Substring(0, $edit.Pos)))
        $help = if ($State.Prompt.Error) {
            Format-Line @(New-Seg $State.Prompt.Error 'Red') $w
        } else {
            Format-Line @(New-Seg 'Enter 決める  Esc やめる  (3000・13000:3000・13000:db:5432 に、空白を空けてメモ)' 'Dim') $w
        }
    } else {
        $message = if ($State.Message) { Format-Line @(New-Seg $State.Message 'Yellow') $w } else { '' }
        $esc = if ($State.BackQuits) { 'Esc やめる' } else { 'Esc 戻る' }
        $help = Format-Line @(New-Seg "Space 切り替え  a 足す  e 直す  d 消す  Enter つなぐ  $esc" 'Dim') $w
    }

    $rows = @($State.Rows)
    $body = [System.Collections.Generic.List[string]]::new()
    if ($rows.Count -eq 0) {
        $body.Add((Format-Line @(New-Seg '  組がありません。a で足す' 'Dim') $w))
    } else {
        $visible = [Math]::Max(1, $Height - $top.Count - $notes.Count - 3)
        Set-ScrollOffset -State $State -Count $rows.Count -Visible $visible
        $portWidth = ($rows | ForEach-Object { "$($_.LocalPort)".Length } | Measure-Object -Maximum).Maximum
        $targetWidth = ($rows | ForEach-Object { Get-DisplayWidth "$($_.RemoteHost):$($_.RemotePort)" } | Measure-Object -Maximum).Maximum
        $tags = @{}
        foreach ($row in $rows) {
            $t = @()
            if ($State.Busy.Contains($row.LocalPort)) { $t += New-Seg '  使用中' 'Yellow' }
            if ($row.Source -ne 'shared') { $t += New-Seg '  この PC' 'Cyan' }
            $tags[$row.LocalPort] = $t
        }
        $tagWidth = ($rows | ForEach-Object { ($tags[$_.LocalPort] | ForEach-Object { Get-DisplayWidth $_.Text } | Measure-Object -Sum).Sum } | Measure-Object -Maximum).Maximum
        $memoLongest = ($rows | ForEach-Object { Get-DisplayWidth $_.Memo } | Measure-Object -Maximum).Maximum
        $memoWidth = [Math]::Min([int]$memoLongest, [Math]::Max(4, $w - (2 + 4 + $portWidth + 3 + $targetWidth + 2) - [int]$tagWidth))
        $end = [Math]::Min($rows.Count, $State.Offset + $visible)
        for ($i = $State.Offset; $i -lt $end; $i++) {
            $row = $rows[$i]
            $selected = $i -eq $State.Cursor
            $check = if ($State.Checked.Contains($row.LocalPort)) { '[x] ' } else { '[ ] ' }
            $segs = @(
                (New-Seg $(if ($selected) { '> ' } else { '  ' }))
                (New-Seg $check)
                (New-Seg (Format-Cell "$($row.LocalPort)" $portWidth))
                (New-Seg ' → ')
                (New-Seg (Format-Cell "$($row.RemoteHost):$($row.RemotePort)" $targetWidth))
            )
            if ($memoWidth -gt 0) { $segs += New-Seg ('  ' + (Format-Cell $row.Memo $memoWidth)) }
            $segs += $tags[$row.LocalPort]
            $body.Add((Format-Line $segs $w -Selected:$selected))
        }
    }
    $lines = @($top) + @($body) + @($notes) + @($rule, $message, $help)
    New-Frame -Lines $lines -Height $Height -CursorX $x -CursorY $(if ($null -ne $x) { $lines.Count - 2 } else { $null })
}

# ---------------------------------------------------------------------------
# 外側 (キーを読む・描く・ファイルに書く・ssh を動かす。tmux の中の pwsh で確かめる)
# ---------------------------------------------------------------------------

# JSON のファイルを読む (BOM はあってもよい)。空なら $null
function Read-JsonFile {
    param([string]$Path)
    $text = [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false))
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    ConvertFrom-Json -InputObject $text -AsHashtable -NoEnumerate -ErrorAction Stop
}

# 共有の組 (hosts.json) を読む。無ければ空、読めなければ Warning に理由を入れて空 (pf は止めない)
function Read-SharedPort {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return ConvertTo-SharedPort $null }
    try {
        $object = Read-JsonFile $Path
    } catch {
        $reason = ($_.Exception.Message -split "`n")[0]
        return [pscustomobject]@{ Hosts = [ordered]@{}; Warning = "hosts.json が読めません ($reason)。共有の組なしで出します" }
    }
    ConvertTo-SharedPort $object
}

# 手元の組 (local.json) を読む。無ければ空の store。読めない・形が違うときは throw する (上書きして消さないため)
function Read-LocalStore {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return New-LocalStore }
    try {
        $object = Read-JsonFile $Path
    } catch {
        throw "local.json が読めません ($Path): $(($_.Exception.Message -split "`n")[0])"
    }
    try {
        ConvertTo-LocalStore $object
    } catch {
        throw "$($_.Exception.Message) ($Path)"
    }
}

# 手元の組を書く。同じ場所の一時ファイルに書いてから置き換える (UTF-8・BOM なし)。
# 書く前に Read-LocalStore で読み直して 1 か所だけ変えるのは呼ぶ側 (別の窓の pf の変更を消さないため)
function Write-LocalStore {
    param([string]$Path, $Store)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $json = ConvertTo-Json -InputObject $Store -Depth 10
    $tmp = "$Path.tmp-$PID"
    [System.IO.File]::WriteAllText($tmp, $json + "`n", [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::Move($tmp, $Path, $true)
}

# ssh の実行ファイルのパス (PATH から引く。同じ名前の関数・alias は使わない)。無ければ $null
function Resolve-SshPath {
    param([string]$Ssh)
    $command = Get-Command -Name $Ssh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command) { $command.Source } else { $null }
}

# ssh -G <Host> (接続はしない) で、ssh の設定の LocalForward・DynamicForward の手元の port を読む。ssh が無い・落ちた・
# 5 秒で終わらないときは何も返さない (設定の転送は無いものとして進む)
function Read-ConfigForward {
    param([string]$Ssh, [string]$HostName)
    try {
        $path = Resolve-SshPath $Ssh
        if ($null -eq $path) { return }
        $info = [System.Diagnostics.ProcessStartInfo]::new($path)
        $info.ArgumentList.Add('-G')
        $info.ArgumentList.Add($HostName)
        $info.UseShellExecute = $false
        $info.RedirectStandardInput = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $process = [System.Diagnostics.Process]::Start($info)
        $process.StandardInput.Close()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $null = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(5000)) {
            try { $process.Kill($true) } catch { }
            return
        }
        # ssh -G の子 (Match exec で起こしたもの) が stdout を握ったままでも、待ち続けない
        if ($process.ExitCode -ne 0 -or -not $stdout.Wait(1000)) { return }
        Get-ConfigForwardPort -Lines ($stdout.Result -split "`r?`n")
    } catch {
        return
    }
}

# 手元で待ち受けている TCP の port (どのアドレスでも)。読めなければ何も返さない
function Get-ListeningPort {
    try {
        [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() | ForEach-Object { $_.Port }
    } catch {
        return
    }
}

# port の画面の使用中を読み直す (行の port と、ssh の設定の転送の port)
function Update-BusyPort {
    param($State)
    $ports = @($State.Rows | ForEach-Object { $_.LocalPort }) + @($State.ConfigPorts)
    $busy = @(Get-BusyPort -Ports $ports -Listening @(Get-ListeningPort))
    $State.Busy.Clear()
    foreach ($p in $busy) { [void]$State.Busy.Add($p) }
}

function Get-WindowSize {
    $width = 80
    $height = 24
    try {
        $width = [Console]::WindowWidth
        $height = [Console]::WindowHeight
    } catch { }
    if ($width -le 0) { $width = 80 }
    if ($height -le 0) { $height = 24 }
    [pscustomobject]@{ Width = $width; Height = $height }
}

# 代替の画面に移り (元の画面の出力を消さない)、Ctrl+C をキーとして受ける。戻すのは Exit-Screen。
# 画面は [Console]::Write で描く。Windows の .NET はこれを console のコードページ (en-US なら 437、ja-JP なら 932) の
# バイトにして書くので、日本語や › が ? になる。画面の間だけ出力を UTF-8 にする (Write-Host は Unicode で書くので要らない)
function Enter-Screen {
    $saved = [pscustomobject]@{ TreatControlCAsInput = $false; OutputEncoding = $null }
    try {
        $saved.TreatControlCAsInput = [Console]::TreatControlCAsInput
        [Console]::TreatControlCAsInput = $true
    } catch { }
    try {
        $saved.OutputEncoding = [Console]::OutputEncoding
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    } catch { }
    [Console]::Write("`e[?1049h`e[H`e[2J")
    $saved
}

function Exit-Screen {
    param($Saved)
    [Console]::Write("`e[0m`e[?25h`e[?1049l")
    if ($null -ne $Saved.OutputEncoding) {
        try { [Console]::OutputEncoding = $Saved.OutputEncoding } catch { }
    }
    try { [Console]::TreatControlCAsInput = $Saved.TreatControlCAsInput } catch { }
}

# 描いた画面を出す。頭から行ごとに書いて行末を消し、残りの下を消す。文字を打つ画面ではカーソルを出す
function Show-Frame {
    param($Frame)
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append("`e[?25l`e[H")
    for ($i = 0; $i -lt $Frame.Lines.Count; $i++) {
        if ($i -gt 0) { [void]$sb.Append("`r`n") }
        [void]$sb.Append($Frame.Lines[$i]).Append("`e[K")
    }
    [void]$sb.Append("`e[J")
    if ($null -ne $Frame.CursorY) { [void]$sb.Append("`e[$($Frame.CursorY + 1);$($Frame.CursorX + 1)H`e[?25h") }
    [Console]::Write($sb.ToString())
}

# Host を選ぶ画面を回す。決めた Host の名前を返す (やめたら $null)。状態は呼ぶ側が持ち、戻ってきたときに続きから出す
function Invoke-HostScreen {
    param($State)
    while ($true) {
        $size = Get-WindowSize
        Show-Frame (Format-HostScreen -State $State -Width $size.Width -Height $size.Height)
        $r = Step-HostScreen $State ([Console]::ReadKey($true))
        if ($r -eq 'quit') { return $null }
        if ($r -eq 'select') { return $State.Shown[$State.Cursor].Name }
    }
}

# port を選ぶ画面を回す。返りの Kind は back・quit・connect (Rows がつなぐ行)。
# 組を変えたら local.json を読み直して 1 か所だけ変えて書き、つなぐときは前回の選択と最近の Host を書く
function Invoke-PortScreen {
    param([string]$HostName, [string[]]$Shared, [string]$LocalPath, [string]$Warning, [int[]]$ConfigPorts, [switch]$BackQuits)
    $entry = Get-HostEntry -Store (Read-LocalStore $LocalPath) -HostName $HostName
    $state = New-PortScreen -HostName $HostName -Rows @(Merge-PortRow -Shared $Shared -Entry $entry) `
        -Hidden @(Get-HiddenPort -Shared $Shared -Entry $entry) -Entry $entry -BackQuits:$BackQuits
    $state.Warning = $Warning
    $state.ConfigPorts = [int[]]@($ConfigPorts)
    Update-BusyPort $state
    while ($true) {
        $size = Get-WindowSize
        Show-Frame (Format-PortScreen -State $state -Width $size.Width -Height $size.Height)
        $key = [Console]::ReadKey($true)
        Update-BusyPort $state
        $action = Step-PortScreen $state $key
        if ($action.Kind -eq 'back' -or $action.Kind -eq 'quit') { return $action }
        if ($action.Kind -eq 'set' -or $action.Kind -eq 'delete') {
            $store = Read-LocalStore $LocalPath
            if ($action.Kind -eq 'set') {
                Set-PortSpec -Store $store -HostName $HostName -Shared $Shared -OldPort $action.OldPort -Row $action.Row
            } else {
                Remove-PortSpec -Store $store -HostName $HostName -Shared $Shared -Port $action.Port
            }
            Write-LocalStore $LocalPath $store
            $entry = Get-HostEntry -Store $store -HostName $HostName
            Update-PortRow -State $state -Rows @(Merge-PortRow -Shared $Shared -Entry $entry) -Hidden @(Get-HiddenPort -Shared $Shared -Entry $entry) -Action $action
            Update-BusyPort $state
        } elseif ($action.Kind -eq 'connect') {
            $rows = @($state.Rows | Where-Object { $state.Checked.Contains($_.LocalPort) })
            $store = Read-LocalStore $LocalPath
            Register-Connection -Store $store -HostName $HostName -Ports @($rows | ForEach-Object { $_.LocalPort })
            Write-LocalStore $LocalPath $store
            return [pscustomobject]@{ Kind = 'connect'; Rows = $rows }
        }
    }
}

# ssh を、いまの PowerShell の中で動かす。タブの名前を pf: <Host> にし、終わったら (Ctrl+C で止めたときも) 戻す。
# 標準入出力は奪わずに渡す (パスフレーズを打てる。stdout をパイプにすると、それを握る子が残る間 pf が終わらない)。
# 返りは ssh が自分で終わったときの終了コード。Ctrl+C では ssh も PowerShell も止まり、finally だけが走る
# (そのとき ssh が残っていれば止める)
function Invoke-Ssh {
    param([string]$SshPath, [string[]]$Arguments, [string]$HostName)
    $info = [System.Diagnostics.ProcessStartInfo]::new($SshPath)
    foreach ($a in $Arguments) { $info.ArgumentList.Add($a) }
    $info.UseShellExecute = $false
    $title = $null
    try { $title = $Host.UI.RawUI.WindowTitle } catch { }
    $process = $null
    try {
        try { $Host.UI.RawUI.WindowTitle = "pf: $HostName" } catch { }
        $process = [System.Diagnostics.Process]::Start($info)
        # 短い間隔で待つ (PowerShell は文の切れ目でしか Ctrl+C の止めを受けない)
        while (-not $process.WaitForExit(200)) { }
        $code = $process.ExitCode
        Write-Host "pf: ssh が終わった (終了コード $code)"
        $code
    } finally {
        if ($null -ne $process -and -not $process.HasExited) {
            try { $process.Kill() } catch { }
        }
        if ($null -ne $title) {
            try { $Host.UI.RawUI.WindowTitle = $title } catch { }
        }
    }
}

# pf の本体。返りは終了コード (ssh の終了コード。画面でやめたら 0、始められなければ 1)
function Invoke-PortForward {
    param([string]$HostName, [string]$HomeDir, [string]$Ssh)
    $dataDir = Join-Path $HomeDir '.config' 'port-forward'
    $localPath = Join-Path $dataDir 'local.json'
    try {
        $store = Read-LocalStore $localPath
    } catch {
        Write-Host "pf: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host 'pf: 直すか消してから打ち直してください (この PC で足した組・前回の選択が入っています)'
        return 1
    }
    $sshPath = Resolve-SshPath $Ssh
    if ($null -eq $sshPath) {
        Write-Host "pf: ssh が見つかりません ($Ssh)。Windows の OpenSSH が入っているか (Install-OpenSSH -Check)、PATH を確かめてください" -ForegroundColor Red
        return 1
    }
    $configHosts = @(Get-SshConfigHost -HomeDir $HomeDir)
    if ($configHosts.Count -eq 0) {
        Write-Host "pf: ssh の設定に Host がありません ($(Join-Path $HomeDir '.ssh' 'config'))" -ForegroundColor Red
        return 1
    }
    $shared = Read-SharedPort (Join-Path $dataDir 'hosts.json')

    # pf <Host>: 一覧のどれかと同じなら Host の画面を飛ばし (Esc でやめる)、違えば絞り込みに入れて開く
    $selected = $null
    $query = ''
    if ($HostName) {
        $selected = $configHosts | Where-Object { $_ -eq $HostName } | Select-Object -First 1
        if (-not $selected) { $query = $HostName }
    }
    $backQuits = [bool]$selected
    $hostState = New-HostScreen -Items @(Get-HostItem -ConfigHosts $configHosts -Store $store) -Query $query

    $result = $null
    $saved = Enter-Screen
    try {
        while ($true) {
            if (-not $selected) {
                $selected = Invoke-HostScreen $hostState
                if (-not $selected) { return 0 }
            }
            $result = Invoke-PortScreen -HostName $selected -Shared @(Get-SharedSpecList -Hosts $shared.Hosts -HostName $selected) `
                -LocalPath $localPath -Warning $shared.Warning -ConfigPorts @(Read-ConfigForward -Ssh $Ssh -HostName $selected) -BackQuits:$backQuits
            if ($result.Kind -eq 'quit') { return 0 }
            if ($result.Kind -eq 'connect') { break }
            $selected = $null
        }
    } finally {
        Exit-Screen $saved
    }

    $arguments = @(Get-SshArgumentList -HostName $selected -Rows $result.Rows)
    Write-Host (Format-CommandLine -Ssh $Ssh -Arguments $arguments)
    Invoke-Ssh -SshPath $sshPath -Arguments $arguments -HostName $selected
}

# dot-source されたとき (テスト) は関数だけを読み、本体は走らせない。
# 終了コードは Invoke-PortForward の最後の返り。思わぬ例外は受け止めて終了コード 2 で終える
# (画面は Invoke-PortForward の finally で戻している)
if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest
    try {
        $code = @(Invoke-PortForward -HostName (@($HostName) -join ' ') -HomeDir $HomeDir -Ssh $Ssh)[-1]
        exit [int]$code
    } catch {
        Write-Host "pf: エラーで止まった: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace
        exit 2
    }
}
