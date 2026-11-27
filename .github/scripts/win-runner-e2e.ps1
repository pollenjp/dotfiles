# Windows の runner の launcher (win/powershell/Invoke-DotfilesRunner.ps1) を、CI が作った本物の exe で通して流す試験 (.github/workflows/
# win-runner-release.yml の build の job が windows-latest で流す。dotfiles-private の docs/adr/117_win_runner_exe_release_*)。
#
#   win-runner-e2e.ps1 -Dist <exe と .sha256 の dir> -Clone <dotfiles の checkout>
#
# dist を手元の HTTP server (Python の http.server。127.0.0.1) で Release と同じ形 (<根>/win-runner-<key の頭 12 字>/<asset>) に配り、置き場
# (LOCALAPPDATA) を一時ディレクトリにして launcher を流す。DOTFILES_RUNNER は exe (cargo に戻らない)。
#
# ## 確かめること
#
#   - 置き場が空なら Release から落とし、sha256 と key を確かめて置き (exe・.sha256・印 verified)、runner を流す (list が 0)
#   - 2 回目は落とさずに、置き場のものを使う
#   - .sha256 が合わない Release からは置かずに、終了コード 2 で止まる
#   - Release が無い (404) なら、直し方を出して終了コード 2 で止まる
param(
    [Parameter(Mandatory = $true)][string]$Dist,
    [Parameter(Mandatory = $true)][string]$Clone
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$launcher = Join-Path $Clone 'win\powershell\Invoke-DotfilesRunner.ps1'
$hostFile = Join-Path $Clone 'win\templates\host.minimum.toml'
$key = "$(@(& git -C $Clone rev-parse 'HEAD:win/runner')[0])".Trim()
$tag = "win-runner-$($key.Substring(0, 12))"
$root = Join-Path ([IO.Path]::GetTempPath()) ("win-runner-e2e-" + [Guid]::NewGuid())
$serve = Join-Path $root 'serve'
$port = 8765
$base = "http://127.0.0.1:$port"
$script:Failures = 0

function Assert-That {
    param([string]$Name, [bool]$Ok, [string[]]$Output)
    if ($Ok) {
        Write-Host "ok   $Name"
    } else {
        Write-Host "FAIL $Name"
        foreach ($l in @($Output)) { Write-Host "     | $l" }
        $script:Failures++
    }
}

# 子の pwsh で launcher を流し、出力の行と終了コードを返す (環境変数は流す間だけ替える)
function Invoke-Launcher {
    param([string]$LocalAppData, [string]$BaseUrl)
    $names = @('LOCALAPPDATA', 'DOTFILES_RUNNER', 'DOTFILES_RUNNER_BASE_URL', 'NO_COLOR')
    $saved = @{}
    foreach ($n in $names) { $saved[$n] = [Environment]::GetEnvironmentVariable($n) }
    $ErrorActionPreference = 'Continue'
    try {
        $env:LOCALAPPDATA = $LocalAppData
        $env:DOTFILES_RUNNER = 'exe'
        $env:DOTFILES_RUNNER_BASE_URL = $BaseUrl
        $env:NO_COLOR = '1'
        $lines = @(& pwsh -NoProfile -NonInteractive -File $launcher $Clone list --host-file $hostFile 2>&1 | ForEach-Object { "$_" })
        [pscustomobject]@{ Code = $LASTEXITCODE; Lines = $lines }
    } finally {
        foreach ($n in $names) { [Environment]::SetEnvironmentVariable($n, $saved[$n]) }
    }
}

# Release と同じ形に置く (good は dist のまま、bad は .sha256 だけを違う値に)
foreach ($kind in @('good', 'bad')) {
    $dir = [IO.Path]::Combine($serve, $kind, $tag)
    $null = New-Item -ItemType Directory -Force -Path $dir
    Copy-Item -LiteralPath (Join-Path $Dist 'dotfiles-win.exe') -Destination $dir
    if ($kind -eq 'good') {
        Copy-Item -LiteralPath (Join-Path $Dist 'dotfiles-win.exe.sha256') -Destination $dir
    } else {
        [IO.File]::WriteAllText((Join-Path $dir 'dotfiles-win.exe.sha256'), "$('0' * 64)  dotfiles-win.exe`n")
    }
}

$server = Start-Process -FilePath 'python' -ArgumentList @('-m', 'http.server', "$port", '--bind', '127.0.0.1', '--directory', $serve) -PassThru -WindowStyle Hidden
try {
    $ready = $false
    for ($i = 0; $i -lt 60; $i++) {
        try {
            $null = Invoke-WebRequest -Uri "$base/good/$tag/dotfiles-win.exe.sha256" -UseBasicParsing -TimeoutSec 2
            $ready = $true
            break
        } catch {
            Start-Sleep -Milliseconds 500
        }
    }
    if (-not $ready) { throw "HTTP server が $base で答えない" }

    $lad = Join-Path $root 'lad1'
    $cache = [IO.Path]::Combine($lad, 'dotfiles', 'runner', $key)
    $r = Invoke-Launcher -LocalAppData $lad -BaseUrl "$base/good"
    Assert-That '置き場が空なら落として流す (list が 0)' ($r.Code -eq 0) $r.Lines
    Assert-That '落とすことを出す' ([bool]($r.Lines | Where-Object { $_ -like "==> runner の exe を落とす: $tag*" })) $r.Lines
    $placed = @('dotfiles-win.exe', 'dotfiles-win.exe.sha256', 'verified' | Where-Object { Test-Path -LiteralPath (Join-Path $cache $_) -PathType Leaf })
    Assert-That '置き場に exe・.sha256・印 verified を置く' ($placed.Count -eq 3) @("placed: $($placed -join ', ')")

    $r = Invoke-Launcher -LocalAppData $lad -BaseUrl "$base/good"
    Assert-That '2 回目は落とさず、置き場のものを使う' (($r.Code -eq 0) -and -not ($r.Lines | Where-Object { $_ -like '==> runner の exe を落とす*' })) $r.Lines

    $lad = Join-Path $root 'lad2'
    $r = Invoke-Launcher -LocalAppData $lad -BaseUrl "$base/bad"
    $badExe = [IO.Path]::Combine($lad, 'dotfiles', 'runner', $key, 'dotfiles-win.exe')
    Assert-That '.sha256 が合わなければ 2 で止まり、置かない' (($r.Code -eq 2) -and -not (Test-Path -LiteralPath $badExe)) $r.Lines
    Assert-That '合わないことを出す' ([bool]($r.Lines | Where-Object { $_ -like '!! *合わない*' })) $r.Lines

    $r = Invoke-Launcher -LocalAppData (Join-Path $root 'lad3') -BaseUrl "$base/none"
    Assert-That 'Release が無ければ (404) 2 で止まり、直し方を出す' (($r.Code -eq 2) -and [bool]($r.Lines | Where-Object { $_ -like '*HTTP 404*' }) -and [bool]($r.Lines | Where-Object { $_ -like '  → merge の直後なら*' })) $r.Lines
} finally {
    if (-not $server.HasExited) { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:Failures -gt 0) {
    Write-Host "$($script:Failures) 件失敗"
    exit 1
}
Write-Host 'すべて通った'
