# win/powershell/Invoke-DotfilesRunner.ps1 (runner の launcher) のテスト。Pester は使わない (win/README.md の「PowerShell のテスト」)。
# 副作用の無い関数は dot-source して確かめ、置き場から起こす流れは、一時の git の repo を clone にし、置き場 (LOCALAPPDATA) を一時ディレクトリにした
# 子の pwsh で launcher を流して確かめる (Linux だけ。exe は version の行を出す sh の script で真似る。cargo は偽物の関数。本物の cargo も GitHub も
# 触らない)。Release から落とす流れは、Windows の CI (.github/scripts/win-runner-e2e.ps1) が本物の exe と手元の HTTP server で確かめる。
#
# WSL から流す (Linux の pwsh で動かすので、Windows 側には触らない):
#   nix shell --inputs-from ./nix nixpkgs#powershell nixpkgs#git --command pwsh -NoProfile -NonInteractive -File win/powershell/Invoke-DotfilesRunner.Tests.ps1
#
# ## 確かめること
#
#   - ファイル: BOM 付きの UTF-8 (BOM は 1 つ) で、PowerShell 7 にしか無い書き方を使わない (Windows PowerShell 5.1 の dotfiles 関数からも呼ぶ)
#   - DOTFILES_RUNNER は空・exe・cargo だけ (大文字小文字を区別する)。key は 40 字の小文字の 16 進。tag は win-runner-<頭 12 字>、URL は
#     <根>/<tag>/<名前> (根の末尾の / は 1 つにする)。.sha256 は 1 行目の頭の 64 字を小文字で読む
#   - exe に渡す引数は、1 つ目 (コマンド) の直後に --repo <clone> を差し込む (import の -- と、その後ろの - で始まる名前は動かさない)
#   - 置き場の古い key のディレクトリは、今の key を残し、ほかを新しい順に 2 つ残して消す (key の形でない名前には触らない)
#   - 選び方の決まり (README の表): 置き場にある → 使う、無い → 落とす、commit していない変更 → cargo があれば build・無ければ ⚠ で HEAD の exe、
#     git が無い・key を読めない → cargo があれば build・無ければ止める、cargo のモード → いつも build、exe のモード → cargo に戻らない
#   - 落とせないとき: 自動で cargo があれば build (1 行知らせる)、無ければ直し方の 4 行で止める。sha256・key が合わない (Hard) なら、cargo が
#     あっても止める
#   - 起こせないわけ: 4551 (Application Control)・1260 (グループ ポリシー・AppLocker) は Smart App Control・App Control の直し方。起こせない (launch) は
#     自動で cargo があれば cargo に戻り、無ければわけと cargo の道の 1 行で止まる。key を読めないわけには git の文を添える
#   - 通し (Linux): clone の key と、commit していない変更 (未追跡のファイルも) を git で読む。置き場に置いた exe と正しい .sha256 なら落とさずに
#     起こし、--repo <clone> を渡し、終了コードは exe のもの、印 verified を置く。.sha256 を壊すと cargo があっても打たずに 2 で止まる。
#     DOTFILES_RUNNER=cargo なら win/runner で cargo run --quiet --release --locked -- <引数> を打つ。落とせない (つながらない) と、cargo が
#     あれば cargo を打ち、無ければ直し方を出して 2。cargo へ回って 101 なら直し方を出す (明示の cargo のモードでは出さない)。置き場の exe を
#     替えたら印を作り直す
#   - 通し (Linux・python3 の HTTP server): exe だけが置き場に残っていれば起こさずに落とした物で置き換える・落とした物を起こせなければ (exe の
#     モード) 2、自動で cargo があれば cargo・Release の sha256 が合わなければ cargo があっても 2 で置かない・404 は直し方を出して 2
#
# BOM 付きの UTF-8 で保存すること (win/README.md の「dotfiles.ps1 を書くときの注意」)。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Launcher = Join-Path $PSScriptRoot 'Invoke-DotfilesRunner.ps1'

# dot-source すると関数だけを読み、本体は走らない (Invoke-DotfilesRunner.ps1 の末尾)
. $Launcher

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

$K = '261aff1f714694bfe0c0199428617dfc448336a4'

# ---------------------------------------------------------------------------
# ファイルそのもの
# ---------------------------------------------------------------------------

Test-Case 'BOM 付きの UTF-8 で保存してある (BOM は 1 つだけ)' 'EF BB BF 23 20' {
    $bytes = [IO.File]::ReadAllBytes($Launcher)
    ($bytes[0..4] | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
}

Test-Case 'PowerShell 7 にしか無い書き方 (??・?.・三項演算子・&&・||・-AsHashtable) を使っていない' '' {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($Launcher, [ref]$tokens, [ref]$errors)
    $bad = @('QuestionQuestion', 'QuestionQuestionEquals', 'QuestionDot', 'QuestionLBracket', 'AndAnd', 'OrOr', 'QuestionMark')
    @($tokens | Where-Object { ("$($_.Kind)" -in $bad) -or ($_.Text -eq '-AsHashtable') } |
            ForEach-Object { "$($_.Text)@$($_.Extent.StartLineNumber)" }) -join ' '
}

Test-Case 'Join-Path に 3 つ目の引数を渡していない (5.1 は 2 つまで)' '' {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Launcher, [ref]$null, [ref]$null)
    @($ast.FindAll({
                param($n)
                ($n -is [System.Management.Automation.Language.CommandAst]) -and ($n.GetCommandName() -eq 'Join-Path') -and
                ($n.CommandElements.Count -gt 3)
            }, $true) | ForEach-Object { $_.Extent.StartLineNumber }) -join ' '
}

Test-Case 'param ブロックを置かない (runner の -h などを PowerShell が自分の引数として読まない)' $false {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Launcher, [ref]$null, [ref]$null)
    $null -ne $ast.ParamBlock
}

# ---------------------------------------------------------------------------
# 副作用の無い関数
# ---------------------------------------------------------------------------

Test-Case 'モード: 空は auto' 'auto' { Get-DotfilesRunnerMode -Value '' }
Test-Case 'モード: exe と cargo' 'exe cargo' { "$(Get-DotfilesRunnerMode -Value 'exe') $(Get-DotfilesRunnerMode -Value 'cargo')" }
Test-Case 'モード: 大文字小文字を区別し、知らない値は $null' 'True True' { "$($null -eq (Get-DotfilesRunnerMode -Value 'Cargo')) $($null -eq (Get-DotfilesRunnerMode -Value 'x'))" }

Test-Case 'key: 40 字の小文字の 16 進だけ' 'True False False False' {
    "$(Test-DotfilesRunnerKey -Key $K) $(Test-DotfilesRunnerKey -Key $K.ToUpperInvariant()) $(Test-DotfilesRunnerKey -Key $K.Substring(1)) $(Test-DotfilesRunnerKey -Key '')"
}
Test-Case 'tag は win-runner-<key の頭 12 字>' 'win-runner-261aff1f7146' { Get-DotfilesRunnerTag -Key $K }
Test-Case 'URL は <根>/<tag>/<名前> (根の末尾の / は 1 つ)' 'http://127.0.0.1:8000/win-runner-261aff1f7146/dotfiles-win.exe' {
    Get-DotfilesRunnerUrl -BaseUrl 'http://127.0.0.1:8000/' -Key $K -Name 'dotfiles-win.exe'
}
Test-Case '既定の URL の根は dotfiles の Release の download' 'https://github.com/pollenjp/dotfiles/releases/download/win-runner-261aff1f7146/dotfiles-win.exe.sha256' {
    Get-DotfilesRunnerUrl -BaseUrl $script:DotfilesRunnerBaseUrl -Key $K -Name 'dotfiles-win.exe.sha256'
}

$hex = ('AB' * 32)
Test-Case '.sha256: 1 行目の頭の 64 字を小文字で' ('ab' * 32) { ConvertFrom-DotfilesRunnerSha256 -Text "$hex  dotfiles-win.exe`r`n" }
Test-Case '.sha256: 形が違えば空' '' { ConvertFrom-DotfilesRunnerSha256 -Text 'abc  dotfiles-win.exe' }
Test-Case '.sha256: 空なら空' '' { ConvertFrom-DotfilesRunnerSha256 -Text '' }

Test-Case '引数: コマンドの直後に --repo <clone> を差し込み、import の -- と名前は動かさない' 'import|--repo|C:\c|fancyzones|--|-x' {
    (Get-DotfilesRunnerArgs -Clone 'C:\c' -Arguments @('import', 'fancyzones', '--', '-x')) -join '|'
}
Test-Case '引数: コマンドだけ' 'check|--repo|C:\c' { (Get-DotfilesRunnerArgs -Clone 'C:\c' -Arguments @('check')) -join '|' }
Test-Case '引数: 引数が無ければ何も足さない' 0 { @(Get-DotfilesRunnerArgs -Clone 'C:\c' -Arguments @()).Count }

Test-Case '置き場の dir は %LOCALAPPDATA%\dotfiles\runner\<key>' ([IO.Path]::Combine('L', 'dotfiles', 'runner', $K)) { Get-DotfilesRunnerCacheDir -LocalAppData 'L' -Key $K }

function New-Dir { param([string]$Name, [int]$AgeDays) [pscustomobject]@{ Name = $Name; LastWriteTime = (Get-Date).AddDays(-$AgeDays) } }
$keys = @(('1' * 40), ('2' * 40), ('3' * 40), ('4' * 40), ('5' * 40))
Test-Case '古い key: 今の key (一番古い) を残し、ほかの 4 つのうち古い 2 つを消す (key の形でない名前には触らない)' "$('2' * 40)|$('1' * 40)" {
    $dirs = @((New-Dir $keys[0] 4), (New-Dir $keys[1] 3), (New-Dir $keys[2] 2), (New-Dir $keys[3] 1), (New-Dir $keys[4] 9), (New-Dir 'not-a-key' 99))
    (Select-DotfilesRunnerStaleDirs -Dirs $dirs -Current $keys[4] -Keep 3) -join '|'
}
Test-Case '古い key: 数が Keep 以下なら何も消さない' 0 {
    @(Select-DotfilesRunnerStaleDirs -Dirs @((New-Dir $keys[0] 1), (New-Dir $keys[1] 2)) -Current $keys[0] -Keep 3).Count
}

function Format-Decision {
    param([string]$Mode = 'auto', [bool]$HaveGit = $true, [string]$Key = $K, [bool]$Dirty = $false, [bool]$HaveCargo = $false, [bool]$Cached = $false)
    $d = Get-DotfilesRunnerDecision -Mode $Mode -HaveGit $HaveGit -Key $Key -Dirty $Dirty -HaveCargo $HaveCargo -Cached $Cached
    "$($d.Action)|notes=$(@($d.Notes).Count)|warn=$(@($d.Warn).Count)|error=$([bool]$d.Error)"
}
Test-Case '決まり: 置き場にあれば使う' 'cached|notes=0|warn=0|error=False' { Format-Decision -Cached $true }
Test-Case '決まり: 置き場に無ければ落とす (cargo があっても)' 'download|notes=0|warn=0|error=False' { Format-Decision -HaveCargo $true }
Test-Case '決まり: commit していない変更があり cargo があれば build' 'cargo|notes=1|warn=0|error=False' { Format-Decision -Dirty $true -HaveCargo $true -Cached $true }
Test-Case '決まり: commit していない変更があり cargo が無ければ ⚠ で HEAD の exe' 'cached|notes=0|warn=1|error=False download|notes=0|warn=1|error=False' {
    "$(Format-Decision -Dirty $true -Cached $true) $(Format-Decision -Dirty $true)"
}
Test-Case '決まり: ⚠ の文は変更が効かないこと' $true {
    $d = Get-DotfilesRunnerDecision -Mode 'auto' -HaveGit $true -Key $K -Dirty $true -HaveCargo $false -Cached $false
    $d.Warn[0] -like '⚠ win/runner に commit していない変更があるが、cargo が無い*変更は効かない*'
}
Test-Case '決まり: git が無ければ、cargo があれば build・無ければ止める' 'cargo|notes=1|warn=0|error=False error|notes=0|warn=0|error=True' {
    "$(Format-Decision -HaveGit $false -Key '' -HaveCargo $true) $(Format-Decision -HaveGit $false -Key '')"
}
Test-Case '決まり: key を読めなければ、cargo が無いと止める' 'error|notes=0|warn=0|error=True' { Format-Decision -Key '' }
Test-Case '決まり: cargo のモードはいつも build' 'cargo|notes=1|warn=0|error=False' { Format-Decision -Mode 'cargo' -Cached $true }
Test-Case '決まり: exe のモードは、変更があっても cargo に戻らず ⚠' 'cached|notes=0|warn=1|error=False' { Format-Decision -Mode 'exe' -Dirty $true -HaveCargo $true -Cached $true }
Test-Case '決まり: exe のモードは、git が無ければ cargo があっても止める' 'error|notes=0|warn=0|error=True' { Format-Decision -Mode 'exe' -HaveGit $false -Key '' -HaveCargo $true }

Test-Case '決まり: key を読めないわけに git の文を添える' $true {
    $d = Get-DotfilesRunnerDecision -Mode 'auto' -HaveGit $true -Key '' -Dirty $false -HaveCargo $false -Cached $false -GitMessage 'fatal: detected dubious ownership'
    $d.Error -like '*git で読めない (fatal: detected dubious ownership)*'
}

function Format-Fallback {
    param([string]$Mode = 'auto', [bool]$HaveCargo = $false, [string]$Kind = 'download')
    $f = Get-DotfilesRunnerFallback -Mode $Mode -HaveCargo $HaveCargo -Kind $Kind -Reason 'Release が無い (HTTP 404)' -CacheDir 'D'
    "$($f.Action)|hints=$(@($f.Hints).Count)|error=$([bool]$f.Error)"
}
Test-Case '落とせない: 自動で cargo があれば build' 'cargo|hints=0|error=False' { Format-Fallback -HaveCargo $true }
Test-Case '落とせない: cargo が無ければ直し方の 4 行で止める' 'error|hints=4|error=True' { Format-Fallback }
Test-Case '落とせない: 直し方は数分待つ・--self-update・-Rust・手で置く' $true {
    $h = @(Get-DotfilesRunnerHints -CacheDir 'D')
    ($h[0] -like '*数分待って*') -and ($h[1] -like '*dotfiles --self-update*') -and ($h[2] -like '*-Rust*') -and ($h[3] -like '*D に置く*')
}
Test-Case '合わない (hard): cargo があっても止める' 'error|hints=2|error=True' { Format-Fallback -HaveCargo $true -Kind 'hard' }
Test-Case '落とせない: exe のモードは cargo に戻らない' 'error|hints=4|error=True' { Format-Fallback -Mode 'exe' -HaveCargo $true }
Test-Case '起こせない (launch): 自動で cargo があれば build (clone の中で作った exe は通ることがある)' 'cargo|hints=0|error=False' { Format-Fallback -HaveCargo $true -Kind 'launch' }
Test-Case '起こせない (launch): cargo が無ければ、わけと cargo の道の 1 行で止める' 'error|hints=1|error=True' { Format-Fallback -Kind 'launch' }

Test-Case '起こせない: 4551 は Smart App Control の直し方' $true { (Get-DotfilesRunnerLaunchHint -Message 'x' -NativeErrorCode 4551) -like '*Smart App Control*' }
Test-Case '起こせない: Application Control の文も Smart App Control の直し方' $true {
    (Get-DotfilesRunnerLaunchHint -Message 'An Application Control policy has blocked this file' -NativeErrorCode 0) -like '*スマート アプリ コントロール*'
}
Test-Case '起こせない: 1260 (グループ ポリシー・AppLocker) も App Control の直し方' $true { (Get-DotfilesRunnerLaunchHint -Message 'x' -NativeErrorCode 1260) -like '*AppLocker*' }
Test-Case '起こせない: ほかは元の文' 'boom' { Get-DotfilesRunnerLaunchHint -Message 'boom' -NativeErrorCode 5 }

# ---------------------------------------------------------------------------
# 通し (Linux の pwsh だけ。exe は sh の script で真似る)
# ---------------------------------------------------------------------------

$git = Find-DotfilesRunnerApplication -Name 'git'
if (([IO.Path]::DirectorySeparatorChar -eq '\') -or (-not $git)) {
    Write-Host 'skip 通し: launcher を子の pwsh で流す (Linux の pwsh と git が要る。exe は sh の script で真似る)'
} else {
    $root = Join-Path ([IO.Path]::GetTempPath()) ("dotfiles-runner-tests-" + [Guid]::NewGuid())
    $clone = Join-Path $root 'clone'
    $home2 = Join-Path $root 'home'
    $gitConfig = Join-Path $root 'gitconfig'
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $clone 'win/runner/src'), $home2
    Set-Content -LiteralPath $gitConfig -Value '' -Encoding ascii
    Set-Content -LiteralPath (Join-Path $clone 'win/runner/Cargo.toml') -Value '[package]' -Encoding ascii
    Set-Content -LiteralPath (Join-Path $clone 'win/runner/src/main.rs') -Value 'fn main() {}' -Encoding ascii
    $savedGit = @{ GLOBAL = $env:GIT_CONFIG_GLOBAL; NOSYSTEM = $env:GIT_CONFIG_NOSYSTEM }
    $env:GIT_CONFIG_GLOBAL = $gitConfig
    $env:GIT_CONFIG_NOSYSTEM = '1'
    try {
        $null = & $git -C $clone init --quiet --initial-branch=main 2>&1
        $null = & $git -C $clone -c user.name=t -c user.email=t@example.invalid add --all 2>&1
        $null = & $git -C $clone -c user.name=t -c user.email=t@example.invalid commit --quiet -m init 2>&1
        $key = "$(@(& $git -C $clone rev-parse 'HEAD:win/runner')[0])".Trim()

        Test-Case '通し: clone の key は git rev-parse HEAD:win/runner と同じ' $key { Get-DotfilesRunnerCloneKey -Git $git -Clone $clone }
        Test-Case '通し: 変更が無ければ dirty でない' $false { Test-DotfilesRunnerDirty -Git $git -Clone $clone }
        $untracked = Join-Path $clone 'win/runner/src/new.rs'
        Set-Content -LiteralPath $untracked -Value '' -Encoding ascii
        Test-Case '通し: 未追跡のファイルも commit していない変更' $true { Test-DotfilesRunnerDirty -Git $git -Clone $clone }
        Remove-Item -LiteralPath $untracked

        # 置き場に、version で key を名乗り、ほかの引数を出して 5 で終わる sh の script を exe として置く
        function Set-FakeExe {
            param([string]$LocalAppData, [string]$Key, [string]$Sha = '')
            $dir = Get-DotfilesRunnerCacheDir -LocalAppData $LocalAppData -Key $Key
            $null = New-Item -ItemType Directory -Force -Path $dir
            $exe = Join-Path $dir 'dotfiles-win.exe'
            $body = "#!/bin/sh`nif [ `"`$1`" = version ]; then printf 'dotfiles-win 0.1.0\nkey=$Key\ncommit=\nbuild=release\n'; exit 0; fi`necho `"fake-exe-args=`$*`"`nexit 5`n"
            [IO.File]::WriteAllText($exe, $body)
            & chmod +x $exe
            if (-not $Sha) { $Sha = Get-DotfilesRunnerFileSha256 -Path $exe }
            [IO.File]::WriteAllText((Join-Path $dir 'dotfiles-win.exe.sha256'), "$Sha  dotfiles-win.exe`n")
            $dir
        }

        # 子の pwsh で launcher を流す。PATH は git の dir だけ (本物の cargo を見せない)、HOME・CARGO_HOME は一時ディレクトリ。-WithCargo なら
        # cargo は、打たれた場所と引数を出して -CargoExit (既定 7) で終わる偽物の関数
        function Invoke-LauncherChild {
            param([string]$LocalAppData, [string]$RunnerArgs, [switch]$WithCargo, [string]$Mode = '', [string]$BaseUrl = '', [int]$CargoExit = 7)
            $child = Join-Path $root 'child.ps1'
            $body = @(
                'param([string]$Launcher, [string]$Clone, [string]$RunnerArgs, [string]$WithCargo)'
                'if ($WithCargo -eq ''1'') { function cargo { "cargo-cwd=$((Get-Location).Path)"; "cargo-args=$($args -join ''|'')"; $global:LASTEXITCODE = [int]$env:FAKE_CARGO_EXIT } }'
                '$a = @($RunnerArgs -split ''\|'' | Where-Object { $_ })'
                '& $Launcher $Clone @a'
                '"code=$LASTEXITCODE"'
            ) -join "`n"
            Set-Content -LiteralPath $child -Value $body -Encoding utf8
            $names = @('HOME', 'USERPROFILE', 'LOCALAPPDATA', 'PATH', 'CARGO_HOME', 'DOTFILES_RUNNER', 'DOTFILES_RUNNER_BASE_URL', 'NO_COLOR', 'FAKE_CARGO_EXIT')
            $saved = @{}
            foreach ($n in $names) { $saved[$n] = [Environment]::GetEnvironmentVariable($n) }
            $ErrorActionPreference = 'Continue'
            try {
                $env:HOME = $home2
                $env:USERPROFILE = $home2
                $env:LOCALAPPDATA = $LocalAppData
                $env:PATH = Split-Path -Parent $git
                $env:CARGO_HOME = Join-Path $root 'no-cargo'
                $env:DOTFILES_RUNNER = $Mode
                $env:DOTFILES_RUNNER_BASE_URL = $BaseUrl
                $env:NO_COLOR = '1'
                $env:FAKE_CARGO_EXIT = "$CargoExit"
                $flag = '0'
                if ($WithCargo) { $flag = '1' }
                $pwsh = (Get-Process -Id $PID).Path
                & $pwsh -NoProfile -NonInteractive -File $child -Launcher $Launcher -Clone $clone -RunnerArgs $RunnerArgs -WithCargo $flag 2>&1 | ForEach-Object { "$_" }
            } finally {
                foreach ($n in $names) { [Environment]::SetEnvironmentVariable($n, $saved[$n]) }
            }
        }

        function Get-ChildValue { param([string[]]$Out, [string]$Name) @($Out | Where-Object { $_ -like "$Name=*" } | ForEach-Object { $_.Substring($Name.Length + 1) }) -join ';' }

        $lad = Join-Path $root 'lad1'
        $dir = Set-FakeExe -LocalAppData $lad -Key $key
        $out = @(Invoke-LauncherChild -LocalAppData $lad -RunnerArgs 'list|--host-file|h.toml' -WithCargo -BaseUrl 'http://127.0.0.1:9/')
        Test-Case '通し: 置き場の exe を起こし、コマンドの直後に --repo <clone> を渡す' "list --repo $clone --host-file h.toml" { Get-ChildValue $out 'fake-exe-args' }
        Test-Case '通し: 終了コードは exe のもの' '5' { Get-ChildValue $out 'code' }
        Test-Case '通し: 置き場にあれば落とさず、cargo も打たない' '0 0' {
            "$(@($out | Where-Object { $_ -like '==> runner の exe を落とす*' }).Count) $(@($out | Where-Object { $_ -like 'cargo-*' }).Count)"
        }
        Test-Case '通し: version で key を確かめた印 verified を置く' $true { Test-Path -LiteralPath (Join-Path $dir 'verified') -PathType Leaf }

        $lad = Join-Path $root 'lad2'
        $null = Set-FakeExe -LocalAppData $lad -Key $key -Sha ('0' * 64)
        $out = @(Invoke-LauncherChild -LocalAppData $lad -RunnerArgs 'check' -WithCargo -BaseUrl 'http://127.0.0.1:9/')
        Test-Case '通し: .sha256 が合わなければ、cargo があっても打たずに 2 で止まる' '2 0 0' {
            "$(Get-ChildValue $out 'code') $(@($out | Where-Object { $_ -like 'cargo-*' }).Count) $(@($out | Where-Object { $_ -like 'fake-exe-args=*' }).Count)"
        }
        Test-Case '通し: 合わないことを出す' $true { [bool]($out | Where-Object { $_ -like '!! *合わない*' }) }

        $out = @(Invoke-LauncherChild -LocalAppData (Join-Path $root 'lad3') -RunnerArgs 'check|--steps|files' -WithCargo -Mode 'cargo')
        Test-Case '通し: DOTFILES_RUNNER=cargo なら win/runner で cargo run --quiet --release --locked -- <引数>' "$(Join-Path $clone 'win/runner')|run|--quiet|--release|--locked|--|check|--steps|files|7" {
            "$(Get-ChildValue $out 'cargo-cwd')|$(Get-ChildValue $out 'cargo-args')|$(Get-ChildValue $out 'code')"
        }

        $out = @(Invoke-LauncherChild -LocalAppData (Join-Path $root 'lad4') -RunnerArgs 'check' -WithCargo -BaseUrl 'http://127.0.0.1:9/')
        Test-Case '通し: 落とせなければ、cargo があれば cargo を打つ' 'check' { (Get-ChildValue $out 'cargo-args') -replace '^.*\|', '' }
        Test-Case '通し: cargo に戻るときは 1 行知らせる' $true { [bool]($out | Where-Object { $_ -like '· 配った runner の exe を使えない*手元で build する (cargo)' }) }

        $out = @(Invoke-LauncherChild -LocalAppData (Join-Path $root 'lad5') -RunnerArgs 'check' -BaseUrl 'http://127.0.0.1:9/')
        Test-Case '通し: 落とせず cargo も無ければ、直し方を出して 2' '2 True' {
            "$(Get-ChildValue $out 'code') $([bool]($out | Where-Object { $_ -like '  → merge の直後なら*' }))"
        }

        Set-Content -LiteralPath (Join-Path $clone 'win/runner/src/main.rs') -Value 'fn main() { /* edited */ }' -Encoding ascii
        $lad = Join-Path $root 'lad6'
        $null = Set-FakeExe -LocalAppData $lad -Key $key
        $out = @(Invoke-LauncherChild -LocalAppData $lad -RunnerArgs 'check' -BaseUrl 'http://127.0.0.1:9/')
        Test-Case '通し: 変更があり cargo が無ければ、⚠ を出して HEAD の exe で流す' '5 True' {
            "$(Get-ChildValue $out 'code') $([bool]($out | Where-Object { $_ -like '⚠ win/runner に commit していない変更があるが*' }))"
        }
        $out = @(Invoke-LauncherChild -LocalAppData $lad -RunnerArgs 'check' -WithCargo -BaseUrl 'http://127.0.0.1:9/')
        Test-Case '通し: 変更があり cargo があれば build する' '7 0' {
            "$(Get-ChildValue $out 'code') $(@($out | Where-Object { $_ -like 'fake-exe-args=*' }).Count)"
        }

        # 変更を戻す (ここから下は変更の無い clone)
        $null = & $git -C $clone checkout --quiet -- win/runner 2>&1

        $out = @(Invoke-LauncherChild -LocalAppData $lad -RunnerArgs 'check' -WithCargo -CargoExit 101 -BaseUrl 'http://127.0.0.1:9/' -Mode 'cargo')
        Test-Case '通し: 明示の cargo のモードの 101 には、Release の直し方を出さない' '101 0' {
            "$(Get-ChildValue $out 'code') $(@($out | Where-Object { $_ -like '!! cargo が終了コード 101*' }).Count)"
        }
        $out = @(Invoke-LauncherChild -LocalAppData (Join-Path $root 'lad7') -RunnerArgs 'check' -WithCargo -CargoExit 101 -BaseUrl 'http://127.0.0.1:9/')
        Test-Case '通し: 落とせずに cargo へ回って 101 なら、合う exe を得る直し方を出す' '101 True True' {
            "$(Get-ChildValue $out 'code') $([bool]($out | Where-Object { $_ -like '!! cargo が終了コード 101*' })) $([bool]($out | Where-Object { $_ -like '  → merge の直後なら*' }))"
        }

        # 置き場の exe を替えたら、印 verified を作り直す (印の頭は確かめた exe の sha256)
        $lad = Join-Path $root 'lad8'
        $dir = Set-FakeExe -LocalAppData $lad -Key $key
        $null = Invoke-LauncherChild -LocalAppData $lad -RunnerArgs 'list' -BaseUrl 'http://127.0.0.1:9/'
        $firstMark = @(([IO.File]::ReadAllText((Join-Path $dir 'verified'))).Trim() -split '\s+')[0]
        Test-Case '通し: 印の頭は確かめた exe の sha256' $true { $firstMark -ceq (Get-DotfilesRunnerFileSha256 -Path (Join-Path $dir 'dotfiles-win.exe')) }
        [IO.File]::AppendAllText((Join-Path $dir 'dotfiles-win.exe'), "# changed`n")
        [IO.File]::WriteAllText((Join-Path $dir 'dotfiles-win.exe.sha256'), "$(Get-DotfilesRunnerFileSha256 -Path (Join-Path $dir 'dotfiles-win.exe'))  dotfiles-win.exe`n")
        $out = @(Invoke-LauncherChild -LocalAppData $lad -RunnerArgs 'list' -BaseUrl 'http://127.0.0.1:9/')
        Test-Case '通し: exe を替えたら version で確かめ直し、印を新しい exe のものにする' '5 True' {
            $mark = @(([IO.File]::ReadAllText((Join-Path $dir 'verified'))).Trim() -split '\s+')[0]
            "$(Get-ChildValue $out 'code') $($mark -ceq (Get-DotfilesRunnerFileSha256 -Path (Join-Path $dir 'dotfiles-win.exe')))"
        }

        # 手元の HTTP server (python3 -m http.server) から落とす。Linux では落とした物に実行の bit が無いので、version で起こせない (起こせないときの道を
        # 確かめる。起こせる道は Windows の CI の .github/scripts/win-runner-e2e.ps1)
        $python = Find-DotfilesRunnerApplication -Name 'python3'
        if (-not $python) {
            Write-Host 'skip 通し: 手元の HTTP server から落とす (python3 が要る)'
        } else {
            $serve = Join-Path $root 'serve'
            $tag = Get-DotfilesRunnerTag -Key $key
            $releaseBody = "release-exe-for-$key`n"
            foreach ($kind in @('good', 'bad')) {
                $rel = [IO.Path]::Combine($serve, $kind, $tag)
                $null = New-Item -ItemType Directory -Force -Path $rel
                [IO.File]::WriteAllText((Join-Path $rel 'dotfiles-win.exe'), $releaseBody)
                $sha = Get-DotfilesRunnerFileSha256 -Path (Join-Path $rel 'dotfiles-win.exe')
                if ($kind -eq 'bad') { $sha = '0' * 64 }
                [IO.File]::WriteAllText((Join-Path $rel 'dotfiles-win.exe.sha256'), "$sha  dotfiles-win.exe`n")
            }
            $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
            $listener.Start()
            $port = $listener.LocalEndpoint.Port
            $listener.Stop()
            $server = Start-Process -FilePath $python -ArgumentList @('-m', 'http.server', "$port", '--bind', '127.0.0.1', '--directory', $serve) -PassThru -RedirectStandardError (Join-Path $root 'server.err') -RedirectStandardOutput (Join-Path $root 'server.out')
            try {
                $base = "http://127.0.0.1:$port"
                $ready = $false
                for ($i = 0; ($i -lt 100) -and (-not $ready); $i++) {
                    try {
                        $null = Invoke-WebRequest -Uri "$base/good/$tag/dotfiles-win.exe.sha256" -UseBasicParsing -TimeoutSec 2
                        $ready = $true
                    } catch {
                        Start-Sleep -Milliseconds 100
                    }
                }
                Test-Case '通し (HTTP): 手元の HTTP server が答える' $true { $ready }
                $releaseSha = Get-DotfilesRunnerFileSha256 -Path ([IO.Path]::Combine($serve, 'good', $tag, 'dotfiles-win.exe'))

                # exe だけが置き場に残っている (.sha256 が無い): 残った exe を起こさず、落とした物で置き換える
                $lad = Join-Path $root 'lad-h1'
                $dir = Set-FakeExe -LocalAppData $lad -Key $key
                Remove-Item -LiteralPath (Join-Path $dir 'dotfiles-win.exe.sha256')
                $out = @(Invoke-LauncherChild -LocalAppData $lad -RunnerArgs 'list' -Mode 'exe' -BaseUrl "$base/good")
                Test-Case '通し (HTTP): exe だけが残っていれば、それを起こさず落とした物で置き換える' "0 True" {
                    "$(@($out | Where-Object { $_ -like 'fake-exe-args=*' }).Count) $((Get-DotfilesRunnerFileSha256 -Path (Join-Path $dir 'dotfiles-win.exe')) -ceq $releaseSha)"
                }
                Test-Case '通し (HTTP): 落とした物を起こせなければ (exe のモード) 2 で止まり、わけを出す' '2 True' {
                    "$(Get-ChildValue $out 'code') $([bool]($out | Where-Object { $_ -like '!! *exe を起こせない*' }))"
                }

                # 落とした物を起こせない (自動・cargo あり): cargo に回り、そう知らせる
                $lad = Join-Path $root 'lad-h2'
                $out = @(Invoke-LauncherChild -LocalAppData $lad -RunnerArgs 'check' -WithCargo -BaseUrl "$base/good")
                # 文字列の中の $( ) に、( の数の合わない引用符の字を書かない (PowerShell が $( ) の閉じを見失う)。先に変数に取る
                $toldCargo = [bool]($out | Where-Object { $_ -like '· 配った runner の exe を使えない (exe を起こせない*手元で build する (cargo)' })
                $downloaded = [bool]($out | Where-Object { $_ -like '==> runner の exe を落とす*' })
                Test-Case '通し (HTTP): 落として sha256 は合ったが起こせなければ、自動で cargo があれば cargo を打つ' '7 True True' {
                    "$(Get-ChildValue $out 'code') $toldCargo $downloaded"
                }
                Test-Case '通し (HTTP): 起こせなかった exe には印を置かない' $false { Test-Path -LiteralPath ([IO.Path]::Combine($lad, 'dotfiles', 'runner', $key, 'verified')) }

                # sha256 が合わない Release: cargo があっても打たずに 2。置き場に置かない
                $lad = Join-Path $root 'lad-h3'
                $out = @(Invoke-LauncherChild -LocalAppData $lad -RunnerArgs 'check' -WithCargo -BaseUrl "$base/bad")
                Test-Case '通し (HTTP): Release の sha256 が合わなければ、cargo があっても 2 で止まり、置かない' '2 0 False' {
                    "$(Get-ChildValue $out 'code') $(@($out | Where-Object { $_ -like 'cargo-*' }).Count) $(Test-Path -LiteralPath ([IO.Path]::Combine($lad, 'dotfiles', 'runner', $key, 'dotfiles-win.exe')))"
                }

                # Release が無い (404): cargo が無ければ直し方を出して 2
                $out = @(Invoke-LauncherChild -LocalAppData (Join-Path $root 'lad-h4') -RunnerArgs 'check' -BaseUrl "$base/none")
                Test-Case '通し (HTTP): Release が無ければ (404)、cargo が無いと直し方を出して 2' '2 True True' {
                    "$(Get-ChildValue $out 'code') $([bool]($out | Where-Object { $_ -like '*HTTP 404*' })) $([bool]($out | Where-Object { $_ -like '  → merge の直後なら*' }))"
                }
            } finally {
                if (-not $server.HasExited) { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue }
            }
        }
    } finally {
        $env:GIT_CONFIG_GLOBAL = $savedGit.GLOBAL
        $env:GIT_CONFIG_NOSYSTEM = $savedGit.NOSYSTEM
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($script:Failures -gt 0) {
    Write-Host "$($script:Failures) 件失敗"
    exit 1
}
Write-Host 'すべて通った'
