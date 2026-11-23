# win/powershell/dotfiles.ps1 の runner の関数 (dotfiles・ConvertTo-DotfilesRunnerArgs) と、略語の展開 (略語の表・判定の関数・
# PSReadLine の割り当て) と、Vi モード (EditMode・挿入モードの bash に似たキー・モードの印) のテスト。Pester は使わない。
# dotfiles 関数は cargo を打つので、HOME を一時ディレクトリにした子の pwsh で、cargo を関数の偽物に替えて流す (本物の cargo も
# ホームの clone も触らない)。略語と Vi モードの割り当ても子の pwsh で確かめる (このテストの PowerShell の PSReadLine には触らない)。
#
# WSL から流す (Linux の pwsh で動かすので、Windows 側には触らない。ghq と fzf も渡すと、cdrepo を本物の ghq・fzf でも流す):
#   nix shell nixpkgs#powershell nixpkgs#ghq nixpkgs#fzf -c pwsh -NoProfile -File win/powershell/dotfiles.Tests.ps1
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
#   - PSReadLine を読み込んでいない PowerShell (script・CI) で読んでも PSReadLine を読み込まない。読み込んだ PowerShell では EditMode を
#     Vi にし、挿入モードの Space ; | & ) を「広げてから字を入れる」、Enter を「広げてから実行する」、Ctrl+Spacebar・Ctrl+@・Shift+Spacebar を
#     「広げずに空白を入れる」に割り当て (Shift+Spacebar は Spacebar と別のキー)、> と < には割り当てない
#   - 挿入モードの Alt+f・Alt+b・Ctrl+w・Alt+d・Ctrl+a・Ctrl+e・Ctrl+k・Ctrl+u を ForwardWord・BackwardWord・UnixWordRubout・KillWord・
#     BeginningOfLine・EndOfLine・KillLine・BackwardKillInput (2.2.0 より前の PSReadLine は BackwardKillLine) に割り当てる。Vi の既定から
#     替わるのは、このキーと略語のキーだけ (コマンドモードは替えない)。WordDelimiters は替えない
#   - モードの印: コマンドモードに入るとカーソルをブロックに、挿入モードに入ると縦棒にする列を書く。端末に向いた PowerShell で読むと縦棒にし
#     (Linux で script の擬似端末の下で見る)、出力をパイプで受けるなら何も書かない。先に置かれた handler (starship の init) を包まず、
#     読み直しても handler は入れ子にならない
#   - cdrepo: ghq か fzf が無ければ、fish・bash の cdrepo と同じ文を出して $LASTEXITCODE を 1 にし、移らない (ghq が無ければ fzf も確かめない)。
#     ghq list を fzf に渡し、fzf には fish・bash の cdrepo と同じ引数 (-1 +m) を渡す。fzf が 0 で選んだ行を返したときだけ ghq root の下の
#     その repo へ移る (ghq list の / 区切りのまま)。fzf が 0 でない (選ばずに抜けた 130)・空を返した・ghq root が落ちたら移らない。
#     ghq と fzf を呼ぶ間だけ [Console]::OutputEncoding と global の $OutputEncoding を BOM の無い UTF-8 にし、終わったらどちらも元に戻す
#     (移らずに抜けるときも)。ghq と fzf が PATH にあれば、本物でも 1 回流す (ASCII でない名前の repo が 1 つの ghq の root で、
#     fzf -1 が選ぶ画面を出さずに返す形)
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

# cdrepo を子の pwsh で打つ。$Fakes は cdrepo の前に置く文 (偽の ghq・fzf の function)。PATH は $PathValue (省けば空のディレクトリ。
# 本物の ghq・fzf を見せない)。$GhqRoot があれば、子の環境変数 GHQ_ROOT にする (本物の ghq の root)。子は一時ディレクトリから
# cdrepo を打ち、移った先・$LASTEXITCODE・偽の fzf が受けた引数と入力と、呼ばれたときの文字コード・偽の ghq を呼んだ引数・cdrepo の前と後の
# [Console]::OutputEncoding と global の $OutputEncoding を出す。偽物の中の $Root は、repo を並べた一時の ghq の root ($CdrepoRoot。
# github.com/a/b と github.com/c/d がある)。$Latin1 なら、cdrepo の前に [Console]::OutputEncoding を ISO-8859-1 に、$OutputEncoding を ASCII に
# しておき、最後に戻す (Linux の pwsh の既定はどちらも UTF-8 で、戻したかが見分けられないため。Windows ではコンソールの文字コードが親と共有
# なので使わない)
function Invoke-CdrepoChild {
    param([string]$Fakes = '', [string]$PathValue = '', [string]$GhqRoot = '', [switch]$Latin1)
    if (-not $PathValue) { $PathValue = $cdrepoEmptyPath }
    $child = Join-Path $cdrepoDir 'child.ps1'
    $body = @(
        'param([string]$Dotfiles, [string]$Start, [string]$Root, [string]$PathValue, [string]$GhqRoot)'
        '. $Dotfiles'
        '$env:PATH = $PathValue'
        'if ($GhqRoot) { $env:GHQ_ROOT = $GhqRoot }'
        '$global:FzfArgs = $null'
        '$global:FzfInput = @()'
        '$global:GhqCalls = @()'
        '$global:FzfEnc = $null'
        $Fakes
        'Set-Location -LiteralPath $Start'
        '$savedEnc = $null'
        $(if ($Latin1) { '$savedEnc = [Console]::OutputEncoding; [Console]::OutputEncoding = [Text.Encoding]::GetEncoding(28591); $global:OutputEncoding = [Text.Encoding]::ASCII' } else { '' })
        '"enc-before=$([Console]::OutputEncoding.WebName) $($global:OutputEncoding.WebName)"'
        '$global:LASTEXITCODE = 0'
        'cdrepo'
        '"code=$LASTEXITCODE"'
        '"enc-after=$([Console]::OutputEncoding.WebName) $($global:OutputEncoding.WebName)"'
        'if ($null -ne $savedEnc) { [Console]::OutputEncoding = $savedEnc }'
        '"pwd=$((Get-Location).Path)"'
        '"fzf-args=$global:FzfArgs"'
        '"fzf-input=$(@($global:FzfInput) -join ''|'')"'
        '"fzf-enc=$global:FzfEnc"'
        '"ghq-calls=$(@($global:GhqCalls) -join ''|'')"'
    ) -join "`n"
    Set-Content -LiteralPath $child -Value $body -Encoding utf8
    # Windows PowerShell 5.1 は外のコマンドに空の文字列の引数を渡さない (-GhqRoot '' の '' が落ち、値の無い -GhqRoot で子が落ちる) ので、
    # 空なら渡さない。5.1 では Stop のままだと、子の stderr の 1 行目で止まる
    $ErrorActionPreference = 'Continue'
    $childArgs = @('-NoProfile', '-NonInteractive', '-File', $child, '-Dotfiles', $dotfiles, '-Start', $cdrepoDir, '-Root', $CdrepoRoot, '-PathValue', $PathValue)
    if ($GhqRoot) { $childArgs += @('-GhqRoot', $GhqRoot) }
    $pwsh = (Get-Process -Id $PID).Path
    & $pwsh @childArgs 2>&1 | ForEach-Object { "$_" }
}

# 子の出力から「<名前>=…」の行の値を取る
function Get-ChildValue {
    param([string[]]$Lines, [string]$Name)
    $line = @($Lines | Where-Object { $_.StartsWith("$Name=", [System.StringComparison]::Ordinal) })
    if ($line.Count -eq 0) { return "(${Name}= の行が無い)" }
    $line[0].Substring($Name.Length + 1)
}

# 偽の ghq (list は 2 つの repo を出し、root は一時の ghq の root を出す。$RootCode で root の終了コードを替える) と偽の fzf ($Pick を出し、
# $FzfCode を $LASTEXITCODE にする。受けた引数と入力と、呼ばれたときの [Console]::OutputEncoding・$OutputEncoding・BOM の長さを控える)。
# function は終了コードを持たないので、$LASTEXITCODE を自分で書く
function New-CdrepoFakes {
    param([string]$Pick = 'github.com/a/b', [int]$FzfCode = 0, [int]$RootCode = 0, [switch]$NoFzf)
    $ghq = @"
function ghq {
    `$global:GhqCalls += (`$args -join ' ')
    if (`$args[0] -eq 'list') { 'github.com/a/b'; 'github.com/c/d'; `$global:LASTEXITCODE = 0 }
    if (`$args[0] -eq 'root') { if ($RootCode -eq 0) { `$Root }; `$global:LASTEXITCODE = $RootCode }
}
"@
    $fzf = @"
function fzf {
    `$global:FzfArgs = `$args -join ' '
    `$global:FzfInput = @(`$input)
    `$global:FzfEnc = "`$([Console]::OutputEncoding.WebName) `$(`$OutputEncoding.WebName) `$(`$OutputEncoding.GetPreamble().Length)"
    if ('$Pick') { '$Pick' }
    `$global:LASTEXITCODE = $FzfCode
}
"@
    if ($NoFzf) { return $ghq }
    "$ghq`n$fzf"
}

$cdrepoDir = Join-Path ([IO.Path]::GetTempPath()) ("dotfiles-tests-" + [Guid]::NewGuid())
$cdrepoEmptyPath = Join-Path $cdrepoDir 'empty-path'
$CdrepoRoot = Join-Path $cdrepoDir 'ghq-root'
$cdrepoRepo = Join-Path (Join-Path (Join-Path $CdrepoRoot 'github.com') 'a') 'b'
$null = New-Item -ItemType Directory -Force -Path $cdrepoEmptyPath
$null = New-Item -ItemType Directory -Force -Path $cdrepoRepo
$null = New-Item -ItemType Directory -Force -Path (Join-Path (Join-Path (Join-Path $CdrepoRoot 'github.com') 'c') 'd')
try {
    # ghq が無ければ、fish・bash と同じ文を出して止まる (fzf があるかは見ない)
    $noGhq = @(Invoke-CdrepoChild)
    Test-Case 'cdrepo: ghq が無ければ「ghq is not installed」を出す' 'ghq is not installed' { $noGhq | Where-Object { $_ -like '* is not installed' } }
    Test-Case 'cdrepo: ghq が無ければ $LASTEXITCODE は 1 で、移らない' "1 $cdrepoDir" { "$(Get-ChildValue $noGhq 'code') $(Get-ChildValue $noGhq 'pwd')" }

    # fzf が無ければ、fish・bash と同じ文を出して止まる (ghq list も打たない)
    $noFzf = @(Invoke-CdrepoChild -Fakes (New-CdrepoFakes -NoFzf))
    Test-Case 'cdrepo: fzf が無ければ「fzf is not installed」を出す' 'fzf is not installed' { $noFzf | Where-Object { $_ -like '* is not installed' } }
    Test-Case 'cdrepo: fzf が無ければ $LASTEXITCODE は 1 で、ghq も打たずに移らない' "1 $cdrepoDir []" { "$(Get-ChildValue $noFzf 'code') $(Get-ChildValue $noFzf 'pwd') [$(Get-ChildValue $noFzf 'ghq-calls')]" }

    # 選んだら ghq root の下のその repo へ移る
    $picked = @(Invoke-CdrepoChild -Fakes (New-CdrepoFakes))
    Test-Case 'cdrepo: fzf に -1 +m を渡す' '-1 +m' { Get-ChildValue $picked 'fzf-args' }
    Test-Case 'cdrepo: fzf に ghq list の行を渡す' 'github.com/a/b|github.com/c/d' { Get-ChildValue $picked 'fzf-input' }
    Test-Case 'cdrepo: 選んだら ghq root の下のその repo へ移る' $cdrepoRepo { Get-ChildValue $picked 'pwd' }
    Test-Case 'cdrepo: ghq は list と root を打つ' 'list|root' { Get-ChildValue $picked 'ghq-calls' }
    Test-Case 'cdrepo: 移った後の $LASTEXITCODE は 0' '0' { Get-ChildValue $picked 'code' }
    # ghq と fzf (Go) は UTF-8 で書き・読むので、呼ぶ間だけ BOM の無い UTF-8 にし、[Console]::OutputEncoding は終わったら戻す
    Test-Case 'cdrepo: ghq と fzf を呼ぶ間は [Console]::OutputEncoding と $OutputEncoding を BOM の無い UTF-8 にする' 'utf-8 utf-8 0' { Get-ChildValue $picked 'fzf-enc' }
    Test-Case 'cdrepo: 終わったら [Console]::OutputEncoding と global の $OutputEncoding を元に戻す' (Get-ChildValue $picked 'enc-before') { Get-ChildValue $picked 'enc-after' }

    # 選ばずに抜けた・何も返さなかった・ghq root が落ちたなら移らない
    $cancelled = @(Invoke-CdrepoChild -Fakes (New-CdrepoFakes -Pick '' -FzfCode 130))
    Test-Case 'cdrepo: fzf を選ばずに抜けたら (130) 移らず、ghq root も打たない' "130 $cdrepoDir list" { "$(Get-ChildValue $cancelled 'code') $(Get-ChildValue $cancelled 'pwd') $(Get-ChildValue $cancelled 'ghq-calls')" }
    $failed = @(Invoke-CdrepoChild -Fakes (New-CdrepoFakes -FzfCode 2))
    Test-Case 'cdrepo: fzf が 0 でなければ、行を返しても移らない' "2 $cdrepoDir" { "$(Get-ChildValue $failed 'code') $(Get-ChildValue $failed 'pwd')" }
    $empty = @(Invoke-CdrepoChild -Fakes (New-CdrepoFakes -Pick ''))
    Test-Case 'cdrepo: fzf が 0 でも空を返したら移らない' "0 $cdrepoDir list" { "$(Get-ChildValue $empty 'code') $(Get-ChildValue $empty 'pwd') $(Get-ChildValue $empty 'ghq-calls')" }
    $noRoot = @(Invoke-CdrepoChild -Fakes (New-CdrepoFakes -RootCode 1))
    Test-Case 'cdrepo: ghq root が落ちたら移らない' "1 $cdrepoDir" { "$(Get-ChildValue $noRoot 'code') $(Get-ChildValue $noRoot 'pwd')" }
    Test-Case 'cdrepo: 移らずに抜けるときも [Console]::OutputEncoding と global の $OutputEncoding を元に戻す' (Get-ChildValue $cancelled 'enc-before') { Get-ChildValue $cancelled 'enc-after' }
    # Linux の pwsh の既定はどちらも UTF-8 なので、ISO-8859-1 と ASCII にしておいて戻したかを見分ける (Windows はコンソールの文字コードが親と
    # 共有なので流さない。Windows の既定 (CP932・5.1 の ASCII) からは、上の 2 つが戻したかを見る)
    if ($PSVersionTable.PSVersion.Major -ge 6 -and $IsLinux) {
        $latin1 = @(Invoke-CdrepoChild -Fakes (New-CdrepoFakes) -Latin1)
        Test-Case 'cdrepo: 前の文字コードが UTF-8 でなくても、呼ぶ間は UTF-8 にして元 (ISO-8859-1・ASCII) に戻す' 'iso-8859-1 us-ascii | utf-8 utf-8 0 | iso-8859-1 us-ascii' {
            "$(Get-ChildValue $latin1 'enc-before') | $(Get-ChildValue $latin1 'fzf-enc') | $(Get-ChildValue $latin1 'enc-after')"
        }
    } else {
        Write-Host 'skip cdrepo: 文字コードを ISO-8859-1・ASCII にしてから戻したかを見る (Linux の pwsh だけで流す)'
    }

    # Linux の cdrepo (fish の function と bash の function) と、知らせる文と fzf の引数を突き合わせる (どちらかを直したら、もう一方も直す)
    $modules = Join-Path (Join-Path (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'nix') 'home') 'modules'
    $fish = (Get-Content -Raw -LiteralPath (Join-Path $modules 'fish.nix')) -replace "`r`n", "`n"
    $bash = (Get-Content -Raw -LiteralPath (Join-Path $modules 'bash.nix')) -replace "`r`n", "`n"
    $fishBody = if ($fish -match "(?s)\bcdrepo = \{.*?body = ''(?<b>.*?)'';") { $Matches['b'] } else { '' }
    $bashBody = if ($bash -match '(?s)\bcdrepo\(\) \{(?<b>.*?)\n[ \t]*\}[ \t]*\n') { $Matches['b'] } else { '' }
    $psMessages = @($noGhq + $noFzf | Where-Object { $_ -like '* is not installed' })
    Test-Case 'cdrepo: 知らせる文は fish.nix の cdrepo と同じ' (@([regex]::Matches($fishBody, 'echo "([^"]*)"') | ForEach-Object { $_.Groups[1].Value }) -join '|') { $psMessages -join '|' }
    Test-Case 'cdrepo: 知らせる文は bash.nix の cdrepo と同じ' (@([regex]::Matches($bashBody, 'echo "([^"]*)"') | ForEach-Object { $_.Groups[1].Value }) -join '|') { $psMessages -join '|' }
    Test-Case 'cdrepo: fzf の引数は fish.nix の cdrepo (ghq list | fzf …) と同じ' $(if ($fishBody -match 'ghq list \| fzf (?<a>[^)\n]*)\)') { $Matches['a'] } else { '(fish.nix に ghq list | fzf が無い)' }) { Get-ChildValue $picked 'fzf-args' }
    Test-Case 'cdrepo: fzf の引数は bash.nix の cdrepo (fzf … <<<) と同じ' $(if ($bashBody -match 'fzf (?<a>[^<\n]*?) *<<<') { $Matches['a'] } else { '(bash.nix に fzf … <<< が無い)' }) { Get-ChildValue $picked 'fzf-args' }

    # 本物の ghq と fzf が PATH にあれば、本物でも 1 回流す。repo が 1 つの ghq の root (GHQ_ROOT) なら、fzf -1 は選ぶ画面を出さずに
    # その行を返す (端末を開かないので、CI でも手元の端末でも止まらない)。ネイティブのコマンドのパイプと $LASTEXITCODE の扱いと、ASCII でない
    # repo の名前 (Windows では文字コードを UTF-8 にしないと化ける) を見る
    $realGhq = Get-Command -Name ghq -CommandType Application -ErrorAction SilentlyContinue
    $realFzf = Get-Command -Name fzf -CommandType Application -ErrorAction SilentlyContinue
    if ($realGhq -and $realFzf) {
        $realRoot = Join-Path $cdrepoDir 'real-root'
        $realRepo = Join-Path (Join-Path (Join-Path $realRoot 'github.com') 'x') '日本語'
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $realRepo '.git')
        $real = @(Invoke-CdrepoChild -PathValue $env:PATH -GhqRoot $realRoot)
        Test-Case 'cdrepo: 本物の ghq と fzf でも、repo が 1 つならそこへ移る (ASCII でない名前の repo)' "0 $realRepo" { "$(Get-ChildValue $real 'code') $(Get-ChildValue $real 'pwd')" }
    } else {
        Write-Host 'skip cdrepo: 本物の ghq と fzf で流す (ghq か fzf が PATH に無い)'
    }
} finally {
    Remove-Item -LiteralPath $cdrepoDir -Recurse -Force -ErrorAction SilentlyContinue
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

# 読んだ先 (パイプ) に何も書かない (モードの印のカーソルの形の列は、端末に向いた PowerShell でだけ書く)。PSReadLine の警告も出さない
Test-Case 'Vi モード: 出力をパイプで受けるなら、読んでも何も書かない' 'end' {
    Invoke-AbbrChild -Body "Import-Module PSReadLine`n. `$Dotfiles`n'end'"
}

# 端末に向いた PowerShell (出力がパイプでない) では、読んだときにカーソルを挿入モードの形 (縦棒) にする (最初のプロンプトは挿入モードだが、
# PSReadLine はモードが替わるまで handler を呼ばない)。子の pwsh を script (util-linux) の擬似端末の下で起こし、書いた列を見る。script -c の
# 無い所 (Windows・macOS) では飛ばす。5.1 には $IsLinux が無い (StrictMode では読むと落ちる) ので、先に版を見る
if ($PSVersionTable.PSVersion.Major -ge 6 -and $IsLinux -and (Get-Command -Name script -CommandType Application -ErrorAction SilentlyContinue)) {
    $ttyDir = Join-Path ([IO.Path]::GetTempPath()) ("dotfiles-tests-" + [Guid]::NewGuid())
    $null = New-Item -ItemType Directory -Force -Path $ttyDir
    try {
        $ttyChild = Join-Path $ttyDir 'child.ps1'
        Set-Content -LiteralPath $ttyChild -Value "param([string]`$Dotfiles)`nImport-Module PSReadLine`n. `$Dotfiles`n'end'" -Encoding utf8
        $ttyPwsh = (Get-Process -Id $PID).Path
        $ttyOut = @(& script -qec "'$ttyPwsh' -NoProfile -NonInteractive -File '$ttyChild' -Dotfiles '$dotfiles'" /dev/null) -join "`n"
    } finally {
        Remove-Item -LiteralPath $ttyDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    Test-Case 'Vi モード: 端末に向いた PowerShell で読むと、カーソルを縦棒 (挿入モード) にする' 'ESC[6 q' {
        @([regex]::Matches($ttyOut, "$([char]27)\[\d* q") | ForEach-Object { $_.Value.Replace([string][char]27, 'ESC') }) -join ' '
    }
} else {
    Write-Host 'skip Vi モード: 端末に向いた PowerShell で読むとカーソルを縦棒にする (擬似端末を作る script -c が無い)'
}

# PSReadLine を読み込んだ PowerShell で、dotfiles.ps1 を読む前と後の割り当てを「キー=関数」で出す。読む前は Vi モードの既定 (EditMode を
# Vi にした直後)。dotfiles.ps1 は Windows の既定の EditMode (Windows) から読む (Linux の pwsh の既定は Emacs)。コマンドモードの割り当ては、
# キーが <> で囲まれて出る (<Ctrl+w>・<d,w> など)。モードの印 (ViModeChangeHandler) が書く字は、[Console]::Out を差し替えて受ける。
# 5.1 の PSReadLine 2.0.0 の Get-PSReadLineKeyHandler には -Chord が無いので、-Bound の全部を出す
$viOut = @(Invoke-AbbrChild -Body @'
Import-Module PSReadLine
"PSReadLine=$((Get-Module -Name PSReadLine).Version)"
Set-PSReadLineOption -EditMode Vi
Get-PSReadLineKeyHandler -Bound | ForEach-Object { "before:$($_.Key)=$($_.Function)" }
Set-PSReadLineOption -EditMode Windows
$delimiters = (Get-PSReadLineOption).WordDelimiters
. $Dotfiles
$option = Get-PSReadLineOption
"EditMode=$($option.EditMode)"
"WordDelimiters=$($option.WordDelimiters -ceq $delimiters)"
"ViModeIndicator=$($option.ViModeIndicator)"
Get-PSReadLineKeyHandler -Bound | ForEach-Object { "after:$($_.Key)=$($_.Function)" }
foreach ($mode in 'Command', 'Insert') {
    $writer = [System.IO.StringWriter]::new()
    $saved = [Console]::Out
    [Console]::SetOut($writer)
    try { & $option.ViModeChangeHandler ([Microsoft.PowerShell.ViMode]$mode) } finally { [Console]::SetOut($saved) }
    "cursor:$mode=$($writer.ToString().Replace([string][char]27, 'ESC'))"
}
'@)
$viBefore = @($viOut | Where-Object { $_ -clike 'before:*' } | ForEach-Object { $_.Substring('before:'.Length) })
$viAfter = @($viOut | Where-Object { $_ -clike 'after:*' } | ForEach-Object { $_.Substring('after:'.Length) })
$psReadLineVersion = [version](@($viOut | Where-Object { $_ -clike 'PSReadLine=*' })[0].Substring('PSReadLine='.Length))

Test-Case 'Vi モード: EditMode を Vi にする' 'EditMode=Vi' { $viOut | Where-Object { $_ -clike 'EditMode=*' } }

# bash に似たキー: 挿入モードの 8 つを、bash (readline) の forward-word・backward-word・unix-word-rubout・kill-word・beginning-of-line・
# end-of-line・kill-line・unix-line-discard に当たる関数 (PSReadLine の Emacs モードと同じ関数) にする。Ctrl+u は、入力の頭まで消して
# kill ring に入れる関数の名前が版で違う (2.2.0 から BackwardKillInput。5.1 の 2.0.0 と 2.1 は BackwardKillLine)。キーは大文字小文字を区別して
# 選ぶ (Alt+F は Alt+Shift+f で別のキー)
$ctrlU = if ($psReadLineVersion -lt [version]'2.2.0') { 'BackwardKillLine' } else { 'BackwardKillInput' }
$wantedViKeys = @(
    'Alt+f=ForwardWord'
    'Alt+b=BackwardWord'
    'Ctrl+w=UnixWordRubout'
    'Alt+d=KillWord'
    'Ctrl+a=BeginningOfLine'
    'Ctrl+e=EndOfLine'
    'Ctrl+k=KillLine'
    "Ctrl+u=$ctrlU"
) | Sort-Object
Test-Case "Vi モード: 挿入モードの Alt+f Alt+b Ctrl+w Alt+d Ctrl+a Ctrl+e Ctrl+k Ctrl+u を bash と同じ動きの関数に割り当てる (Ctrl+u は $ctrlU)" $wantedViKeys {
    $viAfter | Where-Object { ($_ -split '=', 2)[0] -cin 'Alt+f', 'Alt+b', 'Ctrl+w', 'Alt+d', 'Ctrl+a', 'Ctrl+e', 'Ctrl+k', 'Ctrl+u' } | Sort-Object
}

# 略語: 挿入モードで、広げるキー・実行するキー・広げずに空白を入れるキーを割り当てる (> と < には割り当てない。コマンドモードには割り当てない)
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
Test-Case '略語の割り当て: 挿入モードの Space ; | & ) Enter Ctrl+Spacebar Ctrl+@ Shift+Spacebar に割り当てる' $wanted {
    $viAfter | Where-Object { $_ -clike '*=DotfilesAbbr*' } | Sort-Object
}

# Vi の既定から割り当てが替わるのは、挿入モードの bash に似たキーと略語のキーだけ。コマンドモードの割り当て (<> で囲まれたキー) と、
# 挿入モードのほかのキー (Esc・Tab・Ctrl+v など) は Vi の既定のまま
$wantedChangedKeys = @(
    'Alt+f', 'Alt+b', 'Ctrl+w', 'Alt+d', 'Ctrl+a', 'Ctrl+e', 'Ctrl+k', 'Ctrl+u'
    'Spacebar', ';', '|', '&', ')', 'Enter', 'Ctrl+Spacebar', 'Ctrl+@', 'Shift+Spacebar'
) | Sort-Object -CaseSensitive
Test-Case 'Vi モード: Vi の既定から替わるのは、挿入モードの bash に似たキーと略語のキーだけ' $wantedChangedKeys {
    Compare-Object -CaseSensitive $viBefore $viAfter | ForEach-Object { ($_.InputObject -split '=', 2)[0] } | Sort-Object -Unique -CaseSensitive
}

# 語の区切り (WordDelimiters) はほかのキー (Ctrl+←→・コマンドモードの w・b など) にも効くので替えない
Test-Case 'Vi モード: WordDelimiters は替えない' 'WordDelimiters=True' { $viOut | Where-Object { $_ -clike 'WordDelimiters=*' } }

# 今のモードを、カーソルの形で示す (コマンドモードはブロック、挿入モードは縦棒)。PSReadLine はモードが替わるたびに ViModeChangeHandler を
# 呼び、handler はカーソルの形を替える列 (DECSCUSR: ESC [ 2 SP q がブロック、ESC [ 6 SP q が縦棒。どちらも点滅しない) を書く
Test-Case 'Vi モード: モードの印は ViModeChangeHandler で書く (Script)' 'ViModeIndicator=Script' { $viOut | Where-Object { $_ -clike 'ViModeIndicator=*' } }
Test-Case 'Vi モード: コマンドモードに入るとカーソルをブロックにする' 'cursor:Command=ESC[2 q' { $viOut | Where-Object { $_ -clike 'cursor:Command=*' } }
Test-Case 'Vi モード: 挿入モードに入るとカーソルを縦棒にする' 'cursor:Insert=ESC[6 q' { $viOut | Where-Object { $_ -clike 'cursor:Insert=*' } }

# starship の init は、$PROFILE で dotfiles.ps1 より先に ViModeChangeHandler (プロンプトを描き直す) を置き、$PROFILE を読み直すと、そのときの
# handler を包んだ handler を置く。dotfiles.ps1 は先の handler を包まずに置き換える (プロンプトは自分で描き直す。出力がパイプの子では描き直さない)
# ので、読み直しても handler は入れ子にならない (モードが替わるたびに、カーソルの形を書くのも描き直すのも 1 回)
$reloadOut = @(Invoke-AbbrChild -Body @'
Import-Module PSReadLine
Set-PSReadLineOption -ViModeIndicator Script -ViModeChangeHandler { [Console]::Write('previous') }
. $Dotfiles
& {
    $inner = (Get-PSReadLineOption).ViModeChangeHandler
    Set-PSReadLineOption -ViModeChangeHandler { [Console]::Write('wrapper'); & $inner @args }.GetNewClosure()
}
. $Dotfiles
$writer = [System.IO.StringWriter]::new()
$saved = [Console]::Out
[Console]::SetOut($writer)
try { & (Get-PSReadLineOption).ViModeChangeHandler ([Microsoft.PowerShell.ViMode]::Command) } finally { [Console]::SetOut($saved) }
"cursor=$($writer.ToString().Replace([string][char]27, 'ESC'))"
'@)
Test-Case 'Vi モード: 先に置かれた handler (starship の init) を包まず、読み直しても入れ子にならない' 'cursor=ESC[2 q' { $reloadOut | Where-Object { $_ -clike 'cursor=*' } }

if ($script:Failures -gt 0) {
    Write-Host "$($script:Failures) 件失敗"
    exit 1
}
Write-Host 'すべて通った'
