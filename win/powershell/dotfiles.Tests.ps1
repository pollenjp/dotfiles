# win/powershell/dotfiles.ps1 の runner の関数 (dotfiles・ConvertTo-DotfilesRunnerArgs) と、略語の展開 (略語の表・判定の関数・
# PSReadLine の割り当て) と、bash に似たキーの PSReadLine の割り当てのテスト。Pester は使わない。
# dotfiles 関数は cargo を打つので、HOME を一時ディレクトリにした子の pwsh で、cargo を関数の偽物に替えて流す (本物の cargo も
# ホームの clone も触らない)。略語と bash に似たキーの割り当ても子の pwsh で確かめる (このテストの PowerShell の PSReadLine には触らない)。
#
# WSL から流す (Linux の pwsh で動かすので、Windows 側には触らない):
#   nix shell nixpkgs#powershell -c pwsh -NoProfile -File win/powershell/dotfiles.Tests.ps1
#
# ## 確かめること
#
#   - PowerShell が配列にした `--steps files,ntn` (`--steps=files,ntn` も) を、runner には , でつないだ 1 つの引数で渡す
#   - dotfiles は win/runner に入って cargo run --quiet --release --locked -- <引数> を打ち、終わったら元の場所に戻る
#   - clone に runner が無ければ、知らせて $LASTEXITCODE を 2 にする (cargo は打たない)
#   - 略語は、カーソルの直前で終わる語がコマンドの位置 (行頭・| ; && || の後・( $( @( { の中・= の右・2 行目・文字列の中の $( ))
#     にあり、表にあるときだけ広げる。引数・パラメーター・引用符の中・& と . の後・長い語・長い略語の途中・大文字小文字の違い・
#     ` を挟んだ語・変数・コメント・--% の後・function の名前・ハッシュテーブルのキー・switch の節・enum と class のメンバー・
#     リダイレクトの先・カーソルが語の後ろの空白の後や後ろの語の上・カーソルが行の外・空の行では広げない
#   - 中身の頭がキーワードの略語 (e の exit) は、広げた後もキーワードとして読まれる所 (文の頭) でだけ広げ、| && || の後と ( の中
#     (exit がコマンドの名前として読まれる) では広げない
#   - 略語の表は大文字小文字を区別し、中身は e・h・hss … c・cs の function・alias と同じ (function は「表の中身 @args」、h は alias の先、
#     e は exit)。1 つのコマンドに @args を渡すだけの function はどれも表にある
#   - PSReadLine を読み込んでいない PowerShell (script・CI) で読んでも PSReadLine を読み込まない。読み込んだ PowerShell では、
#     Space ; | & ) を「広げてから字を入れる」、Enter を「広げてから実行する」、Ctrl+Spacebar・Ctrl+@・Shift+Spacebar を「広げずに空白を
#     入れる」に割り当て (Shift+Spacebar は Spacebar と別のキー)、> と < には割り当てない
#   - Windows の既定の EditMode (Windows) で読むと、Alt+f・Alt+b・Ctrl+w・Alt+d を ForwardWord・BackwardWord・UnixWordRubout・KillWord に
#     割り当て (4 つの既定の割り当てを外してから読んでも)、EditMode は Windows のまま、WordDelimiters は替えない
#
# BOM 付きの UTF-8 で保存すること (win/README.md の「dotfiles.ps1 を書くときの注意」)。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$dotfiles = Join-Path $PSScriptRoot 'dotfiles.ps1'
. $dotfiles

$script:Failures = 0

# Actual の scriptblock を走らせ、文字列にして Expected と比べる (今の win/*/*.Tests.ps1 と同じ形)
function Test-Case {
    param([string]$Name, $Expected, [scriptblock]$Actual)
    try {
        $got = & $Actual
    } catch {
        $got = "ERROR: $($_.Exception.Message)"
    }
    $e = @($Expected | ForEach-Object { "$_" }) -join ' '
    $a = @($got | ForEach-Object { "$_" }) -join ' '
    if ([string]::Equals($e, $a, [System.StringComparison]::Ordinal)) {
        Write-Host "ok   $Name"
    } else {
        Write-Host "FAIL $Name"
        Write-Host "     expected: [$e]"
        Write-Host "     actual:   [$a]"
        $script:Failures++
    }
}

Test-Case '配列は , でつなぐ' 'check|--steps|files,ntn' { (ConvertTo-DotfilesRunnerArgs -Arguments @('check', '--steps', @('files', 'ntn'))) -join '|' }
Test-Case '--steps= の形の配列も , でつなぐ' 'check|--steps=files,ntn' { (ConvertTo-DotfilesRunnerArgs -Arguments @('check', @('--steps=files', 'ntn'))) -join '|' }
Test-Case '配列でない引数はそのまま' 'apply|--dry-run' { (ConvertTo-DotfilesRunnerArgs -Arguments @('apply', '--dry-run')) -join '|' }
Test-Case '引数が無ければ何も渡さない' 0 { @(ConvertTo-DotfilesRunnerArgs -Arguments @()).Count }

# HOME を一時ディレクトリにした子の pwsh で dotfiles を打つ。cargo は打たれた場所と引数を出す偽物の関数
function Invoke-Child {
    param([string]$TempHome, [string]$Command)
    $child = Join-Path $TempHome 'child.ps1'
    $body = @(
        'param([string]$Dotfiles)'
        '. $Dotfiles'
        'function cargo { "cwd=$((Get-Location).Path)"; "args=$($args -join ''|'')" }'
        "Set-Location -LiteralPath `$HOME"
        $Command
        '"after=$((Get-Location).Path)"'
        '"code=$LASTEXITCODE"'
    ) -join "`n"
    Set-Content -LiteralPath $child -Value $body -Encoding utf8
    $saved = @{ HOME = $env:HOME; USERPROFILE = $env:USERPROFILE }
    try {
        $env:HOME = $TempHome
        $env:USERPROFILE = $TempHome
        $pwsh = (Get-Process -Id $PID).Path
        & $pwsh -NoProfile -NonInteractive -File $child -Dotfiles $dotfiles 2>&1 | ForEach-Object { "$_" }
    } finally {
        $env:HOME = $saved.HOME
        $env:USERPROFILE = $saved.USERPROFILE
    }
}

$withRunner = Join-Path ([IO.Path]::GetTempPath()) ("dotfiles-tests-" + [Guid]::NewGuid())
$runnerDir = [IO.Path]::Combine($withRunner, 'ghq', 'github.com', 'pollenjp', 'dotfiles', 'win', 'runner')
$null = New-Item -ItemType Directory -Force -Path $runnerDir
Set-Content -LiteralPath (Join-Path $runnerDir 'Cargo.toml') -Value '' -Encoding utf8
$withoutRunner = Join-Path ([IO.Path]::GetTempPath()) ("dotfiles-tests-" + [Guid]::NewGuid())
$null = New-Item -ItemType Directory -Force -Path $withoutRunner
try {
    $out = @(Invoke-Child -TempHome $withRunner -Command 'dotfiles check --steps files,ntn')
    Test-Case 'win/runner に入って cargo を打つ' "cwd=$runnerDir" { $out | Where-Object { $_ -like 'cwd=*' } }
    Test-Case 'cargo run --quiet --release --locked -- に引数を , でつないで渡す' 'args=run|--quiet|--release|--locked|--|check|--steps|files,ntn' { $out | Where-Object { $_ -like 'args=*' } }
    Test-Case '終わったら元の場所に戻る' "after=$withRunner" { $out | Where-Object { $_ -like 'after=*' } }

    $out = @(Invoke-Child -TempHome $withRunner -Command 'dotfiles check --steps=files,ntn')
    Test-Case '--steps= の形も 1 つの引数で渡す' 'args=run|--quiet|--release|--locked|--|check|--steps=files,ntn' { $out | Where-Object { $_ -like 'args=*' } }

    $out = @(Invoke-Child -TempHome $withoutRunner -Command 'dotfiles check')
    Test-Case 'runner が無ければ cargo を打たない' 0 { @($out | Where-Object { $_ -like 'args=*' }).Count }
    Test-Case 'runner が無ければ知らせる' $true { [bool]($out | Where-Object { $_ -like '*dotfiles の runner がありません*' }) }
    Test-Case 'runner が無ければ $LASTEXITCODE は 2' 'code=2' { $out | Where-Object { $_ -like 'code=*' } }
} finally {
    Remove-Item -LiteralPath $withRunner -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $withoutRunner -Recurse -Force -ErrorAction SilentlyContinue
}

# 略語の判定 (Get-DotfilesAbbrExpansion) のテストの表。本物の表 ($DotfilesAbbr) とは別にし、本物の中身を変えても判定のテストは
# 変わらないようにする。H と h は大文字小文字だけが違う略語 (fish.nix の abbr にも H と h がある)
$abbr = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
$abbr.Add('hr', 'herdr --remote')
$abbr.Add('hss', 'herdr --session')
$abbr.Add('h', 'herdr')
$abbr.Add('H', 'head')
$abbr.Add('e', 'exit')
$abbr.Add('c', 'claude')

# 行 $Line とカーソル $Cursor (省けば行末) で判定し、「置き換える位置+長さ=中身」の字にする (広げないなら「なし」)
function Format-AbbrExpansion {
    param([string]$Line, [int]$Cursor = -1, $Table = $abbr)
    if ($Cursor -lt 0) { $Cursor = $Line.Length }
    $x = Get-DotfilesAbbrExpansion -Line $Line -Cursor $Cursor -Table $Table
    if ($null -eq $x) { 'なし' } else { '{0}+{1}={2}' -f $x.Start, $x.Length, $x.Text }
}

# コマンドの位置で、表にあれば広げる
$hr = 'herdr --remote'
Test-Case '略語: 行頭' "0+2=$hr" { Format-AbbrExpansion 'hr' }
Test-Case '略語: 先頭の空白の後' "2+2=$hr" { Format-AbbrExpansion '  hr' }
Test-Case '略語: | の後' "16+2=$hr" { Format-AbbrExpansion 'Get-ChildItem | hr' }
Test-Case '略語: ; の後' "4+2=$hr" { Format-AbbrExpansion 'ls; hr' }
if ($PSVersionTable.PSVersion.Major -ge 7) {
    Test-Case '略語: && の後' "6+2=$hr" { Format-AbbrExpansion 'ls && hr' }
    Test-Case '略語: || の後' "6+2=$hr" { Format-AbbrExpansion 'ls || hr' }
} else {
    Write-Host 'skip 略語: && と || の後 (PowerShell 7 からの書き方)'
}
Test-Case '略語: 閉じていない { の中' "13+2=$hr" { Format-AbbrExpansion 'if ($true) { hr' }
Test-Case '略語: 閉じていない $( の中' "2+2=$hr" { Format-AbbrExpansion '$(hr' }
Test-Case '略語: 閉じていない @( の中' "2+2=$hr" { Format-AbbrExpansion '@(hr' }
Test-Case '略語: 閉じていない ( の中' "1+2=$hr" { Format-AbbrExpansion '(hr' }
Test-Case '略語: 引数の ( の中' "10+2=$hr" { Format-AbbrExpansion 'ls -Path (hr' }
Test-Case '略語: 型の変換の後の ( の中' "7+2=$hr" { Format-AbbrExpansion '[void](hr' }
Test-Case '略語: 代入の右' "5+2=$hr" { Format-AbbrExpansion '$x = hr' }
Test-Case '略語: 2 行目' "3+2=$hr" { Format-AbbrExpansion "ls`nhr" }
Test-Case '略語: ForEach-Object の { の中' "9+2=$hr" { Format-AbbrExpansion 'ls | % { hr' }
Test-Case '略語: foreach の本体' "23+2=$hr" { Format-AbbrExpansion 'foreach ($i in 1..2) { hr' }
Test-Case '略語: function の本体' "13+2=$hr" { Format-AbbrExpansion 'function f { hr' }
Test-Case '略語: 文字列の中の $( の中 (構文ではコマンドの位置)' "3+2=$hr" { Format-AbbrExpansion '"$(hr' }
Test-Case '略語: カーソルが語の直後なら、後ろに語があっても広げる' "0+2=$hr" { Format-AbbrExpansion 'hr foo' -Cursor 2 }
Test-Case '略語: | の後の別の略語' '7+3=herdr --session' { Format-AbbrExpansion '1..3 | hss' }
Test-Case '略語: 1 字の略語 (c)' '0+1=claude' { Format-AbbrExpansion 'c' }
Test-Case '略語: 1 字の略語 (e)' '0+1=exit' { Format-AbbrExpansion 'e' }
Test-Case '略語: 1 字の略語 (h)' '0+1=herdr' { Format-AbbrExpansion 'h' }
Test-Case '略語: 大文字小文字だけが違う略語 (H) は別に引く' '0+1=head' { Format-AbbrExpansion 'H' }

# コマンドの位置でない・表に無いなら広げない
Test-Case '略語: 引数では広げない' 'なし' { Format-AbbrExpansion 'git hr' }
Test-Case '略語: 語の後の引数では広げない' 'なし' { Format-AbbrExpansion 'x hr' }
Test-Case '略語: パラメーターの形では広げない' 'なし' { Format-AbbrExpansion 'foo -hr' }
Test-Case '略語: 一重引用符の中では広げない' 'なし' { Format-AbbrExpansion "'hr'" }
Test-Case '略語: 二重引用符の中では広げない' 'なし' { Format-AbbrExpansion '"hr"' }
Test-Case '略語: & の後では広げない' 'なし' { Format-AbbrExpansion '& hr' }
Test-Case '略語: . の後では広げない' 'なし' { Format-AbbrExpansion '. hr' }
Test-Case '略語: 長い語では広げない' 'なし' { Format-AbbrExpansion 'hrx' }
Test-Case '略語: 長い語の途中 (hrx の hr まで) では広げない' 'なし' { Format-AbbrExpansion 'hrx' -Cursor 2 }
Test-Case '略語: 長い略語の途中 (hss の h まで) では広げない' 'なし' { Format-AbbrExpansion 'hss' -Cursor 1 }
Test-Case '略語: 大文字小文字が違えば広げない (HR)' 'なし' { Format-AbbrExpansion 'HR' }
Test-Case '略語: 大文字小文字が違えば広げない (Hr)' 'なし' { Format-AbbrExpansion 'Hr' }
Test-Case '略語: ` を挟んだ語では広げない (打った字のまま表と比べる。`hss の値は hss)' 'なし' { Format-AbbrExpansion '`hss' }
Test-Case '略語: 空の行では広げない' 'なし' { Format-AbbrExpansion '' }
Test-Case '略語: カーソルが行の外 (行の長さより後) なら広げない' 'なし' { Format-AbbrExpansion 'hr' -Cursor 3 }
Test-Case '略語: 変数では広げない' 'なし' { Format-AbbrExpansion 'echo $hr' }
Test-Case '略語: コメントでは広げない' 'なし' { Format-AbbrExpansion '# hr' }
Test-Case '略語: カーソルが語の後ろの空白の後なら広げない' 'なし' { Format-AbbrExpansion 'hr ' }
Test-Case '略語: カーソルが後ろの語の上なら広げない' 'なし' { Format-AbbrExpansion 'hr foo' -Cursor 6 }
Test-Case '略語: --% の後では広げない' 'なし' { Format-AbbrExpansion 'cmd --% hr' }
Test-Case '略語: function の名前では広げない' 'なし' { Format-AbbrExpansion 'function hr' }
Test-Case '略語: ハッシュテーブルのキーでは広げない' 'なし' { Format-AbbrExpansion '@{ c' }
Test-Case '略語: ハッシュテーブルの 2 つ目のキーでは広げない' 'なし' { Format-AbbrExpansion '@{ c = 1; e' }
Test-Case '略語: switch の節では広げない' 'なし' { Format-AbbrExpansion 'switch ($x) { e' }
Test-Case '略語: enum のメンバーでは広げない' 'なし' { Format-AbbrExpansion 'enum E { e' }
Test-Case '略語: class のプロパティでは広げない' 'なし' { Format-AbbrExpansion 'class X { [int] c' }
Test-Case '略語: リダイレクトの先では広げない' 'なし' { Format-AbbrExpansion 'ls > hr' }

# 中身の頭がキーワード (e の exit) の略語は、広げた後の行でもキーワードとして読まれる所 (文の頭) でだけ広げる。| の後と ( の中
# (7 では && || の後も) では exit がコマンドの名前として読まれ、exit というコマンドは無いので落ちる (function の e なら抜ける)
Test-Case '略語: ; の後の e は広げる (exit は文の頭)' '4+1=exit' { Format-AbbrExpansion 'ls; e' }
Test-Case '略語: 代入の右の e は広げる' '5+1=exit' { Format-AbbrExpansion '$x = e' }
Test-Case '略語: 閉じていない $( の中の e は広げる' '2+1=exit' { Format-AbbrExpansion '$(e' }
Test-Case '略語: 閉じていない @( の中の e は広げる' '2+1=exit' { Format-AbbrExpansion '@(e' }
Test-Case '略語: 閉じていない { の中の e は広げる' '13+1=exit' { Format-AbbrExpansion 'if ($true) { e' }
Test-Case '略語: | の後の e は広げない (exit がコマンドの名前になる)' 'なし' { Format-AbbrExpansion 'ls | e' }
Test-Case '略語: 閉じていない ( の中の e は広げない' 'なし' { Format-AbbrExpansion '(e' }
Test-Case '略語: 文字列の中の $( の | の後の e は広げない' 'なし' { Format-AbbrExpansion '"$(ls | e' }
if ($PSVersionTable.PSVersion.Major -ge 7) {
    Test-Case '略語: && の後の e は広げない' 'なし' { Format-AbbrExpansion 'ls && e' }
    Test-Case '略語: || の後の e は広げない' 'なし' { Format-AbbrExpansion 'ls || e' }
} else {
    Write-Host 'skip 略語: && と || の後の e (PowerShell 7 からの書き方)'
}

# 本物の表は大文字小文字を区別する (fish.nix の H と h のように、大文字小文字だけが違う略語を別に持てる。区別しない表 (@{} など) では
# hr があると HR もあることになり、H と h を両方は足せない)
Test-Case '略語: 本物の表は大文字小文字を区別する (HR は hr と別の名前)' $false { $DotfilesAbbr.ContainsKey('HR') }

# 本物の表と、e・h・hss … c・cs の function・alias が食い違わない (広げてから打っても、略語のまま打っても、同じ中身が動く)。
# ループの変数を $name にしない (Test-Case の中で Actual を流すと、$name は Test-Case の引数 $Name を指す)
foreach ($abbrName in @($DotfilesAbbr.Keys)) {
    $text = $DotfilesAbbr[$abbrName]
    switch -CaseSensitive ($abbrName) {
        'e' { Test-Case '略語の表: e は function e の中身' $text { (Get-Command -Name e -CommandType Function).ScriptBlock.ToString().Trim() } }
        'h' { Test-Case '略語の表: h は alias h の先' $text { (Get-Alias -Name h).Definition } }
        default { Test-Case "略語の表: function $abbrName の中身は「表の中身 @args」" "$text @args" { (Get-Command -Name $abbrName -CommandType Function).ScriptBlock.ToString().Trim() } }
    }
}
# 1 つのコマンドに @args を渡すだけの function (& で script を呼ぶ Install-* などを除く) は、どれも表にある (略語を足すときに表を忘れない)
Test-Case '略語の表: @args を渡すだけの function はどれも表にある' '' {
    @(Get-Command -CommandType Function | Where-Object {
            $_.ScriptBlock.File -eq $dotfiles -and $_.Definition.Trim() -match '^[^&\s][^\r\n]* @args$' -and -not $DotfilesAbbr.ContainsKey($_.Name)
        } | ForEach-Object Name) -join ' '
}

# 子の pwsh で $Body を流す ($Dotfiles に dotfiles.ps1 のパスが入る)。このテストの PowerShell の PSReadLine には触らない
function Invoke-AbbrChild {
    param([string]$Body)
    $dir = Join-Path ([IO.Path]::GetTempPath()) ("dotfiles-tests-" + [Guid]::NewGuid())
    $null = New-Item -ItemType Directory -Force -Path $dir
    try {
        $child = Join-Path $dir 'child.ps1'
        Set-Content -LiteralPath $child -Value "param([string]`$Dotfiles)`n$Body" -Encoding utf8
        $pwsh = (Get-Process -Id $PID).Path
        & $pwsh -NoProfile -NonInteractive -File $child -Dotfiles $dotfiles 2>&1 | ForEach-Object { "$_" }
    } finally {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# script・CI のように PSReadLine を読み込んでいない PowerShell で読んでも、PSReadLine を読み込まない (割り当てをしない)
Test-Case '略語の割り当て: PSReadLine を読み込んでいなければ、読み込まない' 'psreadline=False' {
    Invoke-AbbrChild -Body ". `$Dotfiles`n`"psreadline=`$([bool](Get-Module -Name PSReadLine))`""
}

# PSReadLine を読み込んだ PowerShell では、広げるキー・実行するキー・広げずに空白を入れるキーを割り当てる (> と < には割り当てない)
$bound = @(Invoke-AbbrChild -Body @'
Import-Module PSReadLine
. $Dotfiles
Get-PSReadLineKeyHandler -Bound | Where-Object { $_.Function -like 'DotfilesAbbr*' } | ForEach-Object { "$($_.Key)=$($_.Function)" }
'@ | Sort-Object)
$wanted = @(
    'Spacebar=DotfilesAbbrExpandAndInsert'
    ';=DotfilesAbbrExpandAndInsert'
    '|=DotfilesAbbrExpandAndInsert'
    '&=DotfilesAbbrExpandAndInsert'
    ')=DotfilesAbbrExpandAndInsert'
    'Enter=DotfilesAbbrExpandAndAcceptLine'
    'Ctrl+Spacebar=DotfilesAbbrInsertSpace'
    'Ctrl+@=DotfilesAbbrInsertSpace'
    'Shift+Spacebar=DotfilesAbbrInsertSpace'
) | Sort-Object
Test-Case '略語の割り当て: Space ; | & ) Enter Ctrl+Spacebar Ctrl+@ Shift+Spacebar に割り当てる' $wanted { $bound }

# bash に似たキー: Windows の既定の EditMode (Windows) で読むと、Alt+f・Alt+b・Ctrl+w・Alt+d を bash の forward-word・backward-word・
# unix-word-rubout・kill-word に当たる関数に割り当てる。4 つとも外してから読み、PSReadLine の既定によらず dotfiles.ps1 が自分で割り当てることを
# 見る (Alt+d は今の Windows モードの既定でも KillWord)。EditMode (Emacs モードにすると Ctrl+a・Ctrl+v・Tab などほかのキーも替わる) と
# WordDelimiters (ほかのキーの語の区切りにも効く) は替えない。キーは大文字小文字を区別して選ぶ (Alt+F は Alt+Shift+f で別のキー)。
# 5.1 の PSReadLine 2.0.0 の Get-PSReadLineKeyHandler には -Chord が無い
$wordOut = @(Invoke-AbbrChild -Body @'
Import-Module PSReadLine
Set-PSReadLineOption -EditMode Windows
Remove-PSReadLineKeyHandler -Chord 'Alt+f', 'Alt+b', 'Ctrl+w', 'Alt+d'
$delimiters = (Get-PSReadLineOption).WordDelimiters
. $Dotfiles
"EditMode=$((Get-PSReadLineOption).EditMode)"
"WordDelimiters=$((Get-PSReadLineOption).WordDelimiters -ceq $delimiters)"
Get-PSReadLineKeyHandler -Bound | Where-Object { $_.Key -cin 'Alt+f', 'Alt+b', 'Ctrl+w', 'Alt+d' } | ForEach-Object { "$($_.Key)=$($_.Function)" }
'@)
$wantedWordKeys = @(
    'Alt+f=ForwardWord'
    'Alt+b=BackwardWord'
    'Ctrl+w=UnixWordRubout'
    'Alt+d=KillWord'
) | Sort-Object
Test-Case 'bash に似たキー: Alt+f Alt+b Ctrl+w Alt+d を ForwardWord BackwardWord UnixWordRubout KillWord に割り当てる' $wantedWordKeys { $wordOut | Where-Object { $_ -notmatch '^(EditMode|WordDelimiters)=' } | Sort-Object }
Test-Case 'bash に似たキー: EditMode は Windows のまま (Emacs モードにしない)' 'EditMode=Windows' { $wordOut | Where-Object { $_ -like 'EditMode=*' } }
Test-Case 'bash に似たキー: WordDelimiters は替えない' 'WordDelimiters=True' { $wordOut | Where-Object { $_ -like 'WordDelimiters=*' } }

if ($script:Failures -gt 0) {
    Write-Host "$($script:Failures) 件失敗"
    exit 1
}
Write-Host 'すべて通った'
