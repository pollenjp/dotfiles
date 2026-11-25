# win/powershell/Invoke-DotfilesSelfUpdate.ps1 (dotfiles --self-update の中身) のテスト。Pester は使わない (win/README.md の「PowerShell のテスト」)。
# 副作用の無い関数は dot-source して確かめ、clone を進める流れは、一時の HOME に作った本物の git の repo (remote は手元の bare の repo) で、子の pwsh に
# script か dotfiles 関数を流して確かめる (cargo は偽物の関数。本物の cargo もホームの clone も GitHub も触らない)。git の設定は一時の空のファイルにし
# (GIT_CONFIG_GLOBAL・GIT_CONFIG_NOSYSTEM)、手元の署名などの設定を読まない。git が PATH に無ければ、git を使う試験を飛ばす。
#
# WSL から流す (Linux の pwsh で動かすので、Windows 側には触らない):
#   nix shell --inputs-from ./nix nixpkgs#powershell --command pwsh -NoProfile -NonInteractive -File win/powershell/Invoke-DotfilesSelfUpdate.Tests.ps1
#
# ## 確かめること
#
#   - ファイル: BOM 付きの UTF-8 で、PowerShell 7 にしか無い書き方を使わない (Windows PowerShell 5.1 の dotfiles 関数からも呼ぶ)
#   - 引数: --self-update の直後の --dry-run・-h・--help を読み、- で始まらない最初の引数から後ろを runner の引数にする (runner の引数の中の
#     --dry-run は runner のもの)。知らない option は誤り (大文字小文字を区別する)
#   - GitHub の URL (ssh・ssh://・https) だけを gh の資格情報で通し、組は nix/lib/git-via-gh.nix と同じ (前に github.com の helper を空にする 1 組)
#   - 3 つの clone を fetch して fast-forward し、進めた commit を新しい順に出す。最新なら最新と出す。未追跡のファイルは数えない
#   - clone が無い・git の repo でない・未 commit の変更 (作業ツリー・index)・detached HEAD・upstream が無い・fetch が落ちた・fast-forward できない
#     (分かれた・進めると上書きされる未追跡のファイル) ものは ⚠ を出して進めず、ほかの clone は続け、終了コードは 1
#   - --dry-run は fetch だけして (remote-tracking の ref は進む)、進める commit を出し、HEAD も runner も動かさない
#   - runner の引数があれば、進めた後に dotfiles 関数と同じ場所 (win\runner) で同じ引数の cargo を打ち、終了コードは runner のもの (⚠ があれば
#     0 と 3 を 1 に)。⚠ は runner の出力の後にもう一度出す。runner が無ければ 2
#   - dotfiles.ps1 が変わったら、締めに新しい PowerShell を開くよう出す (配った写しが古い・無ければ、配ってから)。変わらなければ出さない
#   - 引数の誤りと --help では、何も fetch しない
#   - git に渡す環境変数 (GIT_TERMINAL_PROMPT・GCM_INTERACTIVE) と、今いる場所を戻す
#   - GitHub の remote の fetch には gh の資格情報の組を、どの git にもプロンプトを出させない環境変数を渡す (Linux だけ。git を包む偽物で、
#     打った引数と環境変数を見る)
#
# BOM 付きの UTF-8 で保存すること (win/README.md の「dotfiles.ps1 を書くときの注意」)。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Script = Join-Path $PSScriptRoot 'Invoke-DotfilesSelfUpdate.ps1'
$dotfiles = Join-Path $PSScriptRoot 'dotfiles.ps1'

# dot-source すると関数だけを読み、本体は走らない (Invoke-DotfilesSelfUpdate.ps1 の末尾)
. $Script

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

# ---------------------------------------------------------------------------
# ファイルそのもの
# ---------------------------------------------------------------------------

# Windows PowerShell 5.1 は BOM の無い UTF-8 を CP932 として読み、日本語の文字列が壊れる。BOM が 2 つ重なると、2 つ目が文字として残る
Test-Case 'BOM 付きの UTF-8 で保存してある (BOM は 1 つだけ)' 'EF BB BF 23 20' {
    $bytes = [IO.File]::ReadAllBytes($Script)
    ($bytes[0..4] | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
}

# dotfiles 関数は Windows PowerShell 5.1 でも読まれ、そこから呼ばれる。7 にしか無い書き方は 5.1 で構文エラーになり、何も動かない
Test-Case 'PowerShell 7 にしか無い書き方 (??・?.・三項演算子・&&・||・-AsHashtable) を使っていない' '' {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($Script, [ref]$tokens, [ref]$errors)
    $bad = @('QuestionQuestion', 'QuestionQuestionEquals', 'QuestionDot', 'QuestionLBracket', 'AndAnd', 'OrOr', 'QuestionMark')
    @($tokens | Where-Object { ("$($_.Kind)" -in $bad) -or ($_.Text -eq '-AsHashtable') } |
            ForEach-Object { "$($_.Text)@$($_.Extent.StartLineNumber)" }) -join ' '
}

Test-Case 'Join-Path に 3 つ目の引数を渡していない (5.1 は 2 つまで)' '' {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Script, [ref]$null, [ref]$null)
    @($ast.FindAll({
                param($n)
                ($n -is [System.Management.Automation.Language.CommandAst]) -and ($n.GetCommandName() -eq 'Join-Path') -and
                ($n.CommandElements.Count -gt 3)
            }, $true) | ForEach-Object { $_.Extent.StartLineNumber }) -join ' '
}

# ---------------------------------------------------------------------------
# 引数 (ConvertFrom-DotfilesSelfUpdateArgs)
# ---------------------------------------------------------------------------

function Format-Parsed {
    param([object[]]$Arguments)
    $p = ConvertFrom-DotfilesSelfUpdateArgs -Arguments $Arguments
    "dry=$($p.DryRun) help=$($p.Help) runner=[$(@($p.RunnerArgs) -join '|')] error=[$($p.Error)]"
}

Test-Case '引数: 何も無ければ更新だけ' 'dry=False help=False runner=[] error=[]' { Format-Parsed @() }
Test-Case '引数: --dry-run' 'dry=True help=False runner=[] error=[]' { Format-Parsed @('--dry-run') }
Test-Case '引数: - で始まらない最初の引数から後ろを runner の引数にする' 'dry=False help=False runner=[apply] error=[]' { Format-Parsed @('apply') }
Test-Case '引数: runner の引数の中の --dry-run は runner のもの (更新は dry-run にしない)' 'dry=False help=False runner=[apply|--dry-run] error=[]' {
    Format-Parsed @('apply', '--dry-run')
}
Test-Case '引数: --dry-run の後ろの runner の引数' 'dry=True help=False runner=[check|--steps|files,ntn] error=[]' { Format-Parsed @('--dry-run', 'check', '--steps', 'files,ntn') }
Test-Case '引数: runner の引数の中の - で始まる引数もそのまま' 'dry=False help=False runner=[import|--|-x] error=[]' { Format-Parsed @('import', '--', '-x') }
# script を直に呼んで --steps files,ntn と打つと、PowerShell が files,ntn を配列にする。dotfiles 関数と同じく , でつなぐ (空白でつながない)
Test-Case '引数: 配列の引数は , でつなぐ' 'dry=False help=False runner=[check|--steps|files,ntn] error=[]' { Format-Parsed @('check', '--steps', @('files', 'ntn')) }
Test-Case '引数: --self-update の重ねは読み捨てる' 'dry=False help=False runner=[list] error=[]' { Format-Parsed @('--self-update', 'list') }
Test-Case '引数: -h' 'dry=False help=True runner=[] error=[]' { Format-Parsed @('-h') }
Test-Case '引数: --help' 'dry=False help=True runner=[] error=[]' { Format-Parsed @('--help') }
Test-Case '引数: runner のコマンドより前の runner の option は誤り' 'dry=False help=False runner=[apply] error=[知らない option です: --force]' { Format-Parsed @('--force', 'apply') }
Test-Case '引数: 大文字小文字を区別する' 'dry=False help=False runner=[] error=[知らない option です: --Dry-Run]' { Format-Parsed @('--Dry-Run') }

# ---------------------------------------------------------------------------
# gh の資格情報 (Test-DotfilesGitHubUrl・Get-DotfilesGitHubConfigArguments)
# ---------------------------------------------------------------------------

Test-Case 'GitHub の URL: ssh' 'True' { Test-DotfilesGitHubUrl -Url 'git@github.com:pollenjp/dotfiles.git' }
Test-Case 'GitHub の URL: ssh://' 'True' { Test-DotfilesGitHubUrl -Url 'ssh://git@github.com/pollenjp/dotfiles.git' }
Test-Case 'GitHub の URL: https' 'True' { Test-DotfilesGitHubUrl -Url 'https://github.com/pollenjp/dotfiles.git' }
Test-Case 'GitHub の URL: 大文字小文字は問わない' 'True' { Test-DotfilesGitHubUrl -Url 'https://GitHub.com/pollenjp/dotfiles' }
Test-Case 'GitHub の URL: 手元のパスは違う' 'False' { Test-DotfilesGitHubUrl -Url '/tmp/remotes/dotfiles.git' }
Test-Case 'GitHub の URL: ほかのホストは違う' 'False' { Test-DotfilesGitHubUrl -Url 'git@gitlab.com:pollenjp/dotfiles.git' }
Test-Case 'GitHub の URL: github.com で始まる別のホストは違う' 'False' { Test-DotfilesGitHubUrl -Url 'https://github.com.example.invalid/pollenjp/dotfiles' }
Test-Case 'GitHub の URL: 空は違う' 'False' { Test-DotfilesGitHubUrl -Url '' }

Test-Case 'gh の組: github.com の helper を空にしてから gh を足し、GitHub の ssh の URL を https に読み替える (gh のパスは / にして一重引用符で囲む)' (
    "-c|credential.https://github.com.helper=|-c|credential.https://github.com.helper=!'C:/Program Files/GitHub CLI/gh.exe' auth git-credential|" +
    '-c|url.https://github.com/.insteadOf=git@github.com:|-c|url.https://github.com/.insteadOf=ssh://git@github.com/') {
    (Get-DotfilesGitHubConfigArguments -GhPath 'C:\Program Files\GitHub CLI\gh.exe') -join '|'
}
Test-Case 'gh の組: gh が無ければ helper を空にするだけ (Git Credential Manager を呼ばない)' (
    '-c|credential.https://github.com.helper=|-c|url.https://github.com/.insteadOf=git@github.com:|-c|url.https://github.com/.insteadOf=ssh://git@github.com/') {
    (Get-DotfilesGitHubConfigArguments -GhPath '') -join '|'
}

# Linux の git gh と Claude の env の組 (nix/lib/git-via-gh.nix) と同じか (あちらを直したら、こちらも直す)
$gitViaGh = [IO.File]::ReadAllText([IO.Path]::Combine((Split-Path -Parent (Split-Path -Parent $PSScriptRoot)), 'nix', 'lib', 'git-via-gh.nix'))
$gitViaGhPairs = @([regex]::Matches($gitViaGh, 'k = "([^"]+)";\s*v = "([^"]*)";') | ForEach-Object { "$($_.Groups[1].Value)=$($_.Groups[2].Value)" })
Test-Case 'gh の組: nix/lib/git-via-gh.nix と同じ組 (前に足す、helper を空にする 1 組と、gh のパスの引用符を除く)' (($gitViaGhPairs | Sort-Object) -join ' ') {
    $ours = @(Get-DotfilesGitHubConfigArguments -GhPath 'gh') | Where-Object { ($_ -ne '-c') -and ($_ -ne 'credential.https://github.com.helper=') } |
        ForEach-Object { $_ -replace "!'gh' ", '!gh ' }
    ($ours | Sort-Object) -join ' '
}

# ---------------------------------------------------------------------------
# 出す行 (Format-DotfilesCloneResult・Get-DotfilesProfileNotice)
# ---------------------------------------------------------------------------

function New-Result {
    param([string]$State, [int]$Count = 0, [string[]]$Log = @(), [string]$Message = '', [string[]]$Detail = @(), [int]$Ahead = 0, [string]$Branch = 'main')
    [pscustomobject]@{
        Name = 'dotfiles'; Directory = 'x'; State = $State; Branch = $Branch; Before = '1111111aaaa'; After = '2222222bbbb'; Count = $Count; Ahead = $Ahead
        Log = $Log; Message = $Message; Detail = $Detail; WatchChanged = $false
    }
}

$fifteen = @(1..15 | ForEach-Object { "c$_ subject $_" })
Test-Case '結果の行: 進めた commit は 15 まで出し、残りの数を出す' (@('✔ dotfiles (main): 17 commit 進めた (1111111 → 2222222)') + @($fifteen | ForEach-Object { "    $_" }) + @('    … ほか 2 commit') -join '|') {
    @(Format-DotfilesCloneResult -Result (New-Result -State 'updated' -Count 17 -Log $fifteen) | ForEach-Object { $_.Text }) -join '|'
}
Test-Case '結果の行: 進めたら緑' 'Green' { @(Format-DotfilesCloneResult -Result (New-Result -State 'updated' -Count 1 -Log @('a x')))[0].Color }
Test-Case '結果の行: --dry-run は進められる数を出す (色なし)' '· dotfiles (main): 1 commit 進められる (1111111 → 2222222。--dry-run なので進めない)|    a x|' {
    $l = @(Format-DotfilesCloneResult -Result (New-Result -State 'would-update' -Count 1 -Log @('a x')))
    "$(@($l | ForEach-Object { $_.Text }) -join '|')|$($l[0].Color)"
}
Test-Case '結果の行: 最新 (push していない commit があれば添える)' '✔ dotfiles (main): 最新 (push していない commit が 2)' {
    @(Format-DotfilesCloneResult -Result (New-Result -State 'current' -Ahead 2))[0].Text
}
Test-Case '結果の行: ⚠ は黄で、下に git の出力の終わりを出す' '⚠ dotfiles (main): fetch に失敗した → x|    git: fatal: a|    git: fatal: b|Yellow' {
    $l = @(Format-DotfilesCloneResult -Result (New-Result -State 'skipped' -Message 'fetch に失敗した → x' -Detail @('fatal: a', 'fatal: b')))
    "$(@($l | ForEach-Object { $_.Text }) -join '|')|$($l[0].Color)"
}
Test-Case '結果の行: branch が分かる前の ⚠ は名前だけ' '⚠ dotfiles: clone が無い' { @(Format-DotfilesCloneResult -Result (New-Result -State 'skipped' -Message 'clone が無い' -Branch ''))[0].Text }

$noticeDir = Join-Path ([IO.Path]::GetTempPath()) ("dotfiles-self-update-tests-" + [Guid]::NewGuid())
$null = New-Item -ItemType Directory -Force -Path $noticeDir
try {
    $newPs1 = Join-Path $noticeDir 'clone.ps1'
    $samePs1 = Join-Path $noticeDir 'same.ps1'
    $oldPs1 = Join-Path $noticeDir 'old.ps1'
    [IO.File]::WriteAllText($newPs1, "# v2`n")
    [IO.File]::WriteAllText($samePs1, "# v2`n")
    [IO.File]::WriteAllText($oldPs1, "# v1`n")
    $deploy = 'dotfiles apply で配ってから (受け持ちが WSL のホストは WSL の ~/dotfiles/setup --self-update --update)'
    Test-Case 'dotfiles.ps1: 配った写しが clone と同じなら、新しい PowerShell を開く' '※ dotfiles.ps1 が変わった (配った写しも新しい)。新しい PowerShell を開く (今の PowerShell の dotfiles 関数などは古いまま)' {
        Get-DotfilesProfileNotice -DryRun $false -CloneFile $newPs1 -DeployedFile $samePs1
    }
    Test-Case 'dotfiles.ps1: 配った写しが古ければ、配ってから新しい PowerShell を開く' "※ dotfiles.ps1 が変わった。配った写し ($oldPs1) はまだ古いので、$deploy、新しい PowerShell を開く (今の PowerShell の dotfiles 関数などは古いまま)" {
        Get-DotfilesProfileNotice -DryRun $false -CloneFile $newPs1 -DeployedFile $oldPs1
    }
    $missingPs1 = Join-Path $noticeDir 'missing.ps1'
    Test-Case 'dotfiles.ps1: 配った写しが無ければ、配ってから' "※ dotfiles.ps1 が変わった。配った写し ($missingPs1) はまだ古いので、$deploy、新しい PowerShell を開く (今の PowerShell の dotfiles 関数などは古いまま)" {
        Get-DotfilesProfileNotice -DryRun $false -CloneFile $newPs1 -DeployedFile $missingPs1
    }
    Test-Case 'dotfiles.ps1: --dry-run なら、進めると変わると出す' "※ 進めると dotfiles.ps1 も変わる。進めた後は、配った写し ($samePs1) を $deploy、新しい PowerShell を開く (今の PowerShell の dotfiles 関数などは古いまま)" {
        Get-DotfilesProfileNotice -DryRun $true -CloneFile $newPs1 -DeployedFile $samePs1
    }
} finally {
    Remove-Item -LiteralPath $noticeDir -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# clone を進める流れ (本物の git の repo で、子の pwsh に流す)
# ---------------------------------------------------------------------------

$names = @(Get-DotfilesCloneNames)
$realGit = @(Get-Command -Name git -CommandType Application -ErrorAction SilentlyContinue)
if ($realGit.Count -eq 0) {
    Write-Host 'skip clone を進める流れ (git が PATH に無い)'
} else {
    # 手元の git の設定 (署名・Git Credential Manager・autocrlf など) を読まない。子の pwsh にも、この環境変数のまま渡る
    $gitHome = Join-Path ([IO.Path]::GetTempPath()) ("dotfiles-self-update-tests-" + [Guid]::NewGuid())
    $null = New-Item -ItemType Directory -Force -Path $gitHome
    [IO.File]::WriteAllText((Join-Path $gitHome 'gitconfig'), '')
    $env:GIT_CONFIG_GLOBAL = Join-Path $gitHome 'gitconfig'
    $env:GIT_CONFIG_NOSYSTEM = '1'
    $env:GIT_AUTHOR_NAME = 'test'
    $env:GIT_AUTHOR_EMAIL = 'test@example.invalid'
    $env:GIT_COMMITTER_NAME = 'test'
    $env:GIT_COMMITTER_EMAIL = 'test@example.invalid'

    # git を打つ (落ちたら止める)
    function Invoke-TestGit {
        param([string[]]$Arguments)
        $ErrorActionPreference = 'Continue'
        $out = @(& git @Arguments 2>&1 | ForEach-Object { "$_" })
        if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' '): $($out -join ' / ')" }
        $out
    }

    function Write-TestFile {
        param([string]$Path, [string]$Text)
        $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path)
        [IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding $false))
    }

    # 一時の HOME に、3 つの repo の remote (bare) と、それを clone した ghq の clone を作る。seed は remote に commit を足すための作業場。
    # dotfiles には runner の Cargo.toml (-NoRunner なら無し)・dotfiles.ps1・この script の写し (dotfiles 関数が clone の中から呼ぶ) を置く
    function New-Fixture {
        param([switch]$NoRunner)
        $root = Join-Path ([IO.Path]::GetTempPath()) ("dotfiles-self-update-tests-" + [Guid]::NewGuid())
        $fx = [pscustomobject]@{
            Root    = $root
            Home    = Join-Path $root 'home'
            Remotes = Join-Path $root 'remotes'
            Seeds   = Join-Path $root 'seeds'
            Clones  = [IO.Path]::Combine($root, 'home', 'ghq', 'github.com', 'pollenjp')
        }
        foreach ($n in $names) {
            $bare = Join-Path $fx.Remotes "$n.git"
            $seed = Join-Path $fx.Seeds $n
            $null = Invoke-TestGit @('init', '--quiet', '--bare', '--initial-branch=main', $bare)
            $null = Invoke-TestGit @('init', '--quiet', '--initial-branch=main', $seed)
            Write-TestFile (Join-Path $seed 'README.md') "$n v1`n"
            if ($n -eq 'dotfiles') {
                if (-not $NoRunner) { Write-TestFile ([IO.Path]::Combine($seed, 'win', 'runner', 'Cargo.toml')) "[package]`n" }
                Write-TestFile ([IO.Path]::Combine($seed, 'win', 'powershell', 'dotfiles.ps1')) "# v1`n"
                Copy-Item -LiteralPath $Script -Destination ([IO.Path]::Combine($seed, 'win', 'powershell', 'Invoke-DotfilesSelfUpdate.ps1'))
            }
            $null = Invoke-TestGit @('-C', $seed, 'add', '--all')
            $null = Invoke-TestGit @('-C', $seed, 'commit', '--quiet', '-m', "$n 1")
            $null = Invoke-TestGit @('-C', $seed, 'remote', 'add', 'origin', $bare)
            $null = Invoke-TestGit @('-C', $seed, 'push', '--quiet', '-u', 'origin', 'main')
            $null = Invoke-TestGit @('clone', '--quiet', $bare, (Join-Path $fx.Clones $n))
        }
        $fx
    }

    # remote に commit を 1 つ足す (seed で書いて push)。足した commit の SHA を返す
    function Add-RemoteCommit {
        param($Fixture, [string]$Name, [string]$Path, [string]$Text, [string]$Message)
        $seed = Join-Path $Fixture.Seeds $Name
        Write-TestFile (Join-Path $seed $Path) $Text
        $null = Invoke-TestGit @('-C', $seed, 'add', '--all')
        $null = Invoke-TestGit @('-C', $seed, 'commit', '--quiet', '-m', $Message)
        $null = Invoke-TestGit @('-C', $seed, 'push', '--quiet', 'origin', 'main')
        @(Invoke-TestGit @('-C', $seed, 'rev-parse', 'HEAD'))[0]
    }

    function Get-Rev {
        param([string]$Directory, [string]$Rev = 'HEAD')
        @(Invoke-TestGit @('-C', $Directory, 'rev-parse', $Rev))[0]
    }

    # git log の %h (進めた commit の行の頭)
    function Get-Abbrev {
        param($Fixture, [string]$Name, [string]$Sha)
        @(Invoke-TestGit @('-C', (Join-Path $Fixture.Seeds $Name), 'log', '--format=%h', '-n', '1', $Sha))[0]
    }

    function Get-Short { param([string]$Sha) $Sha.Substring(0, 7) }

    function Remove-Fixture { param($Fixture) Remove-Item -LiteralPath $Fixture.Root -Recurse -Force -ErrorAction SilentlyContinue }

    # 子の pwsh で $Command を流す (HOME・USERPROFILE は fixture の home、NO_COLOR は 1)。cargo は、打たれた場所と引数を出して
    # -CargoExit を終了コードにする偽物の関数。$Command の中では $Script が script のパス、$Dotfiles が dotfiles.ps1 のパス。git に渡す
    # 環境変数は印の値にしておき、戻したかを見る。-PathPrefix は PATH の前に足すディレクトリ (git を包む偽物)
    function Invoke-SelfUpdateChild {
        param($Fixture, [string]$Command, [int]$CargoExit = 0, [string]$PathPrefix = '')
        $child = Join-Path $Fixture.Root 'child.ps1'
        $body = @(
            'param([string]$Script, [string]$Dotfiles, [string]$PathPrefix)'
            'if ($PathPrefix) { $env:PATH = $PathPrefix + [IO.Path]::PathSeparator + $env:PATH }'
            'function cargo { "cargo-cwd=$((Get-Location).Path)"; "cargo-args=$($args -join ''|'')"; $global:LASTEXITCODE = [int]$env:FAKE_CARGO_EXIT }'
            '$env:GIT_TERMINAL_PROMPT = ''sentinel-prompt'''
            '$env:GCM_INTERACTIVE = ''sentinel-gcm'''
            'Set-Location -LiteralPath $HOME'
            '$global:LASTEXITCODE = 0'
            $Command
            '"code=$LASTEXITCODE"'
            '"after=$((Get-Location).Path)"'
            '"env-after=$env:GIT_TERMINAL_PROMPT $env:GCM_INTERACTIVE"'
        ) -join "`n"
        Set-Content -LiteralPath $child -Value $body -Encoding utf8
        $saved = @{ HOME = $env:HOME; USERPROFILE = $env:USERPROFILE; NO_COLOR = $env:NO_COLOR; FAKE_CARGO_EXIT = $env:FAKE_CARGO_EXIT }
        # Windows PowerShell 5.1 は外のコマンドに空の文字列の引数を渡さないので、空の -PathPrefix は渡さない。Stop のままだと、子の stderr の
        # 1 行目で止まる
        $ErrorActionPreference = 'Continue'
        try {
            $env:HOME = $Fixture.Home
            $env:USERPROFILE = $Fixture.Home
            $env:NO_COLOR = '1'
            $env:FAKE_CARGO_EXIT = "$CargoExit"
            $childArgs = @('-NoProfile', '-NonInteractive', '-File', $child, '-Script', $Script, '-Dotfiles', $dotfiles)
            if ($PathPrefix) { $childArgs += @('-PathPrefix', $PathPrefix) }
            $pwsh = (Get-Process -Id $PID).Path
            & $pwsh @childArgs 2>&1 | ForEach-Object { "$_" }
        } finally {
            $env:HOME = $saved.HOME
            $env:USERPROFILE = $saved.USERPROFILE
            $env:NO_COLOR = $saved.NO_COLOR
            $env:FAKE_CARGO_EXIT = $saved.FAKE_CARGO_EXIT
        }
    }

    # 子の出力から「<名前>=…」の行の値を取る
    function Get-ChildValue {
        param([string[]]$Lines, [string]$Name)
        $line = @($Lines | Where-Object { $_.StartsWith("$Name=", [System.StringComparison]::Ordinal) })
        if ($line.Count -eq 0) { return "(${Name}= の行が無い)" }
        $line[0].Substring($Name.Length + 1)
    }

    # 子の出力から、clone の結果の行 (頭の印 ✔・·・⚠ の後ろが <名前>) と、その下の字下げした行を、初めの 1 組だけ取る
    function Get-CloneLines {
        param([string[]]$Lines, [string]$Name)
        $found = @()
        $in = $false
        foreach ($l in $Lines) {
            if ($l -match '^(✔|·|⚠) ([^\s:]+)[ :]') {
                if ($in) { break }
                $in = ($Matches[2] -ceq $Name)
                if ($in) { $found += $l }
                continue
            }
            if ($in) {
                if ($l.StartsWith('    ', [System.StringComparison]::Ordinal)) { $found += $l } else { break }
            }
        }
        $found -join '|'
    }

    # 行の場所 (無ければ -1)
    function Get-LineIndex {
        param([string[]]$Lines, [string]$Pattern, [int]$From = 0)
        for ($i = $From; $i -lt $Lines.Count; $i++) { if ($Lines[$i] -clike $Pattern) { return $i } }
        -1
    }

    $heading = '==> dotfiles --self-update: 3 つの clone を進める (fetch して fast-forward。GitHub の remote は gh の資格情報で HTTPS を通す)'

    # --- 3 つとも遅れている: 進め、進めた commit を出す。dotfiles.ps1 が変わり、配った写しが無いので、配ってから新しい PowerShell を開く
    $fx = New-Fixture
    try {
        $start = @{}
        foreach ($n in $names) { $start[$n] = Get-Rev (Join-Path $fx.Clones $n) }
        $d1 = Add-RemoteCommit $fx 'dotfiles' 'win/powershell/dotfiles.ps1' "# v2`n" 'dotfiles 2: dotfiles.ps1 を直す'
        $d2 = Add-RemoteCommit $fx 'dotfiles' 'docs.txt' "docs`n" 'dotfiles 3'
        $p1 = Add-RemoteCommit $fx 'dotfiles-private' 'README.md' "v2`n" 'private 2'
        $c1 = Add-RemoteCommit $fx 'claude-skills' 'README.md' "v2`n" 'skills 2'
        Write-TestFile (Join-Path (Join-Path $fx.Clones 'dotfiles-private') 'untracked.txt') "x`n"
        $out = @(Invoke-SelfUpdateChild -Fixture $fx -Command '& $Script')
        Test-Case '進める: 見出し' $heading { $out | Where-Object { $_ -clike '==> *' } }
        Test-Case '進める: dotfiles を 2 commit 進め、進めた commit を新しい順に出す' (@(
                "✔ dotfiles (main): 2 commit 進めた ($(Get-Short $start['dotfiles']) → $(Get-Short $d2))"
                "    $(Get-Abbrev $fx 'dotfiles' $d2) dotfiles 3"
                "    $(Get-Abbrev $fx 'dotfiles' $d1) dotfiles 2: dotfiles.ps1 を直す"
            ) -join '|') { Get-CloneLines $out 'dotfiles' }
        Test-Case '進める: 未追跡のファイルがあっても進める (数えない)' "✔ dotfiles-private (main): 1 commit 進めた ($(Get-Short $start['dotfiles-private']) → $(Get-Short $p1))|    $(Get-Abbrev $fx 'dotfiles-private' $p1) private 2" {
            Get-CloneLines $out 'dotfiles-private'
        }
        Test-Case '進める: 3 つの clone の HEAD が remote の main になる' "$d2 $p1 $c1" { @($names | ForEach-Object { Get-Rev (Join-Path $fx.Clones $_) }) -join ' ' }
        $deployed = [IO.Path]::Combine($fx.Home, '.config', 'powershell', 'dotfiles.ps1')
        Test-Case '進める: dotfiles.ps1 が変わり、配った写しが無ければ、配ってから新しい PowerShell を開くと締めに出す' "※ dotfiles.ps1 が変わった。配った写し ($deployed) はまだ古いので、dotfiles apply で配ってから (受け持ちが WSL のホストは WSL の ~/dotfiles/setup --self-update --update)、新しい PowerShell を開く (今の PowerShell の dotfiles 関数などは古いまま)" {
            $out | Where-Object { $_ -clike '※ *' }
        }
        Test-Case '進める: 締めの行は最後の行' $true { (Get-LineIndex $out '※ *') -eq ((Get-LineIndex $out 'code=*') - 1) }
        Test-Case '進める: runner の引数が無ければ cargo を打たない' 0 { @($out | Where-Object { $_ -like 'cargo-*' }).Count }
        Test-Case '進める: 終了コードは 0' '0' { Get-ChildValue $out 'code' }
        Test-Case '進める: git に渡した環境変数を戻す' 'sentinel-prompt sentinel-gcm' { Get-ChildValue $out 'env-after' }
        Test-Case '進める: 今いる場所は動かない' $fx.Home { Get-ChildValue $out 'after' }

        # もう一度流すと、どれも最新。dotfiles.ps1 は変わらないので締めの行を出さない
        $again = @(Invoke-SelfUpdateChild -Fixture $fx -Command '& $Script')
        Test-Case '進める: 最新なら最新と出す' '✔ dotfiles (main): 最新|✔ dotfiles-private (main): 最新|✔ claude-skills (main): 最新' {
            @($names | ForEach-Object { Get-CloneLines $again $_ }) -join '|'
        }
        Test-Case '進める: dotfiles.ps1 が変わらなければ締めの行を出さない' 0 { @($again | Where-Object { $_ -clike '※ *' }).Count }
        Test-Case '進める: 最新でも終了コードは 0' '0' { Get-ChildValue $again 'code' }
    } finally {
        Remove-Fixture $fx
    }

    # --- 進めないもの (1): 未 commit の変更 (作業ツリー)・detached HEAD。ほかの clone は続ける
    $fx = New-Fixture
    try {
        $private = Join-Path $fx.Clones 'dotfiles-private'
        $skills = Join-Path $fx.Clones 'claude-skills'
        $startPrivate = Get-Rev $private
        $startSkills = Get-Rev $skills
        $null = Add-RemoteCommit $fx 'dotfiles-private' 'README.md' "v2`n" 'private 2'
        $null = Add-RemoteCommit $fx 'claude-skills' 'README.md' "v2`n" 'skills 2'
        Write-TestFile (Join-Path $private 'README.md') "local`n"
        $null = Invoke-TestGit @('-C', $skills, 'switch', '--quiet', '--detach')
        $out = @(Invoke-SelfUpdateChild -Fixture $fx -Command '& $Script')
        Test-Case '進めない: 遅れていない clone は最新' '✔ dotfiles (main): 最新' { Get-CloneLines $out 'dotfiles' }
        Test-Case '進めない: 未 commit の変更 (作業ツリー) があれば進めない' "⚠ dotfiles-private (main): 未 commit の変更があるので進めない → git -C '$private' status で見て、commit するか退けてから打ち直す" {
            Get-CloneLines $out 'dotfiles-private'
        }
        Test-Case '進めない: detached HEAD なら進めない' "⚠ claude-skills: detached HEAD なので進めない → branch に switch してから打ち直す (git -C '$skills' switch main など)" {
            Get-CloneLines $out 'claude-skills'
        }
        Test-Case '進めない: 進めなかった clone の HEAD は動かない' "$startPrivate $startSkills" { "$(Get-Rev $private) $(Get-Rev $skills)" }
        # ⚠️ (U+26A0 U+FE0F) の行は Ordinal で見る (-clike は文化に沿って比べ、U+FE0F を無視して ⚠ の行にも当たる)
        Test-Case '進めない: 締めに、進めなかった clone を出す' '⚠️ 進めなかった clone がある (dotfiles-private・claude-skills) → ⚠ の行のとおりに直して、dotfiles --self-update を打ち直す ⚠️' {
            $out | Where-Object { $_.StartsWith('⚠️ ', [System.StringComparison]::Ordinal) }
        }
        Test-Case '進めない: runner を流さなければ ⚠ を繰り返さない' 0 { @($out | Where-Object { $_ -clike '==> 進めなかった clone*' }).Count }
        Test-Case '進めない: 終了コードは 1' '1' { Get-ChildValue $out 'code' }
    } finally {
        Remove-Fixture $fx
    }

    # --- 進めないもの (2): upstream が無い・未 commit の変更 (index)・分かれた
    $fx = New-Fixture
    try {
        $dot = Join-Path $fx.Clones 'dotfiles'
        $private = Join-Path $fx.Clones 'dotfiles-private'
        $skills = Join-Path $fx.Clones 'claude-skills'
        foreach ($n in $names) { $null = Add-RemoteCommit $fx $n 'more.txt' "more`n" "$n 2" }
        $null = Invoke-TestGit @('-C', $dot, 'switch', '--quiet', '-c', 'local-only')
        Write-TestFile (Join-Path $private 'README.md') "staged`n"
        $null = Invoke-TestGit @('-C', $private, 'add', 'README.md')
        $null = Invoke-TestGit @('-C', $skills, 'commit', '--quiet', '--allow-empty', '-m', 'local')
        $startSkills = Get-Rev $skills
        $out = @(Invoke-SelfUpdateChild -Fixture $fx -Command '& $Script')
        Test-Case '進めない: upstream が無ければ進めない' "⚠ dotfiles (local-only): upstream が無いので進めない → git -C '$dot' branch --set-upstream-to=origin/local-only で付けるか、upstream のある branch に switch する" {
            Get-CloneLines $out 'dotfiles'
        }
        Test-Case '進めない: 未 commit の変更 (index) があれば進めない' "⚠ dotfiles-private (main): 未 commit の変更があるので進めない → git -C '$private' status で見て、commit するか退けてから打ち直す" {
            Get-CloneLines $out 'dotfiles-private'
        }
        Test-Case '進めない: 分かれていれば (fast-forward できなければ) 進めない' '⚠ claude-skills (main): fast-forward できない (ローカルにだけ 1 commit・upstream にだけ 1 commit) → merge か rebase を自分で' {
            Get-CloneLines $out 'claude-skills'
        }
        Test-Case '進めない: 分かれた clone の HEAD は動かない' $startSkills { Get-Rev $skills }
        Test-Case '進めない: 3 つとも進めなければ終了コードは 1' '1' { Get-ChildValue $out 'code' }
    } finally {
        Remove-Fixture $fx
    }

    # --- 進めないもの (3): fetch が落ちた・進めると上書きされる未追跡のファイル・clone が無い
    $fx = New-Fixture
    try {
        $dot = Join-Path $fx.Clones 'dotfiles'
        $private = Join-Path $fx.Clones 'dotfiles-private'
        $skills = Join-Path $fx.Clones 'claude-skills'
        $missingRemote = Join-Path $fx.Remotes 'missing.git'
        $null = Invoke-TestGit @('-C', $dot, 'remote', 'set-url', 'origin', $missingRemote)
        $startPrivate = Get-Rev $private
        $p1 = Add-RemoteCommit $fx 'dotfiles-private' 'new.txt' "remote`n" 'private 2'
        Write-TestFile (Join-Path $private 'new.txt') "local`n"
        Remove-Item -LiteralPath $skills -Recurse -Force
        $out = @(Invoke-SelfUpdateChild -Fixture $fx -Command '& $Script')
        Test-Case '進めない: fetch が落ちたら進めない (手元の remote なら、オフラインの案内)' '⚠ dotfiles (main): fetch に失敗した → オフラインなら、つながってから打ち直す' {
            @(Get-CloneLines $out 'dotfiles') -split '\|' | Select-Object -First 1
        }
        Test-Case '進めない: fetch が落ちたら、下に git の出力の終わりを出す' $true { [bool](@((Get-CloneLines $out 'dotfiles') -split '\|') | Where-Object { $_ -clike '    git: *' }) }
        Test-Case '進めない: 進めると上書きされる未追跡のファイルがあれば進めない' "⚠ dotfiles-private (main): fast-forward できなかった (進めると上書きされる未追跡のファイルがあるなど) → git -C '$private' merge --ff-only origin/main を打って見る" {
            @(Get-CloneLines $out 'dotfiles-private') -split '\|' | Select-Object -First 1
        }
        Test-Case '進めない: fast-forward できなかった clone の HEAD は動かないが、fetch はしてある' "$startPrivate $p1" { "$(Get-Rev $private) $(Get-Rev $private 'origin/main')" }
        Test-Case '進めない: clone が無ければ進めない' "⚠ claude-skills: clone が無い ($skills) → win\bootstrap\Install-Bootstrap.ps1 で clone する" { Get-CloneLines $out 'claude-skills' }
        Test-Case '進めない: 終了コードは 1' '1' { Get-ChildValue $out 'code' }
    } finally {
        Remove-Fixture $fx
    }

    # --- --dry-run: fetch だけして進める commit を出し、HEAD も runner も動かさない。git の repo でない・push していない commit も見る
    $fx = New-Fixture
    try {
        $dot = Join-Path $fx.Clones 'dotfiles'
        $private = Join-Path $fx.Clones 'dotfiles-private'
        $skills = Join-Path $fx.Clones 'claude-skills'
        $startDot = Get-Rev $dot
        $d1 = Add-RemoteCommit $fx 'dotfiles' 'win/powershell/dotfiles.ps1' "# v2`n" 'dotfiles 2'
        Remove-Item -LiteralPath $private -Recurse -Force
        $null = New-Item -ItemType Directory -Force -Path $private
        $null = Invoke-TestGit @('-C', $skills, 'commit', '--quiet', '--allow-empty', '-m', 'local')
        $out = @(Invoke-SelfUpdateChild -Fixture $fx -Command '& $Script --dry-run apply')
        Test-Case '--dry-run: 見出し' '==> dotfiles --self-update --dry-run: 3 つの clone の進める commit を出す (fetch だけ。fast-forward も runner もしない)' { $out | Where-Object { $_ -clike '==> *' } }
        Test-Case '--dry-run: 進められる commit を出す' "· dotfiles (main): 1 commit 進められる ($(Get-Short $startDot) → $(Get-Short $d1)。--dry-run なので進めない)|    $(Get-Abbrev $fx 'dotfiles' $d1) dotfiles 2" {
            Get-CloneLines $out 'dotfiles'
        }
        Test-Case '--dry-run: HEAD は動かさないが、fetch はする (remote-tracking の ref は進む)' "$startDot $d1" { "$(Get-Rev $dot) $(Get-Rev $dot 'origin/main')" }
        Test-Case '--dry-run: git の repo でなければ進めない' "⚠ dotfiles-private: git の repo でない ($private) → 退けてから win\bootstrap\Install-Bootstrap.ps1 で clone し直す" { Get-CloneLines $out 'dotfiles-private' }
        Test-Case '--dry-run: push していない commit だけなら最新' '✔ claude-skills (main): 最新 (push していない commit が 1)' { Get-CloneLines $out 'claude-skills' }
        Test-Case '--dry-run: runner は流さない' '· --dry-run なので runner は流さない (進めてから流すなら、--dry-run を外す: dotfiles --self-update apply)|0' {
            "$($out | Where-Object { $_ -clike '· --dry-run *' })|$(@($out | Where-Object { $_ -like 'cargo-*' }).Count)"
        }
        $deployed = [IO.Path]::Combine($fx.Home, '.config', 'powershell', 'dotfiles.ps1')
        Test-Case '--dry-run: dotfiles.ps1 が変わるなら、進めると変わると出す' "※ 進めると dotfiles.ps1 も変わる。進めた後は、配った写し ($deployed) を dotfiles apply で配ってから (受け持ちが WSL のホストは WSL の ~/dotfiles/setup --self-update --update)、新しい PowerShell を開く (今の PowerShell の dotfiles 関数などは古いまま)" {
            $out | Where-Object { $_ -clike '※ *' }
        }
        Test-Case '--dry-run: 進めない clone があれば終了コードは 1' '1' { Get-ChildValue $out 'code' }
    } finally {
        Remove-Fixture $fx
    }

    # --- dotfiles 関数から: 進めた後に runner に渡す (dotfiles 関数と同じ場所と引数)。配った写しが新しければ、新しい PowerShell を開くだけ
    $fx = New-Fixture
    try {
        $d1 = Add-RemoteCommit $fx 'dotfiles' 'win/powershell/dotfiles.ps1' "# v2`n" 'dotfiles 2'
        Write-TestFile ([IO.Path]::Combine($fx.Home, '.config', 'powershell', 'dotfiles.ps1')) "# v2`n"
        $out = @(Invoke-SelfUpdateChild -Fixture $fx -Command '. $Dotfiles; dotfiles --self-update check --steps files,ntn' -CargoExit 3)
        $runnerDir = [IO.Path]::Combine($fx.Clones, 'dotfiles', 'win', 'runner')
        # 文字列の中の $( ) に、( の数の合わない引用符の字を書かない (PowerShell が $( ) の閉じを見失う)
        $dotAdvanced = @((Get-CloneLines $out 'dotfiles') -split '\|')[0] -clike '✔ dotfiles (main): 1 commit 進めた (*'
        Test-Case 'dotfiles 関数: 進めてから runner に渡す' "True|$runnerDir|run|--quiet|--release|--locked|--|check|--steps|files,ntn" {
            "$dotAdvanced|$(Get-ChildValue $out 'cargo-cwd')|$(Get-ChildValue $out 'cargo-args')"
        }
        Test-Case 'dotfiles 関数: runner は clone を進めた後に流す' $true { (Get-LineIndex $out '✔ claude-skills*') -lt (Get-LineIndex $out 'cargo-cwd=*') }
        Test-Case 'dotfiles 関数: 終了コードは runner のもの' '3' { Get-ChildValue $out 'code' }
        Test-Case 'dotfiles 関数: 配った写しが clone と同じなら、新しい PowerShell を開くだけ' '※ dotfiles.ps1 が変わった (配った写しも新しい)。新しい PowerShell を開く (今の PowerShell の dotfiles 関数などは古いまま)' {
            $out | Where-Object { $_ -clike '※ *' }
        }
        Test-Case 'dotfiles 関数: 締めの行は runner の出力の後' $true { (Get-LineIndex $out 'cargo-args=*') -lt (Get-LineIndex $out '※ *') }
        Test-Case 'dotfiles 関数: 今いる場所と、git に渡した環境変数を戻す' "$($fx.Home)|sentinel-prompt sentinel-gcm" { "$(Get-ChildValue $out 'after')|$(Get-ChildValue $out 'env-after')" }

        # --self-update なしの dotfiles 関数と同じ場所で、同じ引数を runner に渡す (script の末尾の cargo の行と dotfiles 関数の突き合わせ)
        $plain = @(Invoke-SelfUpdateChild -Fixture $fx -Command '. $Dotfiles; dotfiles check --steps files,ntn')
        Test-Case 'dotfiles 関数: --self-update の runner は、--self-update なしと同じ場所・同じ引数で打つ' "$(Get-ChildValue $plain 'cargo-cwd')|$(Get-ChildValue $plain 'cargo-args')" {
            "$(Get-ChildValue $out 'cargo-cwd')|$(Get-ChildValue $out 'cargo-args')"
        }
    } finally {
        Remove-Fixture $fx
    }

    # --- 進めない clone があって runner を流したら、runner の出力の後に ⚠ をもう一度出し、終了コードの 0 と 3 を 1 にする (2 はそのまま)
    $fx = New-Fixture
    try {
        $private = Join-Path $fx.Clones 'dotfiles-private'
        Write-TestFile (Join-Path $private 'README.md') "local`n"
        $out = @(Invoke-SelfUpdateChild -Fixture $fx -Command '& $Script list' -CargoExit 0)
        $warn = "⚠ dotfiles-private (main): 未 commit の変更があるので進めない → git -C '$private' status で見て、commit するか退けてから打ち直す"
        $first = Get-LineIndex $out $warn
        $repeat = Get-LineIndex $out '==> 進めなかった clone (上の ⚠ と同じ)'
        Test-Case 'runner と ⚠: runner は進めない clone があっても流す' 'list' { Get-ChildValue $out 'cargo-args' | ForEach-Object { ($_ -split '\|')[-1] } }
        Test-Case 'runner と ⚠: ⚠ を runner の出力の後にもう一度出す' $true {
            ($first -ge 0) -and ($first -lt (Get-LineIndex $out 'cargo-cwd=*')) -and ($repeat -gt (Get-LineIndex $out 'cargo-args=*')) -and ($out[$repeat + 1] -ceq $warn)
        }
        Test-Case 'runner と ⚠: runner が 0 でも、進めない clone があれば 1' '1' { Get-ChildValue $out 'code' }
        $three = @(Invoke-SelfUpdateChild -Fixture $fx -Command '& $Script list' -CargoExit 3)
        Test-Case 'runner と ⚠: runner が 3 でも、進めない clone があれば 1' '1' { Get-ChildValue $three 'code' }
        $two = @(Invoke-SelfUpdateChild -Fixture $fx -Command '& $Script list' -CargoExit 2)
        Test-Case 'runner と ⚠: runner が 2 ならそのまま' '2' { Get-ChildValue $two 'code' }
    } finally {
        Remove-Fixture $fx
    }

    # --- runner が無ければ、進めた後に知らせて 2
    $fx = New-Fixture -NoRunner
    try {
        $out = @(Invoke-SelfUpdateChild -Fixture $fx -Command '& $Script apply')
        $runnerDir = [IO.Path]::Combine($fx.Clones, 'dotfiles', 'win', 'runner')
        Test-Case 'runner が無い: 知らせて cargo を打たない' "dotfiles の runner がありません: $runnerDir (先に win\bootstrap\Install-Bootstrap.ps1 で clone する)|0" {
            "$($out | Where-Object { $_ -clike 'dotfiles の runner がありません*' })|$(@($out | Where-Object { $_ -like 'cargo-*' }).Count)"
        }
        Test-Case 'runner が無い: 終了コードは 2' '2' { Get-ChildValue $out 'code' }
    } finally {
        Remove-Fixture $fx
    }

    # --- 引数の誤りと --help: 何も fetch しない
    $fx = New-Fixture
    try {
        $dot = Join-Path $fx.Clones 'dotfiles'
        $startTracking = Get-Rev $dot 'origin/main'
        $null = Add-RemoteCommit $fx 'dotfiles' 'more.txt' "more`n" 'dotfiles 2'
        $out = @(Invoke-SelfUpdateChild -Fixture $fx -Command '& $Script --force apply')
        Test-Case '引数の誤り: 誤りと使い方を出す' 'dotfiles --self-update: 知らない option です: --force|使い方: dotfiles --self-update [--dry-run] [<runner の引数>…]' {
            "$($out | Where-Object { $_ -clike 'dotfiles --self-update: *' })|$($out | Where-Object { $_ -clike '使い方: *' })"
        }
        Test-Case '引数の誤り: 何も fetch せず、runner も流さない' "$startTracking|0" { "$(Get-Rev $dot 'origin/main')|$(@($out | Where-Object { $_ -like 'cargo-*' }).Count)" }
        Test-Case '引数の誤り: 終了コードは 2' '2' { Get-ChildValue $out 'code' }
        $help = @(Invoke-SelfUpdateChild -Fixture $fx -Command '& $Script --help')
        Test-Case '--help: 使い方を出し、何も fetch しない' "使い方: dotfiles --self-update [--dry-run] [<runner の引数>…]|0|$startTracking" {
            "$($help | Where-Object { $_ -clike '使い方: *' })|$(@($help | Where-Object { $_ -clike '==> *' }).Count)|$(Get-Rev $dot 'origin/main')"
        }
        Test-Case '--help: 終了コードは 0' '0' { Get-ChildValue $help 'code' }
    } finally {
        Remove-Fixture $fx
    }

    # --- GitHub の remote は gh の資格情報で通す (Linux だけ: git を包む偽物が、打った引数と環境変数を控える)。dotfiles の origin を GitHub の
    # ssh の URL にし、clone の設定の insteadOf (長い接頭辞の方が勝つ) で手元の bare の repo へ向ける (GitHub には出ない)
    if ($PSVersionTable.PSVersion.Major -ge 6 -and $IsLinux) {
        $fx = New-Fixture
        try {
            $bin = Join-Path $fx.Root 'bin'
            $log = Join-Path $fx.Root 'git.log'
            $gitPath = $realGit[0].Path
            Write-TestFile (Join-Path $bin 'git') ("#!/bin/sh`nprintf '%s\n' ""`$*"" >> '$log'`nprintf 'env %s %s\n' ""`$GIT_TERMINAL_PROMPT"" ""`$GCM_INTERACTIVE"" >> '$log'`nexec '$gitPath' ""`$@""`n")
            Write-TestFile (Join-Path $bin 'gh') "#!/bin/sh`nexit 1`n"
            & chmod '+x' (Join-Path $bin 'git') (Join-Path $bin 'gh')
            $dot = Join-Path $fx.Clones 'dotfiles'
            $private = Join-Path $fx.Clones 'dotfiles-private'
            $null = Invoke-TestGit @('-C', $dot, 'remote', 'set-url', 'origin', 'git@github.com:pollenjp/dotfiles.git')
            $null = Invoke-TestGit @('-C', $dot, 'config', "url.$($fx.Remotes)/.insteadOf", 'git@github.com:pollenjp/')
            $d1 = Add-RemoteCommit $fx 'dotfiles' 'more.txt' "more`n" 'dotfiles 2'
            $out = @(Invoke-SelfUpdateChild -Fixture $fx -Command '& $Script' -PathPrefix $bin)
            $calls = @(Get-Content -LiteralPath $log)
            Test-Case 'gh の資格情報: GitHub の remote の fetch に gh の組を渡す' "-c credential.https://github.com.helper= -c credential.https://github.com.helper=!'$bin/gh' auth git-credential -c url.https://github.com/.insteadOf=git@github.com: -c url.https://github.com/.insteadOf=ssh://git@github.com/ -C $dot fetch --quiet origin refs/heads/main" {
                $calls | Where-Object { $_ -clike "* -C $dot fetch *" }
            }
            Test-Case 'gh の資格情報: 手元の remote の fetch には gh の組を渡さない' "-C $private fetch --quiet origin refs/heads/main" { $calls | Where-Object { $_ -clike "* -C $private fetch *" -or $_ -clike "-C $private fetch *" } }
            Test-Case 'gh の資格情報: どの git にもプロンプトを出させない環境変数を渡す' 'env 0 never' { $calls | Where-Object { $_ -clike 'env *' } | Sort-Object -Unique }
            Test-Case 'gh の資格情報: GitHub の remote の clone も進める' $d1 { Get-Rev $dot }
            Test-Case 'gh の資格情報: 終了コードは 0' '0' { Get-ChildValue $out 'code' }
        } finally {
            Remove-Fixture $fx
        }
    } else {
        Write-Host 'skip gh の資格情報: GitHub の remote の fetch に渡す引数と環境変数 (git を包む偽物の sh を使うので Linux の pwsh だけで流す)'
    }

    Remove-Item -LiteralPath $gitHome -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:Failures -gt 0) {
    Write-Host "$($script:Failures) 件失敗"
    exit 1
}
Write-Host 'すべて通った'
