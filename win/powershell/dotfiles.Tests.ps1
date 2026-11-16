# win/powershell/dotfiles.ps1 の runner の関数 (dotfiles・ConvertTo-DotfilesRunnerArgs) のテスト。Pester は使わない。
# dotfiles 関数は cargo を打つので、HOME を一時ディレクトリにした子の pwsh で、cargo を関数の偽物に替えて流す (本物の cargo も
# ホームの clone も触らない)。
#
# WSL から流す (Linux の pwsh で動かすので、Windows 側には触らない):
#   nix shell nixpkgs#powershell -c pwsh -NoProfile -File win/powershell/dotfiles.Tests.ps1
#
# ## 確かめること
#
#   - PowerShell が配列にした `--steps files,ntn` (`--steps=files,ntn` も) を、runner には , でつないだ 1 つの引数で渡す
#   - dotfiles は win/runner に入って cargo run --quiet --release --locked -- <引数> を打ち、終わったら元の場所に戻る
#   - clone に runner が無ければ、知らせて $LASTEXITCODE を 2 にする (cargo は打たない)
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

if ($script:Failures -gt 0) {
    Write-Host "$($script:Failures) 件失敗"
    exit 1
}
Write-Host 'すべて通った'
