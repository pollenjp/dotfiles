# dotfiles --self-update の中身 (win/README.md の「clone を進める (dotfiles --self-update)」。dotfiles-private の ADR 104)。
# PowerShell の dotfiles 関数 (win/powershell/dotfiles.ps1) が、配った写しでなく clone の中のこの script を呼ぶ。この script を直した pull は、
# $PROFILE で読んだ関数が古いままでも、次の dotfiles --self-update から効く (今回の分は、pull する前に読み込んだこの script のまま流れる)。
#
#   dotfiles --self-update [--dry-run] [<runner の引数>…]
#
# 1. dotfiles・dotfiles-private・claude-skills の clone (%USERPROFILE%\ghq\github.com\pollenjp\<名前>。bootstrap が clone する所) を、upstream から
#    fetch して fast-forward する。remote が GitHub なら gh の資格情報 (HTTPS) で通す (bootstrap の clone と同じ組。nix/pkgs/git-gh)。git にも
#    Git Credential Manager にも対話のプロンプトを出させない (資格情報が無ければ、待たずに落ちて ⚠ になる)
# 2. clone が無い・git の repo でない・未 commit の変更がある・detached HEAD・upstream が無い・fetch が落ちた・fast-forward できないものは、⚠ を
#    出して飛ばし、ほかの clone と runner は続ける (Linux の nix/scripts/setup.sh の --self-update と同じ扱い。未追跡のファイルは数えない)。
#    ただし private な repo (dotfiles-private・claude-skills) の clone が無いのは「このホストでは使わない」の · にし、終了コードを変えない (gh に
#    ログインできない PC は -Private でない bootstrap で dotfiles だけを clone する。dotfiles-private の docs/adr/111_win_runner_without_gh_*)。
#    gh が無ければ GitHub の remote を資格情報なしの HTTPS で取る (public な dotfiles は取れる。gh があってログインしていなくても、public な repo は
#    資格情報を求められないので gh の helper は呼ばれない)
# 3. 後ろに runner の引数があれば、進めた後に runner に渡す (dotfiles 関数と同じく win\runner で cargo run。runner は clone から作り直すので、
#    進めた後のコードで動く)
# 4. 締めに、進めなかった clone と、dotfiles.ps1 が変わったら新しい PowerShell を開くことを出す (今の PowerShell の関数は古いまま)
#
# --self-update の直後の --dry-run は、fetch して進める commit を出すだけ (fast-forward も runner もしない。fetch は remote-tracking の ref だけを
# 進める)。runner の引数の中の --dry-run (apply --dry-run) は runner のもの (clone は進める)。
#
# 終了コード: runner の終了コード (流さなければ 0)。進めなかった clone があれば、0 と 3 を 1 にする。引数の誤り・runner が無いときは 2。
#
# BOM 付きの UTF-8 で保存すること。Windows PowerShell 5.1 でも動かす (7 にしか無い書き方を使わない。Invoke-DotfilesSelfUpdate.Tests.ps1 が見る)。
# dot-source したとき (テスト) は関数だけを読み、本体は走らせない (末尾)。

# 進める clone (bootstrap の Get-RepoTargets -Private と同じ 3 つ。runner と pjp が読む)。進める順に並べる
function Get-DotfilesCloneNames {
    @('dotfiles', 'dotfiles-private', 'claude-skills')
}

# private な repo の clone (無ければ「このホストでは使わない」。gh にログインできない PC には無い)
function Get-DotfilesPrivateCloneNames {
    @('dotfiles-private', 'claude-skills')
}

# 使い方 (--help と、引数の誤りで出す)
function Get-DotfilesSelfUpdateUsage {
    @(
        '使い方: dotfiles --self-update [--dry-run] [<runner の引数>…]'
        '  dotfiles・dotfiles-private・claude-skills の clone を fetch して fast-forward し、runner の引数があれば、その後に runner に渡す'
        '  (dotfiles --self-update apply・dotfiles --self-update check --steps files,ntn など)'
        '  --dry-run   fetch して、進める commit を出すだけ (fast-forward も runner もしない。--self-update の直後に書く)'
        '  -h, --help  この使い方を出す'
        '  win/README.md の「clone を進める (dotfiles --self-update)」'
    ) -join "`n"
}

# dotfiles --self-update の後ろの引数を読む。頭に並んだ --self-update の option (--dry-run・-h・--help。--self-update の重ねは読み捨てる) を読み、
# - で始まらない最初の引数から後ろを runner の引数にする (runner の引数の中の --dry-run は runner のもの)。知らない option は Error に入れる
# (runner の option も、--self-update の直後には書けない。runner のコマンドの後ろに書く)。配列の引数 (この script を直に呼んで
# --steps files,ntn と打つと、PowerShell が files,ntn を配列にする) は、dotfiles 関数の ConvertTo-DotfilesRunnerArgs と同じく , でつなぐ
function ConvertFrom-DotfilesSelfUpdateArgs {
    param([object[]]$Arguments)
    $dryRun = $false
    $help = $false
    $errorText = ''
    $runnerArgs = @()
    $all = @(foreach ($x in @($Arguments)) {
            if ($null -eq $x) { continue }
            if ($x -is [array]) { (@($x) | ForEach-Object { "$_" }) -join ',' } else { "$x" }
        })
    for ($i = 0; $i -lt $all.Count; $i++) {
        $a = $all[$i]
        if (-not $a.StartsWith('-', [System.StringComparison]::Ordinal)) {
            $runnerArgs = @($all[$i..($all.Count - 1)])
            break
        }
        switch -CaseSensitive ($a) {
            '--dry-run' { $dryRun = $true }
            '--self-update' { }
            '-h' { $help = $true }
            '--help' { $help = $true }
            default { if (-not $errorText) { $errorText = "知らない option です: $a" } }
        }
    }
    [pscustomobject]@{ DryRun = $dryRun; Help = $help; RunnerArgs = $runnerArgs; Error = $errorText }
}

# remote の URL (設定ファイルの値。insteadOf を当てる前) が GitHub か (ssh・ssh://・https。大文字小文字は問わない)。GitHub なら gh の資格情報で通す
function Test-DotfilesGitHubUrl {
    param([string]$Url)
    $u = "$Url".Trim()
    foreach ($prefix in @('git@github.com:', 'ssh://git@github.com/', 'https://github.com/')) {
        if ($u.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    $false
}

# GitHub の remote を fetch するときの git の -c の組 (bootstrap の Get-GitCloneArguments・nix/pkgs/git-gh と同じ組)。github.com の credential helper を
# 空にしてから gh を足し (Git for Windows の system の設定の Git Credential Manager を呼ばない)、GitHub の ssh の URL を https に読み替える (origin の
# URL も git の設定ファイルも書き換えない)。gh のパスは、git が helper を流す sh が読めるよう / にして一重引用符で囲む。gh が無ければ helper は
# 足さない (公開の repo は資格情報なしで取れる。private な repo は落ちて ⚠ になる)
function Get-DotfilesGitHubConfigArguments {
    param([string]$GhPath)
    $result = @('-c', 'credential.https://github.com.helper=')
    if ($GhPath) {
        $gh = $GhPath -replace '\\', '/'
        $result += @('-c', "credential.https://github.com.helper=!'$gh' auth git-credential")
    }
    $result + @('-c', 'url.https://github.com/.insteadOf=git@github.com:', '-c', 'url.https://github.com/.insteadOf=ssh://git@github.com/')
}

# PATH にある実行ファイルのパス (無ければ空)
function Find-DotfilesApplication {
    param([string]$Name)
    $found = @(Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue)
    if ($found.Count -eq 0) { return '' }
    "$($found[0].Path)"
}

# git を打ち、出力の行 (stdout と stderr) と終了コードを返す。git にも Git Credential Manager にも対話のプロンプトを出させない
# (GIT_TERMINAL_PROMPT=0・GCM_INTERACTIVE=never。bootstrap の clone と同じ)。git は UTF-8 で書く (commit の題の日本語) ので、読むあいだだけコンソールの
# 文字コードを UTF-8 にする (日本語の Windows の既定は CP932)。どれも今の PowerShell (dotfiles 関数を打った PowerShell) の値なので、終わったら戻す
# (Ctrl+C で止めたときも)
function Invoke-DotfilesGit {
    param([string]$Git, [string]$Directory, [string[]]$Arguments, [string[]]$ConfigArguments)
    # 5.1 では Stop のままだと、git の stderr の 1 行目で止まる
    $ErrorActionPreference = 'Continue'
    $savedPrompt = $env:GIT_TERMINAL_PROMPT
    $savedGcm = $env:GCM_INTERACTIVE
    $savedEncoding = $null
    $lines = @()
    $code = -1
    try {
        $env:GIT_TERMINAL_PROMPT = '0'
        $env:GCM_INTERACTIVE = 'never'
        try {
            $savedEncoding = [Console]::OutputEncoding
            [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
        } catch {
            $savedEncoding = $null
        }
        $all = @()
        if ($ConfigArguments) { $all += $ConfigArguments }
        $all += @('-C', $Directory)
        $all += $Arguments
        try {
            $lines = @(& $Git @all 2>&1 | ForEach-Object { "$_" })
            $code = $LASTEXITCODE
        } catch {
            $lines = @("$($_.Exception.Message)")
            $code = -1
        }
    } finally {
        $env:GIT_TERMINAL_PROMPT = $savedPrompt
        $env:GCM_INTERACTIVE = $savedGcm
        if ($null -ne $savedEncoding) {
            try { [Console]::OutputEncoding = $savedEncoding } catch { }
        }
    }
    [pscustomobject]@{ ExitCode = $code; Lines = $lines }
}

# 行の並びの 1 行目 (前後の空白を除く。無ければ空)
function Get-DotfilesFirstLine {
    param([string[]]$Lines)
    $all = @($Lines)
    if ($all.Count -eq 0) { return '' }
    "$($all[0])".Trim()
}

# git の出力の終わりの何行か (⚠ の行の下に出す)
function Select-DotfilesTail {
    param([string[]]$Lines, [int]$Count = 3)
    @(@($Lines) | Where-Object { "$_".Trim() } | Select-Object -Last $Count)
}

# git の設定の値 (無ければ空)
function Get-DotfilesGitConfigValue {
    param([string]$Git, [string]$Directory, [string]$Key)
    $c = Invoke-DotfilesGit -Git $Git -Directory $Directory -Arguments @('config', '--get', $Key)
    if ($c.ExitCode -ne 0) { return '' }
    Get-DotfilesFirstLine -Lines $c.Lines
}

# commit の SHA (引けなければ空)
function Get-DotfilesRevision {
    param([string]$Git, [string]$Directory, [string]$Rev)
    $c = Invoke-DotfilesGit -Git $Git -Directory $Directory -Arguments @('rev-parse', '--verify', '--quiet', $Rev)
    if ($c.ExitCode -ne 0) { return '' }
    Get-DotfilesFirstLine -Lines $c.Lines
}

# 範囲の commit の数 (数えられなければ -1)
function Get-DotfilesCommitCount {
    param([string]$Git, [string]$Directory, [string]$Range)
    $c = Invoke-DotfilesGit -Git $Git -Directory $Directory -Arguments @('rev-list', '--count', $Range)
    $n = 0
    if (($c.ExitCode -ne 0) -or -not [int]::TryParse((Get-DotfilesFirstLine -Lines $c.Lines), [ref]$n)) { return -1 }
    $n
}

# git が思わぬ形で落ちたときの結果 (⚠ の行に、打った git のコマンドと終了コード。下に git の出力の終わり)
function Set-DotfilesCloneFailure {
    param($Result, [string]$What, $Run)
    $Result.State = 'skipped'
    $Result.Message = "git $What が落ちた (終了コード $($Run.ExitCode))"
    $Result.Detail = @(Select-DotfilesTail -Lines $Run.Lines)
    $Result
}

# clone を 1 つ進める (-DryRun なら fetch して、進める commit を数えるだけ)。結果の State は updated (進めた)・current (最新)・would-update
# (--dry-run で、進められる)・unused (private な repo の clone が無い。このホストでは使わない · で、終了コードに数えない)・skipped (⚠。Message に、
# わけと直し方)。-WatchPath のファイルが進める commit で変わるなら WatchChanged
# (dotfiles の clone の win/powershell/dotfiles.ps1)。順と飛ばす条件は Linux の setup.sh の pull_repo と同じ
function Update-DotfilesClone {
    param([string]$Name, [string]$Directory, [string]$Git, [string]$GhPath, [switch]$DryRun, [string]$WatchPath = '')
    $r = [pscustomobject]@{
        Name = $Name; Directory = $Directory; State = 'skipped'; Branch = ''; Before = ''; After = ''; Count = 0; Ahead = 0
        Log = @(); Message = ''; Detail = @(); WatchChanged = $false
    }
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        if (@(Get-DotfilesPrivateCloneNames) -ccontains $Name) {
            $r.State = 'unused'
            $r.Message = 'clone が無い (このホストでは使わない。使うホストは win\bootstrap\Install-Bootstrap.ps1 -Private で clone する)'
            return $r
        }
        $r.Message = "clone が無い ($Directory) → win\bootstrap\Install-Bootstrap.ps1 で clone する"
        return $r
    }
    if (-not (Test-Path -LiteralPath (Join-Path $Directory '.git'))) {
        $r.Message = "git の repo でない ($Directory) → 退けてから win\bootstrap\Install-Bootstrap.ps1 で clone し直す"
        return $r
    }
    if (-not $Git) {
        $r.Message = 'git が見つからない → win\bootstrap\Install-Bootstrap.ps1 で Git for Windows を入れる'
        return $r
    }
    # 直し方の行に出す git -C '<clone>' (PowerShell にそのまま打てる形)
    $at = "git -C '$($Directory -replace "'", "''")'"

    # 今の branch (行の頭に出す。detached HEAD なら空。detached の ⚠ は、未 commit の変更を見た後に出す: setup.sh と同じ順)
    $b = Invoke-DotfilesGit -Git $Git -Directory $Directory -Arguments @('symbolic-ref', '--short', '-q', 'HEAD')
    if (($b.ExitCode -ne 0) -and ($b.ExitCode -ne 1)) { return (Set-DotfilesCloneFailure -Result $r -What 'symbolic-ref' -Run $b) }
    $branch = ''
    if ($b.ExitCode -eq 0) { $branch = Get-DotfilesFirstLine -Lines $b.Lines }
    $r.Branch = $branch

    # 未 commit の変更 (作業ツリーと index。未追跡のファイルは数えない: 進めると上書きされるなら merge が断り、下の ⚠ になる)
    foreach ($cached in @($false, $true)) {
        $diffArgs = @('diff', '--quiet')
        if ($cached) { $diffArgs = @('diff', '--cached', '--quiet') }
        $d = Invoke-DotfilesGit -Git $Git -Directory $Directory -Arguments $diffArgs
        if ($d.ExitCode -eq 1) {
            $r.Message = "未 commit の変更があるので進めない → $at status で見て、commit するか退けてから打ち直す"
            return $r
        }
        if ($d.ExitCode -ne 0) { return (Set-DotfilesCloneFailure -Result $r -What ($diffArgs -join ' ') -Run $d) }
    }

    # branch と upstream
    if (-not $branch) {
        $r.Message = "detached HEAD なので進めない → branch に switch してから打ち直す ($at switch main など)"
        return $r
    }
    $remote = Get-DotfilesGitConfigValue -Git $Git -Directory $Directory -Key "branch.$branch.remote"
    $merge = Get-DotfilesGitConfigValue -Git $Git -Directory $Directory -Key "branch.$branch.merge"
    if ((-not $remote) -or (-not $merge)) {
        $r.Message = "upstream が無いので進めない → $at branch --set-upstream-to=origin/$branch で付けるか、upstream のある branch に switch する"
        return $r
    }

    # fetch (upstream の branch だけ。remote-tracking の ref が進む)。GitHub なら gh の資格情報で通す
    $url = Get-DotfilesGitConfigValue -Git $Git -Directory $Directory -Key "remote.$remote.url"
    $config = @()
    if (Test-DotfilesGitHubUrl -Url $url) { $config = @(Get-DotfilesGitHubConfigArguments -GhPath $GhPath) }
    $f = Invoke-DotfilesGit -Git $Git -Directory $Directory -ConfigArguments $config -Arguments @('fetch', '--quiet', $remote, $merge)
    if ($f.ExitCode -ne 0) {
        $hint = 'オフラインなら、つながってから打ち直す'
        if ($config.Count -gt 0) {
            if ($GhPath) {
                $hint = 'gh の資格情報 (HTTPS) で通している。gh auth status で、この repo を読めるアカウントでログインしているかを確かめる'
            } else {
                $hint = 'gh が見つからない (GitHub の private な repo は gh の資格情報で通す) → win\bootstrap\Install-Bootstrap.ps1 で gh を入れてログインする'
            }
        }
        $r.Message = "fetch に失敗した → $hint"
        $r.Detail = @(Select-DotfilesTail -Lines $f.Lines)
        return $r
    }
    $u = Invoke-DotfilesGit -Git $Git -Directory $Directory -Arguments @('rev-parse', '--symbolic-full-name', '@{upstream}')
    $upstreamRef = ''
    if ($u.ExitCode -eq 0) { $upstreamRef = Get-DotfilesFirstLine -Lines $u.Lines }
    if (-not $upstreamRef) {
        $r.Message = "upstream ($remote の $merge) を引けない → $at branch -vv で見る"
        $r.Detail = @(Select-DotfilesTail -Lines $u.Lines)
        return $r
    }
    $head = Get-DotfilesRevision -Git $Git -Directory $Directory -Rev 'HEAD'
    $target = Get-DotfilesRevision -Git $Git -Directory $Directory -Rev $upstreamRef
    $behind = -1
    $ahead = -1
    if ($head -and $target) {
        $behind = Get-DotfilesCommitCount -Git $Git -Directory $Directory -Range "$head..$target"
        $ahead = Get-DotfilesCommitCount -Git $Git -Directory $Directory -Range "$target..$head"
    }
    if (($behind -lt 0) -or ($ahead -lt 0)) {
        $r.Message = "HEAD と upstream ($upstreamRef) の差を数えられない → $at status で見る"
        return $r
    }
    $r.Before = $head
    $r.Ahead = $ahead
    if ($behind -eq 0) {
        $r.State = 'current'
        $r.After = $head
        return $r
    }
    if ($ahead -gt 0) {
        $r.Message = "fast-forward できない (ローカルにだけ $ahead commit・upstream にだけ $behind commit) → merge か rebase を自分で"
        return $r
    }

    # 進める commit (新しい順に 15 まで) と、見張るファイルが変わるか
    $r.Count = $behind
    $log = Invoke-DotfilesGit -Git $Git -Directory $Directory -Arguments @('log', '--format=%h %s', '-n', '15', "$head..$target")
    if ($log.ExitCode -eq 0) { $r.Log = @($log.Lines) }
    if ($WatchPath) {
        $w = Invoke-DotfilesGit -Git $Git -Directory $Directory -Arguments @('diff', '--quiet', $head, $target, '--', $WatchPath)
        $r.WatchChanged = ($w.ExitCode -eq 1)
    }
    if ($DryRun) {
        $r.State = 'would-update'
        $r.After = $target
        return $r
    }
    # 数えた commit まで進める (fetch し直さない)
    $m = Invoke-DotfilesGit -Git $Git -Directory $Directory -Arguments @('merge', '--ff-only', '--quiet', $target)
    if ($m.ExitCode -ne 0) {
        $short = $upstreamRef -replace '^refs/remotes/', ''
        $r.Message = "fast-forward できなかった (進めると上書きされる未追跡のファイルがあるなど) → $at merge --ff-only $short を打って見る"
        $r.Detail = @(Select-DotfilesTail -Lines $m.Lines -Count 5)
        $r.WatchChanged = $false
        return $r
    }
    $r.State = 'updated'
    $r.After = $target
    $r
}

# SHA の頭 7 字
function Get-DotfilesShortSha {
    param([string]$Sha)
    if ($Sha.Length -gt 7) { return $Sha.Substring(0, 7) }
    $Sha
}

# 出す行 1 つ (Color は Write-Host の色。空なら付けない)
function New-DotfilesLine {
    param([string]$Text, [string]$Color = '')
    [pscustomobject]@{ Text = $Text; Color = $Color }
}

# clone 1 つの結果の行。頭の印は runner の締めの表と同じ (✔ 揃っている・· 知らせるだけ (使わない clone も)・⚠ 直すことがある)。進める commit は下に 1 行ずつ
function Format-DotfilesCloneResult {
    param($Result)
    $label = $Result.Name
    if ($Result.Branch) { $label = "$($Result.Name) ($($Result.Branch))" }
    $range = "$(Get-DotfilesShortSha $Result.Before) → $(Get-DotfilesShortSha $Result.After)"
    $lines = @()
    switch ($Result.State) {
        'updated' { $lines += New-DotfilesLine "✔ $($label): $($Result.Count) commit 進めた ($range)" 'Green' }
        'would-update' { $lines += New-DotfilesLine "· $($label): $($Result.Count) commit 進められる ($range。--dry-run なので進めない)" }
        'current' {
            $text = "✔ $($label): 最新"
            if ($Result.Ahead -gt 0) { $text = "$text (push していない commit が $($Result.Ahead))" }
            $lines += New-DotfilesLine $text 'Green'
        }
        'unused' { $lines += New-DotfilesLine "· $($label): $($Result.Message)" }
        default { $lines += New-DotfilesLine "⚠ $($label): $($Result.Message)" 'Yellow' }
    }
    if (($Result.State -eq 'updated') -or ($Result.State -eq 'would-update')) {
        foreach ($l in @($Result.Log)) { $lines += New-DotfilesLine "    $l" }
        $rest = $Result.Count - @($Result.Log).Count
        if ($rest -gt 0) { $lines += New-DotfilesLine "    … ほか $rest commit" }
    }
    foreach ($l in @($Result.Detail)) { $lines += New-DotfilesLine "    git: $l" }
    $lines
}

# 1 行を出す。色は、環境変数 NO_COLOR が空のときだけ付ける (runner と同じ)
function Write-DotfilesLine {
    param([string]$Text, [string]$Color = '')
    if ($Color -and -not $env:NO_COLOR) {
        Write-Host $Text -ForegroundColor $Color
    } else {
        Write-Host $Text
    }
}

# 2 つのファイルが同じ中身か (どちらかが無ければ違う)
function Test-DotfilesSameFile {
    param([string]$Path, [string]$Other)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    if (-not (Test-Path -LiteralPath $Other -PathType Leaf)) { return $false }
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $Other -Algorithm SHA256).Hash
}

# dotfiles.ps1 が変わったときの締めの行。今の PowerShell の関数 (dotfiles・略語・Vi モードの割り当てなど) は、開いたときに配った写し
# (%USERPROFILE%\.config\powershell\dotfiles.ps1) から読んだものなので、写しを新しくしてから新しい PowerShell を開く。写しを配るのは、受け持ちが
# runner のホストは dotfiles apply (files)、WSL のホストは WSL の setup (WSL の clone から配るので、WSL の本体も進める)
function Get-DotfilesProfileNotice {
    param([bool]$DryRun, [string]$CloneFile, [string]$DeployedFile)
    $deploy = 'dotfiles apply で配ってから (受け持ちが WSL のホストは WSL の ~/dotfiles/setup --self-update --update)'
    if ($DryRun) {
        return "※ 進めると dotfiles.ps1 も変わる。進めた後は、配った写し ($DeployedFile) を $deploy、新しい PowerShell を開く (今の PowerShell の dotfiles 関数などは古いまま)"
    }
    if (Test-DotfilesSameFile -Path $CloneFile -Other $DeployedFile) {
        return '※ dotfiles.ps1 が変わった (配った写しも新しい)。新しい PowerShell を開く (今の PowerShell の dotfiles 関数などは古いまま)'
    }
    "※ dotfiles.ps1 が変わった。配った写し ($DeployedFile) はまだ古いので、$deploy、新しい PowerShell を開く (今の PowerShell の dotfiles 関数などは古いまま)"
}

# 進めるときの見出し。gh が無ければ、GitHub の remote は資格情報なしの HTTPS で取る (public な repo だけ取れる)
function Get-DotfilesSelfUpdateHeading {
    param([bool]$HaveGh)
    if ($HaveGh) {
        return '==> dotfiles --self-update: 3 つの clone を進める (fetch して fast-forward。GitHub の remote は gh の資格情報で HTTPS を通す)'
    }
    '==> dotfiles --self-update: 3 つの clone を進める (fetch して fast-forward。gh が無いので、GitHub の remote は資格情報なしの HTTPS で取る。public な repo だけ取れる)'
}

# 引数を読み、3 つの clone を進めて、行を出す。runner を流すかと、締めに使うものを返す (ExitCode が $null でなければ、引数の誤りか --help で、
# そこで終わる)。runner は呼び出し元 (末尾) が流す: ここで流すと、この関数の戻り値を受けるために PowerShell が cargo の出力をパイプで受け、
# runner が端末を見られない (色が付かない・出力が戻り値に混ざる)
function Invoke-DotfilesSelfUpdate {
    param([object[]]$Arguments)
    $state = [pscustomobject]@{
        ExitCode = $null; DryRun = $false; Results = @(); Runner = ''; RunnerArgs = @(); RunnerMissing = $false
        DotfilesDir = ''; DeployedProfile = ''
    }
    $parsed = ConvertFrom-DotfilesSelfUpdateArgs -Arguments $Arguments
    if ($parsed.Error) {
        Write-DotfilesLine "dotfiles --self-update: $($parsed.Error)" 'Red'
        Write-Host (Get-DotfilesSelfUpdateUsage)
        $state.ExitCode = 2
        return $state
    }
    if ($parsed.Help) {
        Write-Host (Get-DotfilesSelfUpdateUsage)
        $state.ExitCode = 0
        return $state
    }
    $state.DryRun = $parsed.DryRun
    $state.RunnerArgs = @($parsed.RunnerArgs)
    $root = [IO.Path]::Combine($HOME, 'ghq', 'github.com', 'pollenjp')
    $state.DotfilesDir = [IO.Path]::Combine($root, 'dotfiles')
    $state.DeployedProfile = [IO.Path]::Combine($HOME, '.config', 'powershell', 'dotfiles.ps1')
    $git = Find-DotfilesApplication -Name 'git'
    $gh = Find-DotfilesApplication -Name 'gh'
    if ($state.DryRun) {
        Write-DotfilesLine '==> dotfiles --self-update --dry-run: 3 つの clone の進める commit を出す (fetch だけ。fast-forward も runner もしない)'
    } else {
        Write-DotfilesLine (Get-DotfilesSelfUpdateHeading -HaveGh ([bool]$gh))
    }
    $results = @()
    foreach ($name in @(Get-DotfilesCloneNames)) {
        $watch = ''
        if ($name -ceq 'dotfiles') { $watch = 'win/powershell/dotfiles.ps1' }
        $r = Update-DotfilesClone -Name $name -Directory ([IO.Path]::Combine($root, $name)) -Git $git -GhPath $gh -DryRun:$state.DryRun -WatchPath $watch
        foreach ($line in @(Format-DotfilesCloneResult -Result $r)) { Write-DotfilesLine $line.Text $line.Color }
        $results += $r
    }
    $state.Results = $results
    if ($state.RunnerArgs.Count -gt 0) {
        if ($state.DryRun) {
            Write-DotfilesLine "· --dry-run なので runner は流さない (進めてから流すなら、--dry-run を外す: dotfiles --self-update $($state.RunnerArgs -join ' '))"
        } else {
            $runner = [IO.Path]::Combine($state.DotfilesDir, 'win', 'runner')
            if (Test-Path -LiteralPath ([IO.Path]::Combine($runner, 'Cargo.toml')) -PathType Leaf) {
                $state.Runner = $runner
            } else {
                Write-DotfilesLine "dotfiles の runner がありません: $runner (先に win\bootstrap\Install-Bootstrap.ps1 で clone する)" 'Yellow'
                $state.RunnerMissing = $true
            }
        }
    }
    $state
}

# 締め: 進めなかった clone (runner を流したら、その出力の後にもう一度) と、dotfiles.ps1 が変わったことを出し、終了コードを返す
function Complete-DotfilesSelfUpdate {
    param($State, $RunnerCode)
    $code = 0
    if ($State.RunnerMissing) {
        $code = 2
    } elseif ($null -ne $RunnerCode) {
        $code = [int]$RunnerCode
    }
    $skipped = @($State.Results | Where-Object { $_.State -eq 'skipped' })
    if ($skipped.Count -gt 0) {
        if ($State.Runner) {
            Write-Host ''
            Write-DotfilesLine '==> 進めなかった clone (上の ⚠ と同じ)'
            foreach ($r in $skipped) {
                $first = @(Format-DotfilesCloneResult -Result $r)[0]
                Write-DotfilesLine $first.Text $first.Color
            }
        }
        $names = @($skipped | ForEach-Object { $_.Name }) -join '・'
        Write-DotfilesLine "⚠️ 進めなかった clone がある ($names) → ⚠ の行のとおりに直して、dotfiles --self-update を打ち直す ⚠️" 'Yellow'
        if (($code -eq 0) -or ($code -eq 3)) { $code = 1 }
    }
    $dotfiles = @($State.Results | Where-Object { $_.Name -ceq 'dotfiles' })
    if (($dotfiles.Count -gt 0) -and $dotfiles[0].WatchChanged) {
        $clonePs1 = [IO.Path]::Combine($State.DotfilesDir, 'win', 'powershell', 'dotfiles.ps1')
        Write-DotfilesLine (Get-DotfilesProfileNotice -DryRun $State.DryRun -CloneFile $clonePs1 -DeployedFile $State.DeployedProfile) 'Yellow'
    }
    $code
}

# dot-source されたとき (テスト) は関数だけを読み、本体は走らせない。
# runner はここ (script の上の段) で流す。関数の中で流して戻り値を受けると、PowerShell が cargo の出力をパイプで受けてしまう (Invoke-DotfilesSelfUpdate)。
# 思わぬ例外は受け止めて終了コード 2 で終える。Ctrl+C で止めると catch を通らずに finally だけが流れるので、止めたことを出して終了コード 1 で終える
# (bootstrap と同じ。git に渡した環境変数とコンソールの文字コードは Invoke-DotfilesGit の finally が戻し、今いる場所は下の finally が戻す)
if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    # 外のコマンド (git・cargo) の終了コードは自分で読む。pwsh 7.4 からの $PSNativeCommandUseErrorActionPreference を profile で $true にしていると、
    # 0 でない終了コードが誤りの行になって git の出力に混ざり、Stop と組んだ cargo では例外になって締めが飛ぶ。この script の段で $false にする
    # (この script の関数にも効く。5.1 には無い変数で、置いても何も起きない)
    $PSNativeCommandUseErrorActionPreference = $false
    Set-StrictMode -Version Latest
    $exitCode = $null
    try {
        $state = Invoke-DotfilesSelfUpdate -Arguments @($args)
        if ($null -ne $state.ExitCode) {
            $exitCode = $state.ExitCode
        } else {
            $runnerCode = $null
            if ($state.Runner) {
                Write-Host ''
                # dotfiles 関数 (dotfiles.ps1) と同じ打ち方: win\runner に入ってから打ち、'--' は引用符で囲む (理由は dotfiles 関数の注意)。
                # Invoke-DotfilesSelfUpdate.Tests.ps1 が、dotfiles 関数と同じ場所で同じ引数を渡すかを突き合わせる
                $runnerArgs = @($state.RunnerArgs)
                Push-Location -LiteralPath $state.Runner
                try {
                    cargo run --quiet --release --locked '--' @runnerArgs
                    $runnerCode = $LASTEXITCODE
                } finally {
                    Pop-Location
                }
            }
            $exitCode = Complete-DotfilesSelfUpdate -State $state -RunnerCode $runnerCode
        }
    } catch {
        Write-Host "エラーで止まった: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace
        $exitCode = 2
    } finally {
        if ($null -eq $exitCode) {
            Write-Host ''
            Write-Host '⚠️ 途中で止めた (Ctrl+C)。clone を進めきれていないことがあるので、dotfiles --self-update を打ち直す ⚠️' -ForegroundColor Yellow
            exit 1
        }
    }
    exit $exitCode
}
