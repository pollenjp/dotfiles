# Google 日本語入力と PowerToys を setup の中で winget から入れる Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 新しいマシンで `~/dotfiles/setup --update` を流すだけで、Windows の Google 日本語入力 (固定した版) と PowerToys が winget で入り、この PC では Google 日本語入力の版のずれが ⚠ で見えるようにする。

**Architecture:** herdr (order 97) と同じ形にする。`win/` に PowerShell のスクリプト (`Install-GoogleJapaneseInput.ps1`・`Install-PowerToys.ps1`) を置き、`bootstrap-windows-files.sh` (order 90) が `%USERPROFILE%\.config\powershell\` へ配り、bootstrap が `pwsh.exe` で `-Check` / `-IfMissing` を呼ぶ。Google 日本語入力は新しい `bootstrap-windows-google-ime-install.sh` (order 95) が版を確かめて無ければ入れ (UAC)、PowerToys は `bootstrap-windows-powertoys.sh` (order 91) が読み直させる前に無ければ入れる。`bootstrap-windows-google-ime.sh` (order 98) は「入っているがまだ使っていない」を見分けて案内する。

**Tech Stack:** PowerShell 7 と Windows PowerShell 5.1 (スクリプト。テストは Linux の pwsh 7.6、Pester は使わない)、winget 1.29、bash (`set -eu -o pipefail`・shfmt・shellcheck)、Nix flake (`checks` の `scriptTest`)、jq。

**Spec:** `docs/adr/017_win_apps_winget_20261012T115007JST/README.md` (ユーザーの承認済み)。前提は ADR 015 (`docs/adr/015_win_google_ime_powertoys_20261011T234247JST/README.md`) と ADR 010。チケットは [TKT-143](https://app.notion.com/p/winget-Windows-Google-PowerToys-Google-dotfiles-3f779149a66f817a8944c9e4e460383f)。

## Global Constraints

- 作業ツリーは `/home/pollenjp/.herdr/worktrees/dotfiles/worktree-calm-stone-6931` (branch `feat/TKT-143-winget-ime-powertoys`。main の `be7b44b` に ADR の commit `19ae7da` を足したもの)。コマンドはこの作業ツリーの直下で打つ
- commit の題は repo の慣習どおり `type(scope): 日本語の一文 (TKT-143)`。本文の末尾に次の 2 行を必ず付ける
  - `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`
  - `Claude-Session: https://claude.ai/code/session_01YSF6gCGyvBHzRBtjbB61Fm`
- winget の ID: Google 日本語入力は `Google.JapaneseIME` (machine スコープの wix の MSI だけ。入れる・上げると UAC の確認が出る)、PowerToys は `Microsoft.PowerToys` (user スコープの `PowerToysUserSetup-…exe` で入れる。管理者は要らない)
- Google 日本語入力の固定する版は `3.34.6260.0`。書くのは `Install-GoogleJapaneseInput.ps1` の `-Version` の既定値の 1 か所だけ。PowerToys は版を固定せず、winget pin も足さない
- Google 日本語入力の版は `GoogleIMEJaConverter.exe` の `VersionInfo.ProductVersion` で読む (FileVersion の `2.29.5370.0  (build 63)` は使わない)。`C:\Program Files\Google\Google Japanese Input\` と `C:\Program Files (x86)\Google\Google Japanese Input\` の両方を見る (この PC は x86 の方に `2.29.5370.0`)
- PowerToys が入っているかは、`PowerToys.exe` が `%LOCALAPPDATA%\PowerToys\` (user スコープ。この PC は `0.100.2.0`) か `%ProgramFiles%\PowerToys\` (machine スコープ) にあるかで見る
- winget の引数は herdr と同じ: 共通 `--id <ID> --exact --source winget --silent --accept-source-agreements --disable-interactivity`、入れる・上げるときは `--accept-package-agreements` (Google 日本語入力は `--version <版>` も)。pin は `winget pin add|remove|list --id <ID> --exact --accept-source-agreements --disable-interactivity`、版の一覧は `winget show --id <ID> --exact --versions --source winget …` (新しい順)
- スクリプトの終了コード: `Install-GoogleJapaneseInput.ps1 -Check` は 0 揃っている / 1 差がある / 3 入っていない / 2 確かめられない (winget が無い・思わぬ例外)。`Install-PowerToys.ps1 -Check` は 0 入っている / 3 入っていない / 2 確かめられない
- bootstrap の終了コード: 95 (`bootstrap-windows-google-ime-install.sh`) と 91 (`bootstrap-windows-powertoys.sh`) は、知らない引数の 2 以外は 0 を返す (setup を止めない)。95 の `--apply` (手で流す) だけは、揃わなければ 1 (96・97 の `--apply` と同じ)。98 の終了コードは今のまま
- order: 91・95・98。95 は `bootstrap-windows-powershell-profile.sh` と同じ値で、同じ値は辞書順なので `bootstrap-windows-google-ime-install.sh` が先に走る (どちらも相手を使わない)。`# order:` の行は説明の 1 行目より後ろに書く (前に書くと setup のメニューの説明に拾われる)
- 待つ上限: 95 の `-Check` は `timeout 120`、`-IfMissing` は `timeout 600`。91 の `-Check` は `timeout 60`、`-IfMissing` は `timeout 600`
- `pwsh.exe` に渡すコマンドは herdr の 97 と同じ形: `[Console]::OutputEncoding = [Text.Encoding]::UTF8; $global:LASTEXITCODE = 2; & '<パス>' <引数>; exit $LASTEXITCODE` (`-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command`、`</dev/null`)
- 入れるのは `dotfiles.wsl.windowsFiles.enable` のマシンだけ (`~/.local/state/dotfiles/windows-files.json` の `enable` を 97 と同じく読む)。option は足さない
- setup.sh は実行ビットの無い bootstrap を「実行できません」で止める (`step_script` が `-x` を見る)。新しい bootstrap は `chmod +x` して mode `100755` で commit する。Write ツールで書き直したファイルは mode が変わっていないかを `git diff --summary` で見る
- `.ps1` は BOM 付きの UTF-8 (`.editorconfig` の `[*.ps1] charset = utf-8-bom`。Windows PowerShell 5.1 は BOM の無い UTF-8 を CP932 として読む)。Write ツールは BOM を付けないので、`.ps1` を Write で書いたら必ず Task 1 Step 2 の BOM のコマンドを流す。確かめは `head -c3 <file> | od -An -tx1` が ` ef bb bf`
- `.ps1` は Windows PowerShell 5.1 でも読める書き方にする (`? :`・`??`・`?.`・パイプラインの `&&` / `||` を使わない)
- PowerShell のテストは Pester を使わず、Linux の pwsh で手で流す: `nix shell nixpkgs#powershell -c pwsh -NoProfile -File win/<dir>/<名前>.Tests.ps1`。flake の checks には載せない。`.Tests.ps1` は manifest に載せない (配らない)
- Task 1〜7 では Windows に触らない: 本物の `pwsh.exe`・`winget.exe`・`powershell.exe`・`taskkill.exe` を打たない、`/mnt/c` に書かない、`bootstrap-windows-*.sh` を `--dry-run` / `--check` 無しで流さない。bash のテストは偽のコマンドだけを並べた PATH で流し、PowerShell のテストの入口のテストは子の PATH を空にして流す (この作りを崩さない)。Windows に触るのは、ユーザーと一緒に進める Task 8・9 だけ
- ユーザー辞書 (`~/ghq/github.com/pollenjp/dotfiles-private` と `/mnt/c/…/user_dictionary.db`) は読まない・出さない。Task 8 で 98 を流すときも、辞書の差は件数しか出さない (`--show-words` は付けない)
- 新しいファイルは、`nix build ./nix#checks…` の前に `git add` する (flake は git が追っていないファイルを見ない。追っているファイルの変更は commit しなくても見える)
- メッセージとコメントは日本語、識別子は英語 (今のコードと同じ)。`.sh` は shfmt (`.editorconfig` の設定) と shellcheck、`.nix` は nixfmt を通す
- Claude の Bash ツールは zsh で動く。この plan のコマンドは zsh でもそのまま動く形にしてある (bash の書き方が要るところは `bash -c` で包んだ)。`=` で始まる語 (`echo ====` など) は zsh が展開するので打たない

## Review Focus

- 版を上げる途中 (`Install-GoogleJapaneseInput.ps1` の `-Version` を変えて、commit する前) に 98 の `--import` を流す → 同じディレクトリのスクリプトの変更では止まらず、テキストだけを取り込む (Task 6 のテスト 33)
- 新しい bootstrap (95) や書き直した 91 に実行ビットが無い → setup が「実行できません」で止まる前に、テストで落ちる (Task 4 のテスト 20、Task 5 のテスト 18)
- setup の 95 で UAC の確認を押さないまま 600 秒たつ・「いいえ」を押す → ⚠ と手で打つコマンドを出して先へ進み (exit 0)、入っていないものに pin を足さない (Task 4 のテスト 11・12、Task 1 の「install が落ちたら (UAC で断った) pin を足さずに 1」)
- Google 日本語入力が自分で新しい版に上がった (`3.34.10000.0` のように文字列で比べると小さく見える版も) → 下げず、揃えるコマンドではなく repo の版の上げ方を出す (Task 1 の「文字列ではなく数で比べる (6260 < 10000)」と newer の各テスト、Task 4 のテスト 8)
- 3.34 の x64 の MSI で置き場所が `C:\Program Files\` に移る・上げた後も x86 の古い方が残る → 95 は新しい方の版で比べ、98 はどちらにあっても「入っている」と見る (Task 1 の「2 か所にあれば版の新しい方」、Task 6 のテスト 31・32)

---

## ADR の読み方 (plan で決めたこと)

ADR 017 を実装に落とすときに、ADR が書いていないことを次のように決めた。レビューで違うと判断したら、該当の Task の Step を直す。

| 点 | plan の決め方 | 根拠 |
| --- | --- | --- |
| 95 の `--apply` が失敗したとき | exit 1 | ADR の「どの場合も exit 0 (setup を止めない)」は setup から流す経路のことと読んだ。setup は `--apply` を付けない。96・97 の `--apply` も失敗で 1 |
| `Install-PowerToys` を引数なしで打つ | `-IfMissing` と同じ (入っていなければ入れる) | ADR B の表は `-Check` と `-IfMissing` だけ。版を固定しないので、揃えることが他に無い |
| 95 が入れ終えたとき | 「Google 日本語入力で一度何か打ってから、setup --update を流し直す」と出す | ADR の図 `02_ime_install` |
| 95 の差の枠で、入っている版の方が新しいとき (`(下げない)` の行があるとき) | 揃えるコマンドの代わりに、repo の版の上げ方を出す | ADR A「新しいときは下げずに、repo の版を上げるよう案内して 1」。揃えるコマンドを打っても下げないので |
| 98 の「入っているがまだ使っていない」 | `!!` で始めて stderr に出す (exit 0) | 98 の、ユーザーの手が要るときの書き方 (設定画面が開いている など) にそろえた |
| 98 が探す Program Files | `windowsHome` (`/mnt/c/Users/<名前>`) から `/Users/<名前>` を落としたドライブの直下 | windows-files.nix が `/mnt/c/Users/<名前>` で組む。テストも同じ形のホームにする |
| 95 の order | ADR どおり 95 | `bootstrap-windows-powershell-profile.sh` も 95 だが、同じ値は辞書順で、どちらも相手を使わない (nix/README.md の表に書く) |
| **ADR に無い変更**: 98 の `--import` が commit していない変更を確かめる対象 | 取り込みが書き換える `config.txtpb`・`keymap.tsv`・`romaji.tsv` だけにする (Task 6 の Step 8〜14) | ADR A がスクリプトを `win/google-japanese-input/` に置くので、今のままだと ADR §7「版を上げる」の 2 (`-Version` を変えて commit する前に `--import`) が「commit していない変更があります」で止まる (scratch で再現した)。要らなければ Task 6 の Step 8〜14 と、Task 7 の W5・A1・A2 を外す |
| ADR 015 の §7「新しいマシン」(「手で入れる」) | 今の形に書き換え、冒頭に後続 ADR の行を置く。ADR 017 §3 にも足す | `docs/adr/README.md` の方針 (手順書として読まれる部分は現行に追従させ、古い方の冒頭にポインタを置く) |

`docs/adr/README.md` の一覧に 017 を足すのは、ADR の commit (`19ae7da`) で済んでいる。

## ファイルの分担

| ファイル | 役目 | Task |
| --- | --- | --- |
| `win/google-japanese-input/Install-GoogleJapaneseInput.ps1` | 新規。Google 日本語入力の版を読み、winget で入れる・上げる・pin を足す。`-Check` / `-IfMissing` | 1 |
| `win/google-japanese-input/Install-GoogleJapaneseInput.Tests.ps1` | 新規。副作用の無い関数と流れのテスト (Linux の pwsh。配らない) | 1 |
| `win/powertoys/Install-PowerToys.ps1` | 新規。PowerToys が無ければ user スコープで入れる。`-Check` / `-IfMissing` | 2 |
| `win/powertoys/Install-PowerToys.Tests.ps1` | 新規。同じくテスト | 2 |
| `win/manifest.toml`・`win/powershell/dotfiles.ps1` | 2 つのスクリプトを `%USERPROFILE%/.config/powershell/` へ配り、PowerShell の関数から呼べるようにする | 3 |
| `nix/scripts/bootstrap-windows-google-ime-install.sh` | 新規 (order 95)。`-Check` の 0 / 1 / 3 で出し分け、3 なら `-IfMissing` | 4 |
| `nix/tests/bootstrap-windows-google-ime-install.test.sh`・`nix/flake.nix` | 新規のテスト (偽の `pwsh.exe` / `wslpath`) と、それを載せる checks | 4 |
| `nix/scripts/bootstrap-windows-powertoys.sh`・`nix/tests/bootstrap-windows-powertoys.test.sh` | 読み直させる前に、PowerToys が無ければ入れる。テストに偽の `pwsh.exe` / `wslpath` と 11 件 | 5 |
| `nix/scripts/bootstrap-windows-google-ime.sh`・`nix/tests/bootstrap-windows-google-ime.test.sh` | 入っているがまだ使っていないときの案内と、`--import` の確かめの対象。テストに 3 件 | 6 |
| `win/README.md`・`nix/README.md`・ADR 017 §2.C / §3・ADR 015 | 使い方・実行順・手順・テストの表・木、ADR を実装に合わせる | 7 |
| ADR 017 §6 | 実機で確かめた結果 | 8 |

---

### Task 1: Google 日本語入力を固定した版に揃える `Install-GoogleJapaneseInput.ps1` を足す

**Files:**
- Create: `win/google-japanese-input/Install-GoogleJapaneseInput.Tests.ps1`
- Create: `win/google-japanese-input/Install-GoogleJapaneseInput.ps1`

**Interfaces:**
- Consumes: なし
- Produces:
  - スクリプト `win/google-japanese-input/Install-GoogleJapaneseInput.ps1`。`param([string]$Version = '3.34.6260.0', [switch]$Check, [switch]$IfMissing)`
  - 終了コード: `-Check` は 0 揃っている (版が同じで pin がある) / 1 差がある (古い・新しい・版が読めない・pin が無い) / 3 入っていない / 2 winget が無い・思わぬ例外 (書き間違えた `-Version` も)。`-IfMissing` は入っていなければ入れて 0 (入らなければ 1)、入っていれば `-Check` と同じ。どちらも付けないと揃えて 0、揃わなければ 1
  - 出力の約束 (Task 4 の bootstrap が読む): 状態の表の 1 行目は `Google 日本語入力 (winget の Google.JapaneseIME)`。`-Check` (と入っているときの `-IfMissing`) の締めの 1 行は `⚠️ ` で始まる (揃っていれば `揃っている`)。入っている版の方が新しいときは、版の行に `(下げない)` が入る。ずれではないことは `※ ` で始まる行で出す
  - 副作用の無い関数 (テストが呼ぶ): `ConvertTo-GoogleImeVersion -Text <string>` → `[version]` か `$null` / `Get-WingetVersionList -Lines <string[]>` → 版の文字列 (新しい順) / `Get-GoogleImeConverterPath -Roots <string[]>` → exe のパス / `Select-GoogleImeConverter -Candidates <object[]>` (要素は `Path` と `ProductVersion`) → `[pscustomobject]@{ Path; Version }` か `$null` / `Get-GoogleImePlan -Exists <bool> -Installed <version> -Target <version>` → `install`・`upgrade`・`newer`・`unknown`・`none` / `Test-WingetPinned -Lines -PackageId` → bool / `Get-WingetCommands -Plan -PackageId -Version` → 引数の配列の配列 / `Get-GoogleImeExitCode -State` → int / `Get-GoogleImeApplyBlocker -Plan -Versions -Target` → `newer`・`unknown`・`not-listed` か `$null` / `Format-GoogleImeState -State -Target` → `Text` と `Warn` を持つ行
  - Windows に触る関数 (テストでは偽物に差し替える): `Invoke-Winget -Arguments`・`Get-GoogleImeConverterOnDisk`・`Test-GoogleImeInstalled`・`Get-GoogleImeState -PackageId -Target`・`Write-GoogleImeState -State -Target`・`Invoke-InstallGoogleJapaneseInput -Version -Check -IfMissing`
  - State の形: `[pscustomobject]@{ Exists [bool]; Path [string]; Installed [version]; Plan [string]; Pinned [bool]; Versions [string[]]; Latest [string] }`

- [ ] **Step 1: テストを書く `win/google-japanese-input/Install-GoogleJapaneseInput.Tests.ps1`**

`$show` は 2026-10-12 にこの PC で `winget show --id Google.JapaneseIME --exact --versions` が出したもの。後半の「流れ」のテストは Windows に触る関数を偽物に差し替えるので、本物の winget は呼ばない。入口のテストは子の pwsh の PATH を空にする (WSL の PATH には Windows の `winget.exe` があるため)。

```powershell
# win/google-japanese-input/Install-GoogleJapaneseInput.ps1 のうち、副作用の無い関数のテスト。Pester は使わない。
# winget やファイルに触る部分は、実機で -Check と本番を打って確かめる (win/README.md の「Google 日本語入力を入れる」)。
#
# WSL から流す (Linux の pwsh で動かすので、Windows 側には触らない):
#   nix shell nixpkgs#powershell -c pwsh -NoProfile -File win/google-japanese-input/Install-GoogleJapaneseInput.Tests.ps1
#
# BOM 付きの UTF-8 で保存すること (win/README.md の「dotfiles.ps1 を書くときの注意」)。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# dot-source すると関数だけを読み、本体は走らない (Install-GoogleJapaneseInput.ps1 の末尾)
. (Join-Path $PSScriptRoot 'Install-GoogleJapaneseInput.ps1')

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
    if ($e -ceq $a) {
        Write-Host "ok   $Name"
    } else {
        Write-Host "FAIL $Name"
        Write-Host "     expected: [$e]"
        Write-Host "     actual:   [$a]"
        $script:Failures++
    }
}

$Id = 'Google.JapaneseIME'
$V = '3.34.6260.0'
$Old = '2.29.5370.0'
$X64 = 'C:\Program Files\Google\Google Japanese Input\GoogleIMEJaConverter.exe'
$X86 = 'C:\Program Files (x86)\Google\Google Japanese Input\GoogleIMEJaConverter.exe'

# 2026-10-12 に winget show --id Google.JapaneseIME --exact --versions が出したもの
$show = @(
    'Found Google 日本語入力 [Google.JapaneseIME]'
    'Version'
    '-----------'
    '3.34.6260.0'
    '3.34.6230.0'
    '3.33.6130.0'
    '3.33.6088.0'
    '2.32.5990.0'
    '2.31.5840.0'
    '2.30.5620.0'
    '2.30.5610.0'
    '2.29.5370.0'
    '2.28.4650.0'
)
# 上の版の行だけ (関数を通さずに書く。関数が無い段階でもテストが最後まで流れるように)
$versions = @($show[3..12])

# ConvertTo-GoogleImeVersion: ProductVersion の文字列を [version] にする
Test-Case 'ProductVersion の形を読む' $Old { ConvertTo-GoogleImeVersion -Text $Old }
Test-Case '前後の空白を落とす' $V { ConvertTo-GoogleImeVersion -Text "  $V `r" }
Test-Case 'FileVersion の形 (build 付き) は読まない' '' { ConvertTo-GoogleImeVersion -Text '2.29.5370.0  (build 63)' }
Test-Case '空なら空' '' { ConvertTo-GoogleImeVersion -Text '' }
Test-Case '$null なら空' '' { ConvertTo-GoogleImeVersion -Text $null }
Test-Case '[version] に収まらない数なら空 (例外にしない)' '' { ConvertTo-GoogleImeVersion -Text '99999999999.1' }

# Get-WingetVersionList: winget show --versions の出力から、版の行だけを新しい順に拾う
Test-Case '版の行だけを上から順に拾う (見出し・区切りは拾わない)' ($versions -join ' ') { Get-WingetVersionList -Lines $show }
Test-Case 'パッケージが無ければ空' '' { Get-WingetVersionList -Lines @('No package found matching input criteria.') }

# Get-GoogleImeConverterPath: 探す場所
Test-Case '64 ビットと x86 の 2 か所 (同じ値は 1 つにする)' "$X64 $X86" { Get-GoogleImeConverterPath -Roots @('C:\Program Files', 'C:\Program Files', 'C:\Program Files (x86)') }
Test-Case '空の値は飛ばし、末尾の \ は落とす' $X64 { Get-GoogleImeConverterPath -Roots @($null, '', 'C:\Program Files\') }
Test-Case '大文字小文字だけ違う重複も 1 つにする' $X64 { Get-GoogleImeConverterPath -Roots @('C:\Program Files', 'C:\PROGRAM FILES') }

# Select-GoogleImeConverter: 見つかったものから 1 つ選ぶ
$onX86 = [pscustomobject]@{ Path = $X86; ProductVersion = $Old }
$onX64 = [pscustomobject]@{ Path = $X64; ProductVersion = $V }
$broken = [pscustomobject]@{ Path = $X64; ProductVersion = '' }
Test-Case '1 つも無ければ空' '' { Select-GoogleImeConverter -Candidates @() }
Test-Case '1 つならそれ (この PC の 2.29)' "$X86 $Old" { $c = Select-GoogleImeConverter -Candidates @($onX86); "$($c.Path) $($c.Version)" }
Test-Case '2 か所にあれば版の新しい方' "$X64 $V" { $c = Select-GoogleImeConverter -Candidates @($onX86, $onX64); "$($c.Path) $($c.Version)" }
Test-Case '版が読めないものより、読めるものを選ぶ' "$X86 $Old" { $c = Select-GoogleImeConverter -Candidates @($broken, $onX86); "$($c.Path) $($c.Version)" }
Test-Case '版が読めるものが無ければ、最初のもので版は空' "$X64 " { $c = Select-GoogleImeConverter -Candidates @($broken); "$($c.Path) $($c.Version)" }

# Get-GoogleImePlan: することを決める ([version] で比べる)
Test-Case '入っていなければ install' 'install' { Get-GoogleImePlan -Exists $false -Installed $null -Target $V }
Test-Case '古ければ upgrade (この PC の 2.29 → 3.34)' 'upgrade' { Get-GoogleImePlan -Exists $true -Installed $Old -Target $V }
Test-Case '新しければ newer (下げない)' 'newer' { Get-GoogleImePlan -Exists $true -Installed '3.35.0.0' -Target $V }
Test-Case '文字列ではなく数で比べる (6260 < 10000)' 'newer' { Get-GoogleImePlan -Exists $true -Installed '3.34.10000.0' -Target $V }
Test-Case '同じなら none' 'none' { Get-GoogleImePlan -Exists $true -Installed $V -Target $V }
Test-Case 'あるのに版が読めなければ unknown' 'unknown' { Get-GoogleImePlan -Exists $true -Installed $null -Target $V }

# Test-WingetPinned: winget pin list の出力に、その Id の行があるか
$pinsOpenSsh = @(
    'Name    Id                        Version  Source Pin type'
    '----------------------------------------------------------'
    'OpenSSH Microsoft.OpenSSH.Preview 10.0.0.0 winget Pinning'
)
Test-Case 'ほかのパッケージの pin しか無ければ False' 'False' { Test-WingetPinned -Lines $pinsOpenSsh -PackageId $Id }
Test-Case 'Id の列が一致すれば True' 'True' { Test-WingetPinned -Lines ($pinsOpenSsh + @("Google 日本語入力 $Id $V winget Pinning")) -PackageId $Id }
Test-Case 'Id の前方一致では True にしない' 'False' { Test-WingetPinned -Lines @("x $($Id)2 $V winget Pinning") -PackageId $Id }

# Get-WingetCommands: plan ごとに打つ winget の引数
$common = "--id $Id --exact --source winget --silent --accept-source-agreements --disable-interactivity"
Test-Case 'install は版を名指しして入れる' "install $common --version $V --accept-package-agreements" { @(Get-WingetCommands -Plan install -PackageId $Id -Version $V)[0] -join ' ' }
Test-Case 'upgrade は版を名指しして上げる' "upgrade $common --version $V --accept-package-agreements" { @(Get-WingetCommands -Plan upgrade -PackageId $Id -Version $V)[0] -join ' ' }
Test-Case 'install と upgrade は 1 本ずつ' '1 1' { "$(@(Get-WingetCommands -Plan install -PackageId $Id -Version $V).Count) $(@(Get-WingetCommands -Plan upgrade -PackageId $Id -Version $V).Count)" }
Test-Case 'none・newer・unknown なら打たない' '0 0 0' { "$(@(Get-WingetCommands -Plan none -PackageId $Id -Version $V).Count) $(@(Get-WingetCommands -Plan newer -PackageId $Id -Version $V).Count) $(@(Get-WingetCommands -Plan unknown -PackageId $Id -Version $V).Count)" }

# 状態の既定 (揃っている)。テストごとに一部を差し替える
function New-State {
    param([hashtable]$Change = @{})
    $s = [ordered]@{
        Exists = $true; Path = $X64; Installed = [version]$V; Plan = 'none'; Pinned = $true
        Versions = $versions; Latest = $versions[0]
    }
    foreach ($k in $Change.Keys) { $s[$k] = $Change[$k] }
    [pscustomobject]$s
}
$missing = @{ Exists = $false; Path = $null; Installed = $null; Plan = 'install'; Pinned = $false }
# この PC (2026-10-12): x86 に 2.29 があり、pin は無い
$thisPc = @{ Path = $X86; Installed = [version]$Old; Plan = 'upgrade'; Pinned = $false }
$thisPcPinned = @{ Path = $X86; Installed = [version]$Old; Plan = 'upgrade'; Pinned = $true }
$newer = @{ Installed = [version]'3.35.0.0'; Plan = 'newer' }

# Get-GoogleImeExitCode: 終了コード
Test-Case '揃っていれば 0' 0 { Get-GoogleImeExitCode -State (New-State) }
Test-Case 'pin が無ければ 1' 1 { Get-GoogleImeExitCode -State (New-State @{ Pinned = $false }) }
Test-Case '古ければ 1' 1 { Get-GoogleImeExitCode -State (New-State $thisPc) }
Test-Case '新しくても 1' 1 { Get-GoogleImeExitCode -State (New-State $newer) }
Test-Case '版が読めなければ 1' 1 { Get-GoogleImeExitCode -State (New-State @{ Installed = $null; Plan = 'unknown' }) }
Test-Case '入っていなければ 3' 3 { Get-GoogleImeExitCode -State (New-State $missing) }

# Get-GoogleImeApplyBlocker: 揃える前に止める理由
Test-Case '入れられるなら止めない' '' { Get-GoogleImeApplyBlocker -Plan install -Versions $versions -Target $V }
Test-Case '上げられるなら止めない' '' { Get-GoogleImeApplyBlocker -Plan upgrade -Versions $versions -Target $V }
Test-Case '固定した版が winget に無ければ not-listed' 'not-listed' { Get-GoogleImeApplyBlocker -Plan upgrade -Versions $versions -Target '3.99.0.0' }
Test-Case 'winget show が失敗して一覧が空なら、一覧では止めない' '' { Get-GoogleImeApplyBlocker -Plan install -Versions @() -Target $V }
Test-Case '新しければ newer で止める' 'newer' { Get-GoogleImeApplyBlocker -Plan newer -Versions $versions -Target $V }
Test-Case '版が読めなければ unknown で止める' 'unknown' { Get-GoogleImeApplyBlocker -Plan unknown -Versions $versions -Target $V }
Test-Case 'pin を足すだけなら止めない' '' { Get-GoogleImeApplyBlocker -Plan none -Versions @() -Target 'x' }

# Format-GoogleImeState: 状態の表の行
function Get-Rows { param($State) @(Format-GoogleImeState -State $State -Target $V) }
Test-Case '揃っていれば ⚠ の行は無い' 0 { @((Get-Rows (New-State)) | Where-Object { $_.Warn }).Count }
Test-Case '揃っていれば表の 5 行だけ' 5 { (Get-Rows (New-State)).Count }
Test-Case '見出しはパッケージ名' 'Google 日本語入力 (winget の Google.JapaneseIME)' { (Get-Rows (New-State))[0].Text }
Test-Case '入っている版と置き場所' "  入っている版    : $V (C:\Program Files\Google\Google Japanese Input)" { (Get-Rows (New-State))[1].Text }
Test-Case '揃っているときの版の行' "  固定した版      : $V → そのまま" { (Get-Rows (New-State))[2].Text }
Test-Case 'この PC: x86 の 2.29 を出す' "  入っている版    : $Old (C:\Program Files (x86)\Google\Google Japanese Input)" { (Get-Rows (New-State $thisPc))[1].Text }
Test-Case 'この PC: 上げるで ⚠' "⚠ 固定した版      : $V → 上げる" { (Get-Rows (New-State $thisPc))[2].Text }
Test-Case 'この PC: pin が無くて ⚠' '⚠ winget pin      : 無し → 足す' { (Get-Rows (New-State $thisPc))[4].Text }
Test-Case '入っていなければ「入っていない」' '  入っている版    : 入っていない' { (Get-Rows (New-State $missing))[1].Text }
Test-Case '入っていなければ「入れる」で ⚠' "⚠ 固定した版      : $V → 入れる" { (Get-Rows (New-State $missing))[2].Text }
Test-Case '新しければ「下げない」で ⚠' "⚠ 固定した版      : $V → 入っている版の方が新しい (下げない)" { (Get-Rows (New-State $newer))[2].Text }
Test-Case '新しければ ※ で repo の版の上げ方を添える' '※ 入っている版の方が新しい (Google 日本語入力が自分で上がった?)。下げずに、Install-GoogleJapaneseInput.ps1 の -Version の既定値を 3.35.0.0 に上げ、bootstrap-windows-google-ime.sh の --dry-run と --import で設定を読み書きできるかを確かめてから commit する' { (Get-Rows (New-State $newer))[-1].Text }
Test-Case '版が読めなければ「不明」' '  入っている版    : 不明 (GoogleIMEJaConverter.exe の ProductVersion が読めない。C:\Program Files\Google\Google Japanese Input)' { (Get-Rows (New-State @{ Installed = $null; Plan = 'unknown' }))[1].Text }
Test-Case '版が読めなければ ※ で確かめ方を添える' '※ 版が読めないので比べられない。winget list --id Google.JapaneseIME で入っている版を確かめる' { (Get-Rows (New-State @{ Installed = $null; Plan = 'unknown' }))[-1].Text }
Test-Case 'winget show が失敗したら最新版は不明' '  winget の最新版 : 不明 (winget show が失敗)' { (Get-Rows (New-State @{ Versions = @(); Latest = $null }))[3].Text }
Test-Case 'winget show が失敗したら、一覧についての ※/⚠ は出さない' 5 { (Get-Rows (New-State @{ Versions = @(); Latest = $null })).Count }
Test-Case '新しい版が winget にあれば ※ で知らせる' '※ winget に固定した版より新しい 3.35.6300.0 がある。上げるなら Install-GoogleJapaneseInput.ps1 の -Version の既定値を変える' { (Get-Rows (New-State @{ Versions = @('3.35.6300.0') + $versions; Latest = '3.35.6300.0' }))[5].Text }
Test-Case '新しい版が winget にあっても ⚠ にしない' 0 { @((Get-Rows (New-State @{ Versions = @('3.35.6300.0') + $versions; Latest = '3.35.6300.0' })) | Where-Object { $_.Warn }).Count }
Test-Case '固定した版が winget から消えても、入っていれば ※' '※ 固定した版が winget から消えている。新しいマシンには入れられないので、-Version を winget にある版へ変える' { (Get-Rows (New-State @{ Versions = @('3.35.6300.0', $Old); Latest = '3.35.6300.0' }))[5].Text }
Test-Case '固定した版が winget に無くて入れられないなら ⚠' '⚠ 固定した版が winget show --versions に無い (書き間違いか、winget から消えた) ので入れられない' { (Get-Rows (New-State ($missing + @{ Versions = @('3.35.6300.0', $Old); Latest = '3.35.6300.0' })))[5].Text }

# 本体の入口: Linux の pwsh には winget が無いので、終了コード 2 で止まる (成功 (0) に見せない)。
# 子の PATH は空にする (WSL の PATH には Windows の winget.exe があり、名前が違っても本物を呼ばないように)
function Invoke-Entry {
    param([string[]]$Arguments)
    $pwsh = (Get-Process -Id $PID).Path
    $savedPath = $env:PATH
    try {
        $env:PATH = ''
        $out = @(& $pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Install-GoogleJapaneseInput.ps1') @Arguments 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
    } finally {
        $env:PATH = $savedPath
    }
    [pscustomobject]@{ Code = $code; Text = ($out -join "`n") }
}
Test-Case '入口: winget が無ければ終了コード 2' '2' { (Invoke-Entry -Arguments @('-Check')).Code }
Test-Case '入口: 書き間違えた -Version は例外を受け止めて終了コード 2' '2 True' { $r = Invoke-Entry -Arguments @('-Check', '-Version', 'not-a-version'); "$($r.Code) $($r.Text -like '*エラーで止まった*')" }

# ---------------------------------------------------------------------------
# Invoke-InstallGoogleJapaneseInput の流れ。Windows に触る関数を偽物に差し替えて、打つ winget の順と、
# 途中で失敗したときの扱いを確かめる。ここより後ろでは本物の関数は使えない
# ---------------------------------------------------------------------------

# Get-Command winget を通すためだけの関数 (呼ばれるのは下の Invoke-Winget)
function winget { }
# 打った winget を記録する (pin は 'pin add' のように 2 語)。install と upgrade は入った状態にする
function Invoke-Winget {
    param([string[]]$Arguments)
    $verb = if ($Arguments[0] -eq 'pin') { "pin $($Arguments[1])" } else { $Arguments[0] }
    $script:Calls.Add($verb)
    $code = 0
    if ($script:Fail.ContainsKey($verb)) { $code = $script:Fail[$verb] }
    if (($code -eq 0) -and (@('install', 'upgrade') -contains $verb)) { $script:InstalledNow = $true }
    $lines = @()
    if (($verb -eq 'pin list') -and $script:PinListed) { $lines = @("Google 日本語入力 $Id $V winget Pinning") }
    [pscustomobject]@{ ExitCode = $code; Lines = $lines }
}
function Test-GoogleImeInstalled { [bool]$script:InstalledNow }
function Get-GoogleImeState { param($PackageId, $Target) $script:States.Dequeue() }

# 1 回ぶんの流れを走らせ、打った winget・画面の行・終了コードを返す。
# $States は Get-GoogleImeState が返す順 (揃える前と、揃えた後に読み直したもの)
function Invoke-Flow {
    param([object[]]$States, [switch]$Check, [switch]$IfMissing, [hashtable]$Fail = @{}, [switch]$Installed, [switch]$PinListed)
    $script:Calls = [System.Collections.Generic.List[string]]::new()
    $script:States = [System.Collections.Generic.Queue[object]]::new()
    foreach ($s in $States) { $script:States.Enqueue($s) }
    $script:Fail = $Fail
    $script:InstalledNow = [bool]$Installed
    $script:PinListed = [bool]$PinListed
    $out = @(Invoke-InstallGoogleJapaneseInput -Version $V -Check:$Check -IfMissing:$IfMissing 6>&1)
    [pscustomobject]@{
        Calls = ($script:Calls -join ' ')
        Text  = (@($out | Where-Object { $_ -isnot [int] } | ForEach-Object { "$_" }) -join "`n")
        Code  = @($out | Where-Object { $_ -is [int] })[-1]
    }
}

$synced = New-State
Test-Case '-Check は winget を打たない' '1 []' { $r = Invoke-Flow -States @((New-State $thisPc)) -Check -Installed; "$($r.Code) [$($r.Calls)]" }
Test-Case '-Check は入っていなければ 3' '3 []' { $r = Invoke-Flow -States @((New-State $missing)) -Check; "$($r.Code) [$($r.Calls)]" }
Test-Case '-IfMissing は入っていれば上げない (pin も足さない)' '1 []' { $r = Invoke-Flow -States @((New-State $thisPc)) -IfMissing -Installed; "$($r.Code) [$($r.Calls)]" }
Test-Case '-IfMissing は入っていなければ install して pin を足す' '0 [install pin list pin add]' { $r = Invoke-Flow -States @((New-State $missing), $synced) -IfMissing; "$($r.Code) [$($r.Calls)]" }
Test-Case '入れる前に UAC の確認が出ると出す' $true { $r = Invoke-Flow -States @((New-State $missing), $synced) -IfMissing; $r.Text -like '*UAC の確認が出る*' }
Test-Case '揃っていれば何も打たない' '0 []' { $r = Invoke-Flow -States @($synced) -Installed; "$($r.Code) [$($r.Calls)]" }
Test-Case 'pin だけ無ければ pin を足すだけ (UAC は出ない)' '0 [pin list pin add] False' { $r = Invoke-Flow -States @((New-State @{ Pinned = $false }), $synced) -Installed; "$($r.Code) [$($r.Calls)] $($r.Text -like '*UAC*')" }
Test-Case 'この PC: upgrade して pin を足す' '0 [upgrade pin list pin add]' { $r = Invoke-Flow -States @((New-State $thisPc), $synced) -Installed; "$($r.Code) [$($r.Calls)]" }
Test-Case '上げる前に、アプリを閉じるよう出す' $true { $r = Invoke-Flow -States @((New-State $thisPc), $synced) -Installed; $r.Text -like '*アプリをできるだけ閉じる*' }
Test-Case 'pin があるときは外してから上げ、足し直す' '0 [pin remove upgrade pin list pin add]' { $r = Invoke-Flow -States @((New-State $thisPcPinned), $synced) -Installed; "$($r.Code) [$($r.Calls)]" }
Test-Case '新しければ何も打たずに 1 (下げない)' '1 [] True' { $r = Invoke-Flow -States @((New-State $newer)) -Installed; "$($r.Code) [$($r.Calls)] $($r.Text -like '*下げない*')" }
Test-Case '版が読めなければ何も打たずに 1' '1 []' { $r = Invoke-Flow -States @((New-State @{ Installed = $null; Plan = 'unknown' })) -Installed; "$($r.Code) [$($r.Calls)]" }
Test-Case '固定した版が winget に無ければ何も打たずに 1' '1 []' { $r = Invoke-Flow -States @((New-State ($missing + @{ Versions = @('3.35.6300.0'); Latest = '3.35.6300.0' }))) -IfMissing; "$($r.Code) [$($r.Calls)]" }
Test-Case 'install が落ちたら (UAC で断った) pin を足さずに 1' '1 [install pin list]' { $r = Invoke-Flow -States @((New-State $missing), (New-State $missing)) -IfMissing -Fail @{ install = 0x8A150011 }; "$($r.Code) [$($r.Calls)]" }
Test-Case 'install が落ちたら、打ち直し方を出す' $true { $r = Invoke-Flow -States @((New-State $missing), (New-State $missing)) -IfMissing -Fail @{ install = 0x8A150011 }; $r.Text -like '*Install-GoogleJapaneseInput を打ち直す*' }
Test-Case '上げても版が古いまま (再起動待ち) なら、再起動を案内して 1' '1 True' { $r = Invoke-Flow -States @((New-State $thisPc), (New-State $thisPcPinned)) -Installed; "$($r.Code) $($r.Text -like '*再起動してから*')" }

if ($script:Failures -gt 0) {
    Write-Host "$($script:Failures) 件失敗"
    exit 1
}
Write-Host 'すべて通った'
```

- [ ] **Step 2: BOM を付ける**

Write ツールは BOM を付けない。次のコマンドは BOM が無いときだけ付ける (2 回流しても二重にならない)。この plan で `.ps1` を書いたら毎回これを流す。

```bash
bash -c 'for f in "$@"; do if [[ $(head -c3 "$f" | od -An -tx1 | tr -d " ") != efbbbf ]]; then { printf "\xef\xbb\xbf"; cat "$f"; } >"$f.tmp" && mv "$f.tmp" "$f"; fi; printf "%s: %s\n" "$f" "$(head -c3 "$f" | od -An -tx1)"; done' _ win/google-japanese-input/Install-GoogleJapaneseInput.Tests.ps1
```

Expected: `win/google-japanese-input/Install-GoogleJapaneseInput.Tests.ps1:  ef bb bf`

- [ ] **Step 3: テストが落ちることを確かめる**

Run: `nix shell nixpkgs#powershell -c pwsh -NoProfile -File win/google-japanese-input/Install-GoogleJapaneseInput.Tests.ps1; echo "rc=$?"`
Expected: 12 行目の dot-source で止まり、`The term '…/win/google-japanese-input/Install-GoogleJapaneseInput.ps1' is not recognized as a name of a cmdlet, function, script file, or executable program.` と `rc=1`。

- [ ] **Step 4: スクリプトを書く `win/google-japanese-input/Install-GoogleJapaneseInput.ps1`**

```powershell
<#
.SYNOPSIS
Windows の Google 日本語入力 (winget の Google.JapaneseIME) を、決めた版に揃える。

.DESCRIPTION
dotfiles の win/google-japanese-input/Install-GoogleJapaneseInput.ps1 を %USERPROFILE%\.config\powershell\ へ配り、
PowerShell では dotfiles.ps1 の Install-GoogleJapaneseInput から呼ぶ (win/README.md の「Google 日本語入力を入れる」)。

winget の Google.JapaneseIME は machine スコープの MSI (wix) だけで、入れる・上げるときは Windows の
デスクトップに UAC の確認が出る。日本語入力は全部のアプリに読み込まれているので、上げるとアプリや
Windows の再起動が要ることがある。そこで setup (bootstrap-windows-google-ime-install.sh) は入っていない
ときだけ -IfMissing で入れ、上げるのは人がこのスクリプトを打つ (ADR 017)。入っている版の方が新しくても
下げない (repo の版を上げるよう案内する)。

版は GoogleIMEJaConverter.exe の ProductVersion で読む (FileVersion は "2.29.5370.0  (build 63)" の形で、
winget の版と書き方が違う)。置き場所は版によって Program Files と Program Files (x86) のどちらかなので、両方を見る。

BOM 付きの UTF-8 で保存すること (Windows PowerShell 5.1 は BOM の無い UTF-8 を CP932 として読む)。

.PARAMETER Version
固定する版。winget show --id Google.JapaneseIME --versions に出る値。版を変えるときはここの既定値を変える
(win/README.md の「Google 日本語入力を入れる」の手順で、設定を読み書きできるかを確かめてから commit する)。

.PARAMETER Check
今の状態と固定した版との差を出すだけで、何も変えない。揃っていれば終了コード 0、差があれば 1、
入っていなければ 3、確かめられなければ 2。

.PARAMETER IfMissing
入っていなければ固定した版を入れて pin を足す。入っていれば -Check と同じで、上げはしない (setup --update が使う)。
#>
[CmdletBinding()]
param(
    [string]$Version = '3.34.6260.0',
    [switch]$Check,
    [switch]$IfMissing
)

# ---------------------------------------------------------------------------
# 副作用の無い関数 (Install-GoogleJapaneseInput.Tests.ps1 で確かめる)
# ---------------------------------------------------------------------------

# 版の文字列 ("2.29.5370.0") を [version] にする。数字を . でつないだ 2〜4 個の形でなければ $null
# (FileVersion の "2.29.5370.0  (build 63)" のような形は読まない)
function ConvertTo-GoogleImeVersion {
    param([string]$Text)
    $v = $null
    if (("$Text" -match '^\s*(\d+(\.\d+){1,3})\s*$') -and [version]::TryParse($Matches[1], [ref]$v)) { return $v }
    $null
}

# winget show --versions の出力から、版の行だけを上から順 (= 新しい順) に拾う (Install-Herdr.ps1 と同じ)。
# 呼ぶ側は @() で包む (1 つも無いと $null にほどける)
function Get-WingetVersionList {
    param([string[]]$Lines)
    foreach ($line in $Lines) {
        if ("$line" -match '^\s*(\d+(\.\d+)+(-[0-9A-Za-z][0-9A-Za-z.-]*)?)\s*$') { $Matches[1] }
    }
}

# GoogleIMEJaConverter.exe を探す場所 (Program Files の候補ごとに 1 つ)。空の値と、大文字小文字だけが
# 違う重複は除く (64 ビットの PowerShell では ProgramW6432 と ProgramFiles が同じ)。
# 区切りは \ で組む (Linux の pwsh で流すテストでも同じ文字列になるよう、Join-Path は使わない)
function Get-GoogleImeConverterPath {
    param([string[]]$Roots)
    $seen = @{}
    foreach ($root in $Roots) {
        if (-not $root) { continue }
        $dir = $root.TrimEnd('\')
        $key = $dir.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        "$dir\Google\Google Japanese Input\GoogleIMEJaConverter.exe"
    }
}

# 見つかった GoogleIMEJaConverter.exe (Path と ProductVersion の組) から 1 つ選ぶ。2 か所にあれば版の
# 新しい方。版が読めるものが無ければ最初のもの (Version は $null)。1 つも無ければ $null
function Select-GoogleImeConverter {
    param([object[]]$Candidates)
    $best = $null
    foreach ($c in @($Candidates | Where-Object { $_ })) {
        $v = ConvertTo-GoogleImeVersion -Text $c.ProductVersion
        if (($null -eq $best) -or (($null -ne $v) -and (($null -eq $best.Version) -or ($v -gt $best.Version)))) {
            $best = [pscustomobject]@{ Path = $c.Path; Version = $v }
        }
    }
    $best
}

# 入っているか・入っている版・固定した版から、することを決める
#   install: 入っていない / upgrade: 古い / newer: 新しい (下げない) / unknown: 版が読めない / none: 同じ
function Get-GoogleImePlan {
    param([bool]$Exists, [version]$Installed, [version]$Target)
    if (-not $Exists) { return 'install' }
    if ($null -eq $Installed) { return 'unknown' }
    if ($Installed -lt $Target) { return 'upgrade' }
    if ($Installed -gt $Target) { return 'newer' }
    'none'
}

# winget pin list の出力に、その Id を列に持つ行があるか (Install-Herdr.ps1 と同じ)。
# 見出しや「pin が無い」の文言は表示言語で変わるので、Id の一致だけを見る
function Test-WingetPinned {
    param([string[]]$Lines, [string]$PackageId)
    foreach ($line in $Lines) {
        if (($line -split '\s+') -ccontains $PackageId) { return $true }
    }
    $false
}

# plan ごとに打つ winget の引数 (配列の配列)。上げるときは winget upgrade に版を名指しする
# (MSI の更新で入れ替わる。Install-OpenSSH.ps1 と同じ)
function Get-WingetCommands {
    param([string]$Plan, [string]$PackageId, [string]$Version)
    $common = @('--id', $PackageId, '--exact', '--source', 'winget', '--silent',
        '--accept-source-agreements', '--disable-interactivity')
    $put = $common + @('--version', $Version, '--accept-package-agreements')
    switch ($Plan) {
        'install' { , (@('install') + $put) }
        'upgrade' { , (@('upgrade') + $put) }
    }
}

# 終了コード。入っていなければ 3、版と pin が揃っていれば 0、ほかは 1
function Get-GoogleImeExitCode {
    param($State)
    if ($State.Plan -eq 'install') { return 3 }
    if (($State.Plan -eq 'none') -and $State.Pinned) { return 0 }
    1
}

# 揃える前に止める理由。無ければ $null
#   newer:      入っている版の方が新しい (下げない)
#   unknown:    版が読めないので比べられない
#   not-listed: 入れる・上げるのに、固定した版が winget に無い (版の一覧が読めたときだけ判断する)
function Get-GoogleImeApplyBlocker {
    param([string]$Plan, [string[]]$Versions, [string]$Target)
    if ($Plan -eq 'newer') { return 'newer' }
    if ($Plan -eq 'unknown') { return 'unknown' }
    $known = @($Versions | Where-Object { $_ })
    if ((@('install', 'upgrade') -contains $Plan) -and ($known.Count -gt 0) -and ($known -cnotcontains $Target)) { return 'not-listed' }
    $null
}

# 状態の表の行 (Text と、直すことがあるかの Warn)。直すことがある行だけ先頭に ⚠ を付け、
# ほかは 2 字下げる。ずれではないこと (winget に新しい版がある) は ※ で添える
function Format-GoogleImeState {
    param($State, [string]$Target)
    $planText = switch ($State.Plan) {
        'install' { '入れる' }
        'upgrade' { '上げる' }
        'newer' { '入っている版の方が新しい (下げない)' }
        'unknown' { '比べられない' }
        default { 'そのまま' }
    }
    $dir = ''
    if ($State.Path) {
        $cut = $State.Path.LastIndexOf('\')
        $dir = if ($cut -ge 0) { $State.Path.Substring(0, $cut) } else { $State.Path }
    }
    $installedText = if ($State.Plan -eq 'install') { '入っていない' } elseif ($null -ne $State.Installed) { "$($State.Installed) ($dir)" } else { "不明 (GoogleIMEJaConverter.exe の ProductVersion が読めない。$dir)" }
    $latestText = if ($State.Latest) { $State.Latest } else { '不明 (winget show が失敗)' }
    $pinText = if ($State.Pinned) { 'あり' } else { '無し → 足す' }
    $rows = @(
        @{ Text = 'Google 日本語入力 (winget の Google.JapaneseIME)'; Warn = $false; Indent = $false }
        @{ Text = "入っている版    : $installedText"; Warn = $false; Indent = $true }
        @{ Text = "固定した版      : $Target → $planText"; Warn = ($State.Plan -ne 'none'); Indent = $true }
        @{ Text = "winget の最新版 : $latestText"; Warn = $false; Indent = $true }
        @{ Text = "winget pin      : $pinText"; Warn = (-not $State.Pinned); Indent = $true }
    )
    foreach ($row in $rows) {
        $prefix = if (-not $row.Indent) { '' } elseif ($row.Warn) { '⚠ ' } else { '  ' }
        [pscustomobject]@{ Text = "$prefix$($row.Text)"; Warn = [bool]$row.Warn }
    }
    $versions = @($State.Versions | Where-Object { $_ })
    if (($versions.Count -gt 0) -and ($versions -cnotcontains $Target)) {
        if (@('install', 'upgrade') -contains $State.Plan) {
            [pscustomobject]@{ Text = '⚠ 固定した版が winget show --versions に無い (書き間違いか、winget から消えた) ので入れられない'; Warn = $true }
        } else {
            [pscustomobject]@{ Text = '※ 固定した版が winget から消えている。新しいマシンには入れられないので、-Version を winget にある版へ変える'; Warn = $false }
        }
    } elseif (($versions.Count -gt 0) -and ($versions[0] -cne $Target)) {
        [pscustomobject]@{ Text = "※ winget に固定した版より新しい $($versions[0]) がある。上げるなら Install-GoogleJapaneseInput.ps1 の -Version の既定値を変える"; Warn = $false }
    }
    if ($State.Plan -eq 'newer') {
        [pscustomobject]@{ Text = "※ 入っている版の方が新しい (Google 日本語入力が自分で上がった?)。下げずに、Install-GoogleJapaneseInput.ps1 の -Version の既定値を $($State.Installed) に上げ、bootstrap-windows-google-ime.sh の --dry-run と --import で設定を読み書きできるかを確かめてから commit する"; Warn = $false }
    }
    if ($State.Plan -eq 'unknown') {
        [pscustomobject]@{ Text = '※ 版が読めないので比べられない。winget list --id Google.JapaneseIME で入っている版を確かめる'; Warn = $false }
    }
}

# ---------------------------------------------------------------------------
# Windows に触る関数 (実機で -Check と本番を打って確かめる)
# ---------------------------------------------------------------------------

# winget を打ち、出力の行 (進み具合の表示は除く) と終了コードを返す (Install-OpenSSH.ps1 と同じ)
function Invoke-Winget {
    param([string[]]$Arguments)
    # 5.1 では Stop のままだと、外部コマンドの stderr の 1 行目で止まる
    $ErrorActionPreference = 'Continue'
    $lines = & winget @Arguments 2>&1 | ForEach-Object { "$_" } |
        Where-Object { $_ -notmatch '^\s*[-\\|/]?\s*$' -and $_ -notmatch '[█▒]' }
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Lines = @($lines) }
}

# Program Files (64 ビットと x86) にある GoogleIMEJaConverter.exe と、その ProductVersion
function Get-GoogleImeConverterOnDisk {
    foreach ($exe in @(Get-GoogleImeConverterPath -Roots @($env:ProgramW6432, $env:ProgramFiles, ${env:ProgramFiles(x86)}))) {
        if (Test-Path -LiteralPath $exe -PathType Leaf) {
            [pscustomobject]@{ Path = $exe; ProductVersion = (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion }
        }
    }
}

# 入っているか (揃えた後に pin を足すかを決める)
function Test-GoogleImeInstalled {
    @(Get-GoogleImeConverterOnDisk).Count -gt 0
}

# 今の状態を読む (何も変えない。管理者は要らない)
function Get-GoogleImeState {
    param([string]$PackageId, [version]$Target)
    $converter = Select-GoogleImeConverter -Candidates @(Get-GoogleImeConverterOnDisk)
    $pins = Invoke-Winget -Arguments @('pin', 'list', '--id', $PackageId, '--exact', '--accept-source-agreements', '--disable-interactivity')
    $show = Invoke-Winget -Arguments @('show', '--id', $PackageId, '--exact', '--versions', '--source', 'winget', '--accept-source-agreements', '--disable-interactivity')
    # @() で包む。関数が返す空の配列は呼び出し側で $null にほどける (Install-OpenSSH.ps1 で踏んだ)
    $versions = @(Get-WingetVersionList -Lines $show.Lines)
    $latest = $null
    if ($versions.Count -gt 0) { $latest = $versions[0] }
    $exists = $null -ne $converter
    $path = $null
    $installed = $null
    if ($exists) {
        $path = $converter.Path
        $installed = $converter.Version
    }
    [pscustomobject]@{
        Exists    = $exists
        Path      = $path
        Installed = $installed
        Plan      = Get-GoogleImePlan -Exists $exists -Installed $installed -Target $Target
        Pinned    = Test-WingetPinned -Lines $pins.Lines -PackageId $PackageId
        Versions  = $versions
        Latest    = $latest
    }
}

# 状態の表を出す。直すことがある行 (⚠) は黄色にする
function Write-GoogleImeState {
    param($State, [string]$Target)
    foreach ($row in (Format-GoogleImeState -State $State -Target $Target)) {
        if ($row.Warn) { Write-Host $row.Text -ForegroundColor Yellow } else { Write-Host $row.Text }
    }
}

function Invoke-InstallGoogleJapaneseInput {
    param([string]$Version, [switch]$Check, [switch]$IfMissing)
    $packageId = 'Google.JapaneseIME'
    # 書き間違えた -Version は、winget を打つ前にここで例外になる (終了コード 2)
    $target = [version]$Version

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host 'winget が見つからない。Microsoft Store の「アプリ インストーラー」を入れる'
        return 2
    }

    $state = Get-GoogleImeState -PackageId $packageId -Target $target
    Write-GoogleImeState -State $state -Target $Version
    $code = Get-GoogleImeExitCode -State $state

    # -Check は何も変えない。-IfMissing は入っていないときだけ入れ、入っていれば -Check と同じ
    if ($Check -or ($IfMissing -and ($state.Plan -ne 'install'))) {
        if ($code -eq 0) {
            Write-Host '揃っている'
        } elseif ($code -eq 3) {
            Write-Host '⚠️ Google 日本語入力が入っていない → Install-GoogleJapaneseInput で入れる (UAC の確認が出る) ⚠️' -ForegroundColor Yellow
        } elseif ($state.Plan -eq 'newer') {
            Write-Host '⚠️ 入っている版の方が新しい → 下げずに Install-GoogleJapaneseInput.ps1 の -Version を上げる ⚠️' -ForegroundColor Yellow
        } else {
            Write-Host '⚠️ 固定した版と揃っていない → Install-GoogleJapaneseInput で揃える (上げるときは UAC の確認が出る) ⚠️' -ForegroundColor Yellow
        }
        return $code
    }
    if ($code -eq 0) {
        Write-Host '揃っている。何もしない'
        return 0
    }

    $blocker = Get-GoogleImeApplyBlocker -Plan $state.Plan -Versions $state.Versions -Target $Version
    if ($blocker -eq 'newer') {
        Write-Host "入っている版 ($($state.Installed)) の方が固定した版 ($Version) より新しいので、下げない。Install-GoogleJapaneseInput.ps1 の -Version の既定値を上げる (win/README.md の「Google 日本語入力を入れる」)"
        return 1
    }
    if ($blocker -eq 'unknown') {
        Write-Host "GoogleIMEJaConverter.exe の版が読めないので、何もしない。winget list --id $packageId で入っている版を確かめる"
        return 1
    }
    if ($blocker -eq 'not-listed') {
        Write-Host "固定した版 $Version が winget に無いので入れられない。-Version を winget show --id $packageId --versions にある版へ変える"
        return 1
    }

    if ($state.Plan -eq 'upgrade') {
        Write-Host '上げる前に、日本語入力を使っているアプリをできるだけ閉じる (使用中のファイルは、Windows を再起動するまで置き換わらないことがある)'
    }
    if ($state.Plan -ne 'none') {
        Write-Host 'Windows のデスクトップに UAC の確認が出る。「はい」を押す'
    }
    # 上げるときは、古い版の pin を残さないよう先に外す (上げた後に足し直す。Install-Herdr.ps1 と同じ)
    if (($state.Plan -eq 'upgrade') -and $state.Pinned) {
        $unpin = Invoke-Winget -Arguments @('pin', 'remove', '--id', $packageId, '--exact', '--accept-source-agreements', '--disable-interactivity')
        if ($unpin.ExitCode -ne 0) { Write-Host ('winget pin remove が失敗した (終了コード 0x{0:X8})' -f $unpin.ExitCode) }
    }
    foreach ($arguments in @(Get-WingetCommands -Plan $state.Plan -PackageId $packageId -Version $Version)) {
        Write-Host "winget $($arguments -join ' ')"
        $result = Invoke-Winget -Arguments $arguments
        $result.Lines | Select-Object -Last 5 | ForEach-Object { Write-Host "  $_" }
        if ($result.ExitCode -ne 0) {
            Write-Host ('winget が失敗した (終了コード 0x{0:X8})。UAC で「いいえ」を押したなら、Install-GoogleJapaneseInput を打ち直す' -f $result.ExitCode)
            break
        }
    }
    # 入っていれば pin を足す (上げた後は、上で外したので足し直しになる)
    $pins = Invoke-Winget -Arguments @('pin', 'list', '--id', $packageId, '--exact', '--accept-source-agreements', '--disable-interactivity')
    if ((Test-GoogleImeInstalled) -and -not (Test-WingetPinned -Lines $pins.Lines -PackageId $packageId)) {
        $pin = Invoke-Winget -Arguments @('pin', 'add', '--id', $packageId, '--exact', '--accept-source-agreements', '--disable-interactivity')
        if ($pin.ExitCode -eq 0) { Write-Host 'winget pin を足した (winget upgrade --all から外れる)' }
        else { Write-Host ('winget pin add が失敗した (終了コード 0x{0:X8})' -f $pin.ExitCode) }
    }

    # 揃ったかを読み直して確かめる
    Write-Host ''
    $after = Get-GoogleImeState -PackageId $packageId -Target $target
    Write-GoogleImeState -State $after -Target $Version
    if ((Get-GoogleImeExitCode -State $after) -eq 0) {
        Write-Host '揃った'
        return 0
    }
    if ($after.Plan -eq 'upgrade') {
        Write-Host '版が揃っていない。使用中のファイルが Windows の再起動待ちになったなら、再起動してから Install-GoogleJapaneseInput -Check で確かめる'
    }
    return 1
}

# dot-source されたとき (テスト) は関数だけを読み、本体は走らせない。
# 思わぬ例外は受け止めて終了コード 2 で終える。受け止めないと exit まで届かず、
# -Command から呼んだとき外側の exit $LASTEXITCODE が中の winget の 0 を返して成功に見える
if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest
    try {
        exit (Invoke-InstallGoogleJapaneseInput -Version $Version -Check:$Check -IfMissing:$IfMissing)
    } catch {
        Write-Host "エラーで止まった: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace
        exit 2
    }
}
```

- [ ] **Step 5: BOM を付ける**

```bash
bash -c 'for f in "$@"; do if [[ $(head -c3 "$f" | od -An -tx1 | tr -d " ") != efbbbf ]]; then { printf "\xef\xbb\xbf"; cat "$f"; } >"$f.tmp" && mv "$f.tmp" "$f"; fi; printf "%s: %s\n" "$f" "$(head -c3 "$f" | od -An -tx1)"; done' _ win/google-japanese-input/Install-GoogleJapaneseInput.ps1
```

Expected: `win/google-japanese-input/Install-GoogleJapaneseInput.ps1:  ef bb bf`

- [ ] **Step 6: テストが通ることを確かめる**

Run: `nix shell nixpkgs#powershell -c pwsh -NoProfile -File win/google-japanese-input/Install-GoogleJapaneseInput.Tests.ps1 | grep -v '^ok'`
Expected: `すべて通った` の 1 行だけ (`FAIL` の行も `N 件失敗` も出ない。失敗があるとテストは exit 1 で、最後の行が `N 件失敗` になる)。

Run: `nix shell nixpkgs#powershell -c pwsh -NoProfile -File win/google-japanese-input/Install-GoogleJapaneseInput.Tests.ps1 | grep -c '^ok'`
Expected: `80`

- [ ] **Step 7: Commit**

```bash
git add win/google-japanese-input/Install-GoogleJapaneseInput.ps1 win/google-japanese-input/Install-GoogleJapaneseInput.Tests.ps1
git commit -F - <<'EOF'
feat(win): Google 日本語入力を winget で固定した版に揃える Install-GoogleJapaneseInput.ps1 を足す (TKT-143)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01YSF6gCGyvBHzRBtjbB61Fm
EOF
```

---

### Task 2: PowerToys が無ければ入れる `Install-PowerToys.ps1` を足す

**Files:**
- Create: `win/powertoys/Install-PowerToys.Tests.ps1`
- Create: `win/powertoys/Install-PowerToys.ps1`

**Interfaces:**
- Consumes: なし
- Produces:
  - スクリプト `win/powertoys/Install-PowerToys.ps1`。`param([switch]$Check, [switch]$IfMissing)`
  - 終了コード: `-Check` は 0 入っている / 3 入っていない / 2 思わぬ例外。`-IfMissing` (と引数なし) は、入っていれば 0、入っていなければ入れて 0、入らなければ 1、winget が無ければ 2
  - 出力の約束 (Task 5 の bootstrap が読む): 状態の表の 1 行目は `PowerToys (winget の Microsoft.PowerToys。版は固定しない)`。入っていないときの `-Check` の締めの 1 行は `⚠️ ` で始まる。入っていれば `入っている`、入れ終えたら `入った`
  - 副作用の無い関数: `Get-PowerToysExeCandidate -LocalAppData <string> -ProgramFiles <string>` → exe のパス (user、machine の順) / `Find-PowerToysExe -Candidates <string[]> -Exists <scriptblock>` → パスか `$null` / `Get-PowerToysInstallArguments -PackageId` → 引数の配列 / `Get-PowerToysExitCode -State` → 0 か 3 / `Format-PowerToysState -State` → `Text` と `Warn` を持つ行
  - Windows に触る関数: `Invoke-Winget -Arguments`・`Get-PowerToysState` (引数なし)・`Write-PowerToysState -State`・`Invoke-InstallPowerToys -Check`
  - State の形: `[pscustomobject]@{ Exe [string]; Version [string] }` (入っていなければ `Exe` が `$null`)

- [ ] **Step 1: テストを書く `win/powertoys/Install-PowerToys.Tests.ps1`**

```powershell
# win/powertoys/Install-PowerToys.ps1 のうち、副作用の無い関数のテスト。Pester は使わない。
# winget やファイルに触る部分は、実機で -Check を打って確かめる (win/README.md の「PowerToys を入れる」)。
#
# WSL から流す (Linux の pwsh で動かすので、Windows 側には触らない):
#   nix shell nixpkgs#powershell -c pwsh -NoProfile -File win/powertoys/Install-PowerToys.Tests.ps1
#
# BOM 付きの UTF-8 で保存すること (win/README.md の「dotfiles.ps1 を書くときの注意」)。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# dot-source すると関数だけを読み、本体は走らない (Install-PowerToys.ps1 の末尾)
. (Join-Path $PSScriptRoot 'Install-PowerToys.ps1')

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
    if ($e -ceq $a) {
        Write-Host "ok   $Name"
    } else {
        Write-Host "FAIL $Name"
        Write-Host "     expected: [$e]"
        Write-Host "     actual:   [$a]"
        $script:Failures++
    }
}

$Id = 'Microsoft.PowerToys'
$User = 'C:\Users\u\AppData\Local\PowerToys\PowerToys.exe'
$Machine = 'C:\Program Files\PowerToys\PowerToys.exe'

# Get-PowerToysExeCandidate: 置き場所の候補 (user スコープ、machine スコープの順)
Test-Case 'user スコープ、machine スコープの順' "$User $Machine" { Get-PowerToysExeCandidate -LocalAppData 'C:\Users\u\AppData\Local' -ProgramFiles 'C:\Program Files' }
Test-Case '末尾の \ は落とす' "$User $Machine" { Get-PowerToysExeCandidate -LocalAppData 'C:\Users\u\AppData\Local\' -ProgramFiles 'C:\Program Files\' }
Test-Case '空の値は飛ばす' $Machine { Get-PowerToysExeCandidate -LocalAppData $null -ProgramFiles 'C:\Program Files' }

# Find-PowerToysExe: 候補を前から見て、最初にあったもの
Test-Case 'user スコープにあればそれ (この PC)' $User { Find-PowerToysExe -Candidates @($User, $Machine) -Exists { param($p) $p -eq $User } }
Test-Case 'machine スコープにだけあればそれ' $Machine { Find-PowerToysExe -Candidates @($User, $Machine) -Exists { param($p) $p -eq $Machine } }
Test-Case '両方にあれば先の user スコープ' $User { Find-PowerToysExe -Candidates @($User, $Machine) -Exists { param($p) $true } }
Test-Case 'どちらにも無ければ空' '' { Find-PowerToysExe -Candidates @($User, $Machine) -Exists { param($p) $false } }

# Get-PowerToysInstallArguments: 入れる winget の引数 (user スコープ、版は名指ししない)
Test-Case 'user スコープで入れる引数' "install --id $Id --exact --source winget --scope user --silent --accept-source-agreements --disable-interactivity --accept-package-agreements" { (Get-PowerToysInstallArguments -PackageId $Id) -join ' ' }

# Get-PowerToysExitCode: 終了コード
Test-Case '入っていれば 0' 0 { Get-PowerToysExitCode -State ([pscustomobject]@{ Exe = $User; Version = '0.100.2.0' }) }
Test-Case '入っていなければ 3' 3 { Get-PowerToysExitCode -State ([pscustomobject]@{ Exe = $null; Version = $null }) }

# Format-PowerToysState: 状態の表の行
$installed = [pscustomobject]@{ Exe = $User; Version = '0.100.2.0' }
$missing = [pscustomobject]@{ Exe = $null; Version = $null }
function Get-Rows { param($State) @(Format-PowerToysState -State $State) }
Test-Case '見出しはパッケージ名' 'PowerToys (winget の Microsoft.PowerToys。版は固定しない)' { (Get-Rows $installed)[0].Text }
Test-Case '入っていれば場所と版の 3 行で、⚠ は無い' '3 0' { $r = Get-Rows $installed; "$($r.Count) $(@($r | Where-Object { $_.Warn }).Count)" }
Test-Case '入っている場所' "  入っている場所 : $User" { (Get-Rows $installed)[1].Text }
Test-Case '入っている版' '  入っている版   : 0.100.2.0' { (Get-Rows $installed)[2].Text }
Test-Case '版が読めなければ不明' '  入っている版   : 不明 (PowerToys.exe の ProductVersion が読めない)' { (Get-Rows ([pscustomobject]@{ Exe = $User; Version = '' }))[2].Text }
Test-Case '入っていなければ 2 行で、⚠ を付ける' '2 1' { $r = Get-Rows $missing; "$($r.Count) $(@($r | Where-Object { $_.Warn }).Count)" }
Test-Case '入っていなければ入れると出す' '⚠ 入っている場所 : 入っていない → user スコープで入れる' { (Get-Rows $missing)[1].Text }

# 本体の入口: Linux の pwsh には %LOCALAPPDATA% も %ProgramFiles% も無いので「入っていない」の 3 になる。
# -Check だけを流す (付けずに流すと winget を探しに行くため)。子の PATH は空にする
# (WSL の PATH には Windows の winget.exe があり、名前が違っても本物を呼ばないように)
Test-Case '入口: -Check は入っていなければ終了コード 3' '3 True' {
    $pwsh = (Get-Process -Id $PID).Path
    $savedPath = $env:PATH
    try {
        $env:PATH = ''
        $out = @(& $pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Install-PowerToys.ps1') -Check 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
    } finally {
        $env:PATH = $savedPath
    }
    "$code $(($out -join "`n") -like '*入っていない*')"
}

# ---------------------------------------------------------------------------
# Invoke-InstallPowerToys の流れ。Windows に触る関数を偽物に差し替えて、打つ winget と、
# 失敗したときの扱いを確かめる。ここより後ろでは本物の関数は使えない
# ---------------------------------------------------------------------------

# Get-Command winget を通すためだけの関数 (呼ばれるのは下の Invoke-Winget)
function winget { }
function Invoke-Winget {
    param([string[]]$Arguments)
    $script:Calls.Add($Arguments[0])
    [pscustomobject]@{ ExitCode = $script:WingetCode; Lines = @() }
}
function Get-PowerToysState { $script:States.Dequeue() }

# 1 回ぶんの流れを走らせ、打った winget・画面の行・終了コードを返す。
# $States は Get-PowerToysState が返す順 (入れる前と、入れた後に読み直したもの)
function Invoke-Flow {
    param([object[]]$States, [switch]$Check, [int]$WingetCode = 0)
    $script:Calls = [System.Collections.Generic.List[string]]::new()
    $script:States = [System.Collections.Generic.Queue[object]]::new()
    foreach ($s in $States) { $script:States.Enqueue($s) }
    $script:WingetCode = $WingetCode
    $out = @(Invoke-InstallPowerToys -Check:$Check 6>&1)
    [pscustomobject]@{
        Calls = ($script:Calls -join ' ')
        Text  = (@($out | Where-Object { $_ -isnot [int] } | ForEach-Object { "$_" }) -join "`n")
        Code  = @($out | Where-Object { $_ -is [int] })[-1]
    }
}

Test-Case '-Check は入っていれば 0 で、winget を打たない' '0 []' { $r = Invoke-Flow -States @($installed) -Check; "$($r.Code) [$($r.Calls)]" }
Test-Case '-Check は入っていなければ 3 で、winget を打たない' '3 []' { $r = Invoke-Flow -States @($missing) -Check; "$($r.Code) [$($r.Calls)]" }
Test-Case '入っていれば何も打たずに 0' '0 []' { $r = Invoke-Flow -States @($installed); "$($r.Code) [$($r.Calls)]" }
Test-Case '入っていなければ install して 0' '0 [install]' { $r = Invoke-Flow -States @($missing, $installed); "$($r.Code) [$($r.Calls)]" }
Test-Case 'install が落ちて入らなければ 1 で、打ち直し方を出す' '1 [install] True' { $r = Invoke-Flow -States @($missing, $missing) -WingetCode 1; "$($r.Code) [$($r.Calls)] $($r.Text -like '*Install-PowerToys を打ち直す*')" }
Test-Case 'winget が無ければ 2' '2 []' {
    Remove-Item -LiteralPath function:winget
    try {
        $r = Invoke-Flow -States @($missing)
    } finally {
        function script:winget { }
    }
    "$($r.Code) [$($r.Calls)]"
}

if ($script:Failures -gt 0) {
    Write-Host "$($script:Failures) 件失敗"
    exit 1
}
Write-Host 'すべて通った'
```

- [ ] **Step 2: BOM を付ける**

```bash
bash -c 'for f in "$@"; do if [[ $(head -c3 "$f" | od -An -tx1 | tr -d " ") != efbbbf ]]; then { printf "\xef\xbb\xbf"; cat "$f"; } >"$f.tmp" && mv "$f.tmp" "$f"; fi; printf "%s: %s\n" "$f" "$(head -c3 "$f" | od -An -tx1)"; done' _ win/powertoys/Install-PowerToys.Tests.ps1
```

Expected: `win/powertoys/Install-PowerToys.Tests.ps1:  ef bb bf`

- [ ] **Step 3: テストが落ちることを確かめる**

Run: `nix shell nixpkgs#powershell -c pwsh -NoProfile -File win/powertoys/Install-PowerToys.Tests.ps1; echo "rc=$?"`
Expected: `The term '…/win/powertoys/Install-PowerToys.ps1' is not recognized as a name of a cmdlet, function, script file, or executable program.` と `rc=1`。

- [ ] **Step 4: スクリプトを書く `win/powertoys/Install-PowerToys.ps1`**

```powershell
<#
.SYNOPSIS
Windows の PowerToys (winget の Microsoft.PowerToys) が入っていなければ、user スコープで入れる。

.DESCRIPTION
dotfiles の win/powertoys/Install-PowerToys.ps1 を %USERPROFILE%\.config\powershell\ へ配り、
PowerShell では dotfiles.ps1 の Install-PowerToys から呼ぶ (win/README.md の「PowerToys を入れる」)。

版は固定しない。PowerToys は自分で新しい版を知らせるので、winget pin も足さない (ADR 017)。
入っているかは、PowerToys.exe が %LOCALAPPDATA%\PowerToys\ (user スコープ) か
%ProgramFiles%\PowerToys\ (machine スコープ) にあるかで見る。入れるときは user スコープの
installer (PowerToysUserSetup-…exe) にするので、管理者は要らない。

BOM 付きの UTF-8 で保存すること (Windows PowerShell 5.1 は BOM の無い UTF-8 を CP932 として読む)。

.PARAMETER Check
入っているかを出すだけで、何も変えない。入っていれば終了コード 0、入っていなければ 3、確かめられなければ 2。

.PARAMETER IfMissing
入っていなければ入れる。入っていれば -Check と同じ (setup --update の bootstrap-windows-powertoys.sh が使う)。
版を固定しないので揃えることが他に無く、付けずに打っても同じことをする。
#>
[CmdletBinding()]
param(
    [switch]$Check,
    [switch]$IfMissing
)

# ---------------------------------------------------------------------------
# 副作用の無い関数 (Install-PowerToys.Tests.ps1 で確かめる)
# ---------------------------------------------------------------------------

# PowerToys.exe の置き場所の候補 (user スコープ、machine スコープの順)。空の値は飛ばす。
# 区切りは \ で組む (Linux の pwsh で流すテストでも同じ文字列になるよう、Join-Path は使わない)
function Get-PowerToysExeCandidate {
    param([string]$LocalAppData, [string]$ProgramFiles)
    foreach ($root in @($LocalAppData, $ProgramFiles)) {
        if ($root) { "$($root.TrimEnd('\'))\PowerToys\PowerToys.exe" }
    }
}

# 候補を前から見て、最初にあったもの。無ければ $null。
# $Exists はファイルがあるかを答える scriptblock (テストでは偽物を渡す)
function Find-PowerToysExe {
    param([string[]]$Candidates, [scriptblock]$Exists)
    foreach ($candidate in $Candidates) {
        if (& $Exists $candidate) { return $candidate }
    }
    $null
}

# 入れる winget の引数。user スコープの installer を選び、版は名指ししない (そのときの最新を入れる)
function Get-PowerToysInstallArguments {
    param([string]$PackageId)
    @('install', '--id', $PackageId, '--exact', '--source', 'winget', '--scope', 'user', '--silent',
        '--accept-source-agreements', '--disable-interactivity', '--accept-package-agreements')
}

# 終了コード。入っていれば 0、入っていなければ 3
function Get-PowerToysExitCode {
    param($State)
    if ($State.Exe) { return 0 }
    3
}

# 状態の表の行 (Text と、直すことがあるかの Warn)。入っていなければ ⚠ を付ける
function Format-PowerToysState {
    param($State)
    [pscustomobject]@{ Text = 'PowerToys (winget の Microsoft.PowerToys。版は固定しない)'; Warn = $false }
    if ($State.Exe) {
        $versionText = if ($State.Version) { $State.Version } else { '不明 (PowerToys.exe の ProductVersion が読めない)' }
        [pscustomobject]@{ Text = "  入っている場所 : $($State.Exe)"; Warn = $false }
        [pscustomobject]@{ Text = "  入っている版   : $versionText"; Warn = $false }
    } else {
        [pscustomobject]@{ Text = '⚠ 入っている場所 : 入っていない → user スコープで入れる'; Warn = $true }
    }
}

# ---------------------------------------------------------------------------
# Windows に触る関数 (実機で -Check と本番を打って確かめる)
# ---------------------------------------------------------------------------

# winget を打ち、出力の行 (進み具合の表示は除く) と終了コードを返す (Install-OpenSSH.ps1 と同じ)
function Invoke-Winget {
    param([string[]]$Arguments)
    # 5.1 では Stop のままだと、外部コマンドの stderr の 1 行目で止まる
    $ErrorActionPreference = 'Continue'
    $lines = & winget @Arguments 2>&1 | ForEach-Object { "$_" } |
        Where-Object { $_ -notmatch '^\s*[-\\|/]?\s*$' -and $_ -notmatch '[█▒]' }
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Lines = @($lines) }
}

# 今の状態を読む (何も変えない。winget も使わない)
function Get-PowerToysState {
    $candidates = @(Get-PowerToysExeCandidate -LocalAppData $env:LOCALAPPDATA -ProgramFiles $env:ProgramFiles)
    $exe = Find-PowerToysExe -Candidates $candidates -Exists { param($p) Test-Path -LiteralPath $p -PathType Leaf }
    $version = $null
    if ($exe) { $version = (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion }
    [pscustomobject]@{ Exe = $exe; Version = $version }
}

# 状態の表を出す。直すことがある行 (⚠) は黄色にする
function Write-PowerToysState {
    param($State)
    foreach ($row in (Format-PowerToysState -State $State)) {
        if ($row.Warn) { Write-Host $row.Text -ForegroundColor Yellow } else { Write-Host $row.Text }
    }
}

function Invoke-InstallPowerToys {
    param([switch]$Check)
    $packageId = 'Microsoft.PowerToys'

    $state = Get-PowerToysState
    Write-PowerToysState -State $state
    $code = Get-PowerToysExitCode -State $state

    # 入っていれば何もしない (-Check でも、付けなくても)。-Check は入っていなくても何も変えない
    if ($code -eq 0) {
        Write-Host '入っている'
        return 0
    }
    if ($Check) {
        Write-Host '⚠️ PowerToys が入っていない → Install-PowerToys で入れる ⚠️' -ForegroundColor Yellow
        return $code
    }

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host 'winget が見つからない。Microsoft Store の「アプリ インストーラー」を入れる'
        return 2
    }
    $arguments = @(Get-PowerToysInstallArguments -PackageId $packageId)
    Write-Host "winget $($arguments -join ' ')"
    $result = Invoke-Winget -Arguments $arguments
    $result.Lines | Select-Object -Last 5 | ForEach-Object { Write-Host "  $_" }
    if ($result.ExitCode -ne 0) {
        Write-Host ('winget が失敗した (終了コード 0x{0:X8})' -f $result.ExitCode)
    }

    # 入ったかを読み直して確かめる
    Write-Host ''
    $after = Get-PowerToysState
    Write-PowerToysState -State $after
    if ((Get-PowerToysExitCode -State $after) -eq 0) {
        Write-Host '入った'
        return 0
    }
    Write-Host '入らなかった。ネットワークを確かめて Install-PowerToys を打ち直す (setup --update でも、もう一度入れにいく)'
    return 1
}

# dot-source されたとき (テスト) は関数だけを読み、本体は走らせない。
# 思わぬ例外は受け止めて終了コード 2 で終える。受け止めないと exit まで届かず、
# -Command から呼んだとき外側の exit $LASTEXITCODE が中の winget の 0 を返して成功に見える。
# -IfMissing は付けなくても同じなので、本体には渡さない (bootstrap が herdr と同じ形で呼ぶために受け取る)
if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest
    try {
        exit (Invoke-InstallPowerToys -Check:$Check)
    } catch {
        Write-Host "エラーで止まった: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace
        exit 2
    }
}
```

- [ ] **Step 5: BOM を付ける**

```bash
bash -c 'for f in "$@"; do if [[ $(head -c3 "$f" | od -An -tx1 | tr -d " ") != efbbbf ]]; then { printf "\xef\xbb\xbf"; cat "$f"; } >"$f.tmp" && mv "$f.tmp" "$f"; fi; printf "%s: %s\n" "$f" "$(head -c3 "$f" | od -An -tx1)"; done' _ win/powertoys/Install-PowerToys.ps1
```

Expected: `win/powertoys/Install-PowerToys.ps1:  ef bb bf`

- [ ] **Step 6: テストが通ることを確かめる**

Run: `nix shell nixpkgs#powershell -c pwsh -NoProfile -File win/powertoys/Install-PowerToys.Tests.ps1 | grep -v '^ok'`
Expected: `すべて通った` の 1 行だけ。

Run: `nix shell nixpkgs#powershell -c pwsh -NoProfile -File win/powertoys/Install-PowerToys.Tests.ps1 | grep -c '^ok'`
Expected: `24`

`win/powertoys/**` は `.gitattributes` で `-text` (改行を変えない) だが、書いたままの LF と BOM で置けばよい。

- [ ] **Step 7: Commit**

```bash
git add win/powertoys/Install-PowerToys.ps1 win/powertoys/Install-PowerToys.Tests.ps1
git commit -F - <<'EOF'
feat(win): PowerToys が無ければ winget の user スコープで入れる Install-PowerToys.ps1 を足す (TKT-143)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01YSF6gCGyvBHzRBtjbB61Fm
EOF
```

---

### Task 3: 2 つのスクリプトを配り、PowerShell の関数から呼べるようにする

**Files:**
- Modify: `win/manifest.toml` (末尾に 2 件)
- Modify: `win/powershell/dotfiles.ps1` (末尾の `Install-Herdr` の後に 2 つの関数)

**Interfaces:**
- Consumes: Task 1・2 のファイル (`win/google-japanese-input/Install-GoogleJapaneseInput.ps1`・`win/powertoys/Install-PowerToys.ps1`。manifest の検証は src があることを見る)
- Produces:
  - Windows 側の置き先 `%USERPROFILE%\.config\powershell\Install-GoogleJapaneseInput.ps1` と `…\Install-PowerToys.ps1`。WSL からは `<windowsHome>/.config/powershell/Install-GoogleJapaneseInput.ps1`・`…/Install-PowerToys.ps1` (Task 4・5 の bootstrap が「配られているか」を見る)
  - PowerShell の関数 `Install-GoogleJapaneseInput` と `Install-PowerToys` (引数は `@args` でスクリプトへそのまま渡す)

- [ ] **Step 1: 足す前の状態を確かめる (落ちることの確かめ)**

Run: `nix/scripts/bootstrap-windows-files.sh --check`
Expected: `win/manifest.toml: OK (7 件)`

Run: `nix shell nixpkgs#powershell -c pwsh -NoProfile -Command '. ./win/powershell/dotfiles.ps1; (Get-Command Install-GoogleJapaneseInput, Install-PowerToys -ErrorAction Stop).Name -join " "'; echo "rc=$?"`
Expected: `Get-Command: The term 'Install-GoogleJapaneseInput' is not recognized as a name of a cmdlet, function, script file, or executable program.` と `rc=1`。

- [ ] **Step 2: `win/manifest.toml` の末尾に 2 件足す**

Edit で、old_string:

```toml
hint = "Keyboard Manager のエディタを開いていたら、閉じて開き直す"
```

new_string:

```toml
hint = "Keyboard Manager のエディタを開いていたら、閉じて開き直す"

[[files]]
src = "google-japanese-input/Install-GoogleJapaneseInput.ps1"
dst = "%USERPROFILE%/.config/powershell/Install-GoogleJapaneseInput.ps1"
hint = "PowerShell で Install-GoogleJapaneseInput -Check を打つと、固定した版との差が分かる (setup --update でも確かめ、入っていなければ入れる。入れる・上げるときは UAC の確認が出る)"

[[files]]
src = "powertoys/Install-PowerToys.ps1"
dst = "%USERPROFILE%/.config/powershell/Install-PowerToys.ps1"
hint = "PowerShell で Install-PowerToys -Check を打つと、入っているかが分かる (setup --update でも確かめ、入っていなければ入れる)"
```

- [ ] **Step 3: `win/powershell/dotfiles.ps1` の末尾に 2 つの関数を足す**

Edit で (ファイルの先頭の BOM には触らない。Write で書き直さない)、old_string:

```powershell
function Install-Herdr { & "$HOME\.config\powershell\Install-Herdr.ps1" @args }
```

new_string:

```powershell
function Install-Herdr { & "$HOME\.config\powershell\Install-Herdr.ps1" @args }

# Windows の Google 日本語入力 (winget の Google.JapaneseIME) を、dotfiles で固定した版に揃える。
# 中身は同じ場所へ配る Install-GoogleJapaneseInput.ps1 (win/README.md の「Google 日本語入力を入れる」)。-Check なら確かめるだけ。
# 入れる・上げるときは Windows に UAC の確認が出る。上げる前に、日本語入力を使っているアプリをできるだけ閉じる。
function Install-GoogleJapaneseInput { & "$HOME\.config\powershell\Install-GoogleJapaneseInput.ps1" @args }

# Windows の PowerToys (winget の Microsoft.PowerToys) が入っていなければ、user スコープで入れる。
# 中身は同じ場所へ配る Install-PowerToys.ps1 (win/README.md の「PowerToys を入れる」)。-Check なら確かめるだけ。
# 版は固定しない (PowerToys が自分で新しい版を知らせる)。
function Install-PowerToys { & "$HOME\.config\powershell\Install-PowerToys.ps1" @args }
```

- [ ] **Step 4: 足した後を確かめる**

Run: `nix/scripts/bootstrap-windows-files.sh --check`
Expected: `win/manifest.toml: OK (9 件)`

Run: `nix shell nixpkgs#powershell -c pwsh -NoProfile -Command '. ./win/powershell/dotfiles.ps1; (Get-Command Install-GoogleJapaneseInput, Install-PowerToys -ErrorAction Stop).Name -join " "'; echo "rc=$?"`
Expected: `Install-GoogleJapaneseInput Install-PowerToys` と `rc=0`。

Run: `head -c3 win/powershell/dotfiles.ps1 | od -An -tx1`
Expected: ` ef bb bf`

- [ ] **Step 5: Commit**

```bash
git add win/manifest.toml win/powershell/dotfiles.ps1
git commit -F - <<'EOF'
feat(win): 2 つのスクリプトを配り、PowerShell の Install-GoogleJapaneseInput と Install-PowerToys から呼べるようにする (TKT-143)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01YSF6gCGyvBHzRBtjbB61Fm
EOF
```

---

### Task 4: Google 日本語入力の版を setup で確かめ、無ければ入れる `bootstrap-windows-google-ime-install.sh` (order 95) を足す

**Files:**
- Create: `nix/tests/bootstrap-windows-google-ime-install.test.sh`
- Create: `nix/scripts/bootstrap-windows-google-ime-install.sh` (mode 100755)
- Modify: `nix/flake.nix` (checks の `bootstrap-windows-powertoys-test` の次の行)

**Interfaces:**
- Consumes: Task 1 の出力の約束 (終了コード 0 / 1 / 3 / 2、見出しの `Google.JapaneseIME`、締めの `⚠️ ` の行、`(下げない)`、`※ ` の行)。Task 3 の置き先 `<windowsHome>/.config/powershell/Install-GoogleJapaneseInput.ps1`
- Produces:
  - `nix/scripts/bootstrap-windows-google-ime-install.sh [--apply]`。ヘッダの説明の 1 行目は setup のメニューに出る。`# order: 95`
  - 終了コード: 知らない引数は 2、`--apply` で揃わなければ 1、ほかは 0
  - flake の check `bootstrap-windows-google-ime-install-test`

- [ ] **Step 1: テストを書く `nix/tests/bootstrap-windows-google-ime-install.test.sh`**

bootstrap-windows-herdr.test.sh と同じ作り。偽の `pwsh.exe` は `-IfMissing` の呼び出しだけ `FAKE_PWSH_OUT2` / `FAKE_PWSH_RC2` を返す。出力の見本は Task 1 のスクリプトが出す表と同じ文字列にしてある。

```bash
#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/scripts/bootstrap-windows-google-ime-install.sh の振る舞いを、使い捨ての HOME と
# 偽の pwsh.exe / wslpath で確かめる。
#
#   bash nix/tests/bootstrap-windows-google-ime-install.test.sh [<script のパス>]
#
# flake の checks (bootstrap-windows-google-ime-install-test) が Nix のサンドボックスで流す。
# CI の `nix flake check` もこれを通る。使うのは bash・jq・coreutils・grep・sed だけ。
#
# ## 確かめること
#
#   - 配らないマシン・Install-GoogleJapaneseInput.ps1 が無いときは pwsh.exe を呼ばずに飛ばす
#   - pwsh.exe が無い・失敗する・こちらの出力を返さないときは、手で打つコマンドを出して exit 0
#   - -Check が 0 なら 1 行だけ。1 なら ⚠ で囲んだ注意・状態・揃えるコマンドを出す (上げはしない)。
#     入っている版の方が新しいときは、揃えるコマンドの代わりに repo の版の上げ方を出す
#   - -Check が 3 (入っていない) なら、UAC の確認が出ると先に出してから -IfMissing で入れる。入ったら
#     一度使ってから流し直すよう出す。入れられない・時間切れなら ⚠ で囲んで知らせる
#   - どれも exit 0。--apply は -Check を付けずに流し、失敗なら exit 1。端末でなければ色を付けない
#   - script に実行ビットがある (setup.sh は -x でない bootstrap を流さずに止まる)
#   - jq が無くても exit 0 (知らない引数の 2 以外で 0 以外を返さない)
#
# ## 本物の pwsh.exe を見せない
#
# WSL では PATH に本物の pwsh.exe と wslpath がある。見えると本物の Windows で winget を
# 呼びうるので、要るコマンドだけを symlink で並べた PATH で流す (bootstrap-windows-herdr.test.sh
# と同じ作り)。偽の pwsh.exe と wslpath の shebang は $BASH から作る (サンドボックスに /usr/bin/env が無い)。

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../scripts/bootstrap-windows-google-ime-install.sh}
work=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-windows-google-ime-install-test.XXXXXX")
trap 'rm -rf "${work}"' EXIT

pass=0
fail=0
ok() {
  pass=$((pass + 1))
  echo "  ok   $1"
}
ng() {
  fail=$((fail + 1))
  echo "  FAIL $1"
  if [[ -n ${2:-} ]]; then
    echo "       ${2//$'\n'/$'\n'       }"
  fi
}

v='3.34.6260.0'

# Install-GoogleJapaneseInput.ps1 -Check の出力 (この PC: x86 の 2.29 で pin が無い)
check_out="Google 日本語入力 (winget の Google.JapaneseIME)
  入っている版    : 2.29.5370.0 (C:\\Program Files (x86)\\Google\\Google Japanese Input)
⚠ 固定した版      : ${v} → 上げる
  winget の最新版 : ${v}
⚠ winget pin      : 無し → 足す
⚠️ 固定した版と揃っていない → Install-GoogleJapaneseInput で揃える (上げるときは UAC の確認が出る) ⚠️"

# Install-GoogleJapaneseInput.ps1 -Check の出力 (揃っている)
synced_out="Google 日本語入力 (winget の Google.JapaneseIME)
  入っている版    : ${v} (C:\\Program Files\\Google\\Google Japanese Input)
  固定した版      : ${v} → そのまま
  winget の最新版 : ${v}
  winget pin      : あり
揃っている"

# Install-GoogleJapaneseInput.ps1 -Check の出力 (入っている版の方が新しい)
newer_out="Google 日本語入力 (winget の Google.JapaneseIME)
  入っている版    : 3.35.0.0 (C:\\Program Files\\Google\\Google Japanese Input)
⚠ 固定した版      : ${v} → 入っている版の方が新しい (下げない)
  winget の最新版 : ${v}
  winget pin      : あり
※ 入っている版の方が新しい (Google 日本語入力が自分で上がった?)。下げずに、Install-GoogleJapaneseInput.ps1 の -Version の既定値を 3.35.0.0 に上げ、bootstrap-windows-google-ime.sh の --dry-run と --import で設定を読み書きできるかを確かめてから commit する
⚠️ 入っている版の方が新しい → 下げずに Install-GoogleJapaneseInput.ps1 の -Version を上げる ⚠️"

# Install-GoogleJapaneseInput.ps1 -Check の出力 (入っていない)
missing_out="Google 日本語入力 (winget の Google.JapaneseIME)
  入っている版    : 入っていない
⚠ 固定した版      : ${v} → 入れる
  winget の最新版 : ${v}
⚠ winget pin      : 無し → 足す
⚠️ Google 日本語入力が入っていない → Install-GoogleJapaneseInput で入れる (UAC の確認が出る) ⚠️"

# Install-GoogleJapaneseInput.ps1 -IfMissing が入れ終えたときの出力
installed_out="Windows のデスクトップに UAC の確認が出る。「はい」を押す
winget install --id Google.JapaneseIME --exact --source winget --silent --accept-source-agreements --disable-interactivity --version ${v} --accept-package-agreements
  Successfully installed
winget pin を足した (winget upgrade --all から外れる)

${synced_out%揃っている}揃った"

# 要るコマンドだけを並べた PATH (pwsh.exe と wslpath は入れない)
sys_bin="${work}/sys-bin"
mkdir -p "${sys_bin}"
for c in env jq grep sed tr cat head tail od mkdir mktemp mv rm dirname basename chmod timeout; do
  if ! p=$(command -v "${c}"); then
    echo "見つからない: ${c}" >&2
    exit 1
  fi
  ln -s "${p}" "${sys_bin}/${c}"
done

# 1 ケースぶんの HOME を作る。
#   $1: 名前、$2: windows-files.json の中身 (空なら作らない。@WIN@ は配り先に置き換える)
#   $3: 1 なら Install-GoogleJapaneseInput.ps1 を配った状態にする
# 配り先 (Windows のホームに見立てる) は <HOME>/win。
new_home() {
  local h="${work}/$1"
  mkdir -p "${h}/.local/state/dotfiles" "${h}/bin" "${h}/win"
  if [[ -n $2 ]]; then
    printf '%s\n' "${2//@WIN@/${h}/win}" >"${h}/.local/state/dotfiles/windows-files.json"
  fi
  if [[ $3 == 1 ]]; then
    mkdir -p "${h}/win/.config/powershell"
    printf '# Install-GoogleJapaneseInput.ps1\n' >"${h}/win/.config/powershell/Install-GoogleJapaneseInput.ps1"
  fi
  # 偽の pwsh.exe。引数を記録し、出力を行ごとに CRLF で出して終わる。
  # -IfMissing の呼び出しは FAKE_PWSH_OUT2 / FAKE_PWSH_RC2、ほかは FAKE_PWSH_OUT / FAKE_PWSH_RC を使う
  {
    printf '#!%s\n' "${BASH}"
    cat <<'EOF'
printf '%s\n' "$*" >>"${HOME}/pwsh-calls"
case "$*" in
  *-IfMissing*)
    out=${FAKE_PWSH_OUT2-}
    rc=${FAKE_PWSH_RC2:-0}
    ;;
  *)
    out=${FAKE_PWSH_OUT-}
    rc=${FAKE_PWSH_RC:-0}
    ;;
esac
if [[ -n ${out} ]]; then
  while IFS= read -r l; do printf '%s\r\n' "${l}"; done <<<"${out}"
fi
exit "${rc}"
EOF
  } >"${h}/bin/pwsh.exe"
  # 偽の wslpath。-w <パス> を C:\fake\<ファイル名> にする
  {
    printf '#!%s\n' "${BASH}"
    cat <<'EOF'
[[ $1 == -w ]] || exit 1
printf 'C:\\fake\\%s\n' "${2##*/}"
EOF
  } >"${h}/bin/wslpath"
  chmod +x "${h}/bin/pwsh.exe" "${h}/bin/wslpath"
  echo "${h}"
}

# $1: HOME、$2: 1 なら偽の pwsh.exe を PATH に置かない、残り: script の引数。
# 環境変数 (FAKE_PWSH_*) は呼び出し側で付ける。
run() {
  local h=$1 nopwsh=$2
  shift 2
  local path="${h}/bin:${sys_bin}"
  if [[ ${nopwsh} == 1 ]]; then
    path="${h}/bin-nopwsh:${sys_bin}"
    mkdir -p "${h}/bin-nopwsh"
    ln -sf "${h}/bin/wslpath" "${h}/bin-nopwsh/wslpath"
  fi
  env HOME="${h}" PATH="${path}" "${BASH}" "${script}" "$@" >"${h}/out" 2>"${h}/err"
  echo $? >"${h}/rc"
}

rc() { cat "$1/rc"; }
outerr() { cat "$1/out" "$1/err"; }
pwsh_called() { [[ -s $1/pwsh-calls ]]; }
calls() { cat "$1/pwsh-calls" 2>/dev/null; }
ncalls() { calls "$1" | grep -c ''; }
warn_lines() { outerr "$1" | grep -c '⚠️'; }

state_on='{"enable":true,"version":1,"windowsHome":"@WIN@"}'
state_off='{"enable":false,"version":1,"windowsHome":null}'

echo "== bootstrap-windows-google-ime-install.sh: ${script}"

# 1. 状態ファイルが無い: 飛ばす
h=$(new_home t1 "" 1)
run "${h}" 0
if [[ $(rc "${h}") == 0 ]] && ! pwsh_called "${h}" && outerr "${h}" | grep -q '飛ばします'; then
  ok "windows-files.json が無ければ pwsh.exe を呼ばずに飛ばす"
else
  ng "状態ファイルが無い" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 2. enable = false: 飛ばす
h=$(new_home t2 "${state_off}" 1)
run "${h}" 0
if [[ $(rc "${h}") == 0 ]] && ! pwsh_called "${h}" && outerr "${h}" | grep -q '配りません'; then
  ok "enable = false なら pwsh.exe を呼ばずに飛ばす"
else
  ng "enable = false" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 3. Install-GoogleJapaneseInput.ps1 が配られていない: 飛ばす
h=$(new_home t3 "${state_on}" 0)
run "${h}" 0
if [[ $(rc "${h}") == 0 ]] && ! pwsh_called "${h}" && outerr "${h}" | grep -q 'まだ配られていません'; then
  ok "Install-GoogleJapaneseInput.ps1 が配られていなければ飛ばす"
else
  ng "Install-GoogleJapaneseInput.ps1 が無い" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 4. pwsh.exe が無い: 手で打つコマンドを出して exit 0
h=$(new_home t4 "${state_on}" 1)
run "${h}" 1
if [[ $(rc "${h}") == 0 ]] && outerr "${h}" | grep -qF 'Install-GoogleJapaneseInput -Check'; then
  ok "pwsh.exe が無ければ手で打つコマンドを出して exit 0"
else
  ng "pwsh.exe が無い" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 5. pwsh.exe が失敗する (interop が落ちている): 手で打つコマンドを出して exit 0
h=$(new_home t5 "${state_on}" 1)
FAKE_PWSH_RC=126 FAKE_PWSH_OUT='' run "${h}" 0
if [[ $(rc "${h}") == 0 ]] && outerr "${h}" | grep -qF 'Install-GoogleJapaneseInput -Check' && outerr "${h}" | grep -q '確かめられませんでした'; then
  ok "pwsh.exe が失敗したら手で打つコマンドを出して exit 0"
else
  ng "pwsh.exe が失敗する" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 6. 揃っている (-Check が 0): 1 行だけで ⚠ は出さない。pwsh.exe は -NoProfile と -Check で、配った場所を渡す
h=$(new_home t6 "${state_on}" 1)
FAKE_PWSH_RC=0 FAKE_PWSH_OUT="${synced_out}" run "${h}" 0
if [[ $(rc "${h}") == 0 && $(warn_lines "${h}") == 0 ]] && outerr "${h}" | grep -q '揃っています' \
  && calls "${h}" | grep -q -- '-NoProfile' && calls "${h}" | grep -q -- '-Check' \
  && calls "${h}" | grep -qF 'C:\fake\Install-GoogleJapaneseInput.ps1'; then
  ok "揃っていれば 1 行だけ出して exit 0 (pwsh.exe は -NoProfile -Check、配った場所を渡す)"
else
  ng "揃っている" "rc=$(rc "${h}") calls=$(calls "${h}") $(outerr "${h}")"
fi

# 6b. スクリプトが exit まで届かずに終わっても成功扱いにしない: 呼ぶ前に $LASTEXITCODE を 2 にしておく
# shellcheck disable=SC2016 # PowerShell の $global:… を文字のまま探す
if calls "${h}" | grep -qF '$global:LASTEXITCODE = 2; &'; then
  ok "pwsh.exe には、スクリプトを呼ぶ前に \$LASTEXITCODE を 2 にするコマンドを渡す"
else
  ng "\$LASTEXITCODE を先に 2 にしていない" "calls=$(calls "${h}")"
fi

# 7. 差がある (-Check が 1): ⚠ で上下を囲み、状態と揃えるコマンドを出す。上げはしない
h=$(new_home t7 "${state_on}" 1)
FAKE_PWSH_RC=1 FAKE_PWSH_OUT="${check_out}" run "${h}" 0
if [[ $(rc "${h}") == 0 && $(warn_lines "${h}") -ge 2 ]] && outerr "${h}" | grep -q '揃っていません' \
  && outerr "${h}" | grep -qF "⚠ 固定した版      : ${v} → 上げる" && outerr "${h}" | grep -qF '2.29.5370.0' \
  && outerr "${h}" | grep -qF -- 'bootstrap-windows-google-ime-install.sh --apply' \
  && outerr "${h}" | grep -qF 'PowerShell: Install-GoogleJapaneseInput' && outerr "${h}" | grep -qF 'UAC' \
  && [[ $(ncalls "${h}") == 1 ]]; then
  ok "差があれば ⚠ で囲んだ注意と状態と揃えるコマンドを出して exit 0 (上げはしない)"
else
  ng "差がある" "rc=$(rc "${h}") warn_lines=$(warn_lines "${h}") calls=$(calls "${h}") $(outerr "${h}")"
fi
if ! outerr "${h}" | grep -qF '揃っていない → Install-GoogleJapaneseInput'; then
  ok "PowerShell の締めの 1 行は、枠の揃えるコマンドと重なるので出さない"
else
  ng "締めの 1 行が重なっている" "$(outerr "${h}")"
fi
if ! outerr "${h}" | grep -q $'\e\['; then
  ok "端末でなければ色 (エスケープ) を付けない"
else
  ng "端末でないのに色が付いている" "$(outerr "${h}" | od -c | head -5)"
fi
if ! outerr "${h}" | grep -q $'\r'; then
  ok "pwsh.exe の CRLF は落として出す"
else
  ng "CR が残っている" "$(outerr "${h}" | od -c | head -5)"
fi

# 8. 入っている版の方が新しい (-Check が 1): 枠に入れるが、揃えるコマンドではなく repo の版の上げ方を出す
h=$(new_home t8 "${state_on}" 1)
FAKE_PWSH_RC=1 FAKE_PWSH_OUT="${newer_out}" run "${h}" 0
if [[ $(rc "${h}") == 0 && $(warn_lines "${h}") -ge 2 && $(ncalls "${h}") == 1 ]] && outerr "${h}" | grep -q '下げはしません' \
  && outerr "${h}" | grep -qF '※ 入っている版の方が新しい' && ! outerr "${h}" | grep -qF -- '--apply'; then
  ok "入っている版の方が新しければ、揃えるコマンドの代わりに repo の版の上げ方を出す"
else
  ng "入っている版の方が新しい" "rc=$(rc "${h}") warn_lines=$(warn_lines "${h}") $(outerr "${h}")"
fi

# 9. -Check が 1 でも、こちらの出力が無い (スクリプトが壊れている等): 差とは扱わず、手で打つコマンドを出す
h=$(new_home t9 "${state_on}" 1)
FAKE_PWSH_RC=1 FAKE_PWSH_OUT='The term is not recognized as a name of a cmdlet' run "${h}" 0
if [[ $(rc "${h}") == 0 && $(warn_lines "${h}") == 0 ]] && outerr "${h}" | grep -q '確かめられませんでした' \
  && outerr "${h}" | grep -qF 'Install-GoogleJapaneseInput -Check'; then
  ok "-Check の出力が来なければ差とは扱わず、手で打つコマンドを出して exit 0"
else
  ng "出力が来ない" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 10. 入っていない (-Check が 3): UAC の確認が出ると先に出してから -IfMissing で入れる。入ったら ⚠ は出さず、
#     一度使ってから流し直すよう出す
h=$(new_home t10 "${state_on}" 1)
FAKE_PWSH_RC=3 FAKE_PWSH_OUT="${missing_out}" FAKE_PWSH_RC2=0 FAKE_PWSH_OUT2="${installed_out}" run "${h}" 0
if [[ $(rc "${h}") == 0 && $(warn_lines "${h}") == 0 && $(ncalls "${h}") == 2 ]] && outerr "${h}" | grep -q 'UAC の確認が出たら' \
  && outerr "${h}" | grep -q '入れました' && outerr "${h}" | grep -q '一度何か打ってから、setup --update を流し直して' \
  && calls "${h}" | tail -n 1 | grep -q -- '-IfMissing' && ! calls "${h}" | tail -n 1 | grep -q -- '-Check'; then
  ok "入っていなければ UAC が出ると出してから -IfMissing で入れ、一度使ってから流し直すよう出して exit 0"
else
  ng "入っていない → 入れる" "rc=$(rc "${h}") calls=$(calls "${h}") $(outerr "${h}")"
fi

# 11. 入っていないので入れようとしたが失敗 (UAC で断った など): ⚠ で囲んで知らせる。setup は止めない
h=$(new_home t11 "${state_on}" 1)
FAKE_PWSH_RC=3 FAKE_PWSH_OUT="${missing_out}" FAKE_PWSH_RC2=1 FAKE_PWSH_OUT2='winget が失敗した (終了コード 0x8A150011)。UAC で「いいえ」を押したなら、Install-GoogleJapaneseInput を打ち直す' run "${h}" 0
if [[ $(rc "${h}") == 0 && $(warn_lines "${h}") -ge 2 ]] && outerr "${h}" | grep -q '入れられませんでした (終了コード 1)' \
  && outerr "${h}" | grep -qF '0x8A150011' && outerr "${h}" | grep -qF -- 'bootstrap-windows-google-ime-install.sh --apply'; then
  ok "入れられなければ ⚠ で囲んで知らせて exit 0"
else
  ng "入れられない" "rc=$(rc "${h}") warn_lines=$(warn_lines "${h}") $(outerr "${h}")"
fi

# 12. UAC を押さないまま 600 秒たった (timeout の 124): 時間切れと出して ⚠ で囲む。setup は止めない
h=$(new_home t12 "${state_on}" 1)
FAKE_PWSH_RC=3 FAKE_PWSH_OUT="${missing_out}" FAKE_PWSH_RC2=124 FAKE_PWSH_OUT2='' run "${h}" 0
if [[ $(rc "${h}") == 0 && $(warn_lines "${h}") -ge 2 ]] && outerr "${h}" | grep -q '600 秒待っても終わらない' \
  && outerr "${h}" | grep -qF 'PowerShell: Install-GoogleJapaneseInput'; then
  ok "UAC を押さないまま時間切れになったら ⚠ で囲んで知らせて exit 0"
else
  ng "時間切れ" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 13. -Check が 3 でも、こちらの出力が無い: 入れには行かず、手で打つコマンドを出す
h=$(new_home t13 "${state_on}" 1)
FAKE_PWSH_RC=3 FAKE_PWSH_OUT='Exec format error' run "${h}" 0
if [[ $(rc "${h}") == 0 && $(ncalls "${h}") == 1 ]] && outerr "${h}" | grep -q '確かめられませんでした' \
  && outerr "${h}" | grep -qF 'Install-GoogleJapaneseInput -Check'; then
  ok "-Check が 3 でも出力が来なければ、入れずに手で打つコマンドを出す"
else
  ng "3 だが出力が来ない" "rc=$(rc "${h}") calls=$(calls "${h}") $(outerr "${h}")"
fi

# 14. -Check が 2 (winget が無い・例外): 手で打つコマンドを出して exit 0
h=$(new_home t14 "${state_on}" 1)
FAKE_PWSH_RC=2 FAKE_PWSH_OUT='winget が見つからない。Microsoft Store の「アプリ インストーラー」を入れる' run "${h}" 0
if [[ $(rc "${h}") == 0 && $(ncalls "${h}") == 1 ]] && outerr "${h}" | grep -q '確かめられませんでした (終了コード 2' \
  && outerr "${h}" | grep -qF 'アプリ インストーラー'; then
  ok "-Check が 2 (winget が無い) なら、スクリプトの出力と手で打つコマンドを出して exit 0"
else
  ng "-Check が 2" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 15. --apply: -Check も -IfMissing も付けずに流す。成功なら exit 0
h=$(new_home t15 "${state_on}" 1)
FAKE_PWSH_RC=0 FAKE_PWSH_OUT="揃った" run "${h}" 0 --apply
if [[ $(rc "${h}") == 0 ]] && pwsh_called "${h}" && ! calls "${h}" | grep -q -- '-Check' \
  && ! calls "${h}" | grep -q -- '-IfMissing' && calls "${h}" | grep -qF 'C:\fake\Install-GoogleJapaneseInput.ps1' \
  && outerr "${h}" | grep -q '揃いました'; then
  ok "--apply は -Check を付けずに流し、成功なら exit 0"
else
  ng "--apply 成功" "rc=$(rc "${h}") calls=$(calls "${h}") $(outerr "${h}")"
fi

# 16. --apply が失敗: exit 1 (手で流すものなので失敗を返す)
h=$(new_home t16 "${state_on}" 1)
FAKE_PWSH_RC=1 FAKE_PWSH_OUT="入っている版 (3.35.0.0) の方が固定した版 (${v}) より新しいので、下げない" run "${h}" 0 --apply
if [[ $(rc "${h}") == 1 ]] && outerr "${h}" | grep -q '揃いませんでした'; then
  ok "--apply が失敗したら exit 1"
else
  ng "--apply 失敗" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 17. 揃っているが winget に新しい版がある: 1 行に加えて ※ の行も出す (ずれではないので ⚠ にはしない)
h=$(new_home t17 "${state_on}" 1)
newer_listed='※ winget に固定した版より新しい 3.35.6300.0 がある。上げるなら Install-GoogleJapaneseInput.ps1 の -Version の既定値を変える'
FAKE_PWSH_RC=0 FAKE_PWSH_OUT="${synced_out}"$'\n'"${newer_listed}" run "${h}" 0
if [[ $(rc "${h}") == 0 && $(warn_lines "${h}") == 0 ]] && outerr "${h}" | grep -q '揃っています' \
  && outerr "${h}" | grep -qF "${newer_listed}"; then
  ok "揃っていても、winget に新しい版があれば ※ の行を出す"
else
  ng "新しい版がある" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 18. pwsh.exe の出力に色のエスケープが混ざっていても、取り除いてから枠に入れる
h=$(new_home t18 "${state_on}" 1)
FAKE_PWSH_RC=1 FAKE_PWSH_OUT='Google 日本語入力 (winget の Google.JapaneseIME)'$'\n\e[33m⚠ winget pin      : 無し → 足す\e[0m' run "${h}" 0
if [[ $(rc "${h}") == 0 ]] && ! outerr "${h}" | grep -q $'\e' && outerr "${h}" | grep -qF '⚠ winget pin      : 無し → 足す'; then
  ok "pwsh.exe の色のエスケープは取り除いて出す"
else
  ng "エスケープが残る" "rc=$(rc "${h}") $(outerr "${h}" | od -c | head -8)"
fi

# 19. 知らない引数: exit 2
h=$(new_home t19 "${state_on}" 1)
run "${h}" 0 --bogus
if [[ $(rc "${h}") == 2 ]] && ! pwsh_called "${h}"; then
  ok "知らない引数は exit 2"
else
  ng "知らない引数" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 20. script に実行ビットがある (setup.sh は実行ビットの無い bootstrap を「実行できません」で止める)
if [[ -x ${script} ]]; then
  ok "script に実行ビットがある (setup.sh は実行できない bootstrap で止まる)"
else
  ng "script に実行ビットが無い" "$(ls -l "${script}")"
fi

# 21. jq が無い: setup を止めないよう exit 0 で飛ばす (pwsh.exe は呼ばない)
nojq_bin="${work}/sys-bin-nojq"
mkdir -p "${nojq_bin}"
for c in "${sys_bin}"/*; do
  if [[ ${c##*/} != jq ]]; then
    ln -s "${c}" "${nojq_bin}/${c##*/}"
  fi
done
h=$(new_home t21 "${state_on}" 1)
env HOME="${h}" PATH="${h}/bin:${nojq_bin}" "${BASH}" "${script}" >"${h}/out" 2>"${h}/err"
echo $? >"${h}/rc"
if [[ $(rc "${h}") == 0 ]] && ! pwsh_called "${h}" && outerr "${h}" | grep -q 'jq が見つかりません'; then
  ok "jq が無くても exit 0 で飛ばす (setup を止めない)"
else
  ng "jq が無い" "rc=$(rc "${h}") $(outerr "${h}")"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
```

- [ ] **Step 2: テストが落ちることを確かめる**

Run: `bash nix/tests/bootstrap-windows-google-ime-install.test.sh | tail -1`
Expected: `== 3 passed, 22 failed` (script が無いので、出力に色・CR・PowerShell の締めの行が「無い」ことを見る 3 件だけが通る)。

- [ ] **Step 3: script を書く `nix/scripts/bootstrap-windows-google-ime-install.sh`**

```bash
#!/usr/bin/env bash
# shellcheck shell=bash
#
# Windows の Google 日本語入力 (winget の Google.JapaneseIME) が、dotfiles で固定した版に揃っているかを確かめる。
# 冪等。`setup.sh --update` でも毎回走る。入っていなければ winget で入れ (Windows に UAC の確認が出る)、
# 入っていて揃っていなければ ⚠ で囲んで知らせる (上げはしない)。
#
# order: 95
#
# ^ setup.sh が読む実行順。bootstrap-windows-files.sh (order: 90) が Install-GoogleJapaneseInput.ps1 を
#   置いた後、設定と辞書を置く bootstrap-windows-google-ime.sh (order: 98) より前に走らせる。
#   bootstrap-windows-powershell-profile.sh も 95 で、同じ値は辞書順なのでこちらが先に走る
#   (どちらも相手を使わない)。仕組みは nix/README.md「bootstrap の実行順」。
#
# ## 何のために
#
# Windows の Google 日本語入力は winget の Google.JapaneseIME で入れ、版は
# win/google-japanese-input/Install-GoogleJapaneseInput.ps1 の -Version の既定値で固定する
# (win/README.md の「Google 日本語入力を入れる」、docs/adr/017_win_apps_winget_*)。
# 設定 (bootstrap-windows-google-ime.sh が置く) を読み書きできると確かめた版に留めるため、
# 自分で上がったときも気付けるよう、setup のたびに差を確かめて見せる。新しいマシンでは入れるところまでする。
#
# ## 何をするか
#
# 1. ~/.local/state/dotfiles/windows-files.json (home-manager が置く) を読み、配らない
#    マシンなら飛ばす。<windowsHome>/.config/powershell/Install-GoogleJapaneseInput.ps1 が無いときも飛ばす
# 2. pwsh.exe で Install-GoogleJapaneseInput.ps1 -Check を流す (何も変えない)。
#    WSL の interop を通るので、落ちていたら手で打つコマンドを出して飛ばす (exit 0)
# 3. 終了コード 0 なら 1 行だけ出す。1 なら ⚠ で囲んだ注意と状態の表と揃えるコマンドを出す。
#    3 (入っていない) なら Install-GoogleJapaneseInput.ps1 -IfMissing で入れる。machine スコープの MSI
#    なので Windows に UAC の確認が出る (その場にいて押せるはずの、新しいマシンで起きる)。どれも exit 0
#
# 上げる (入れ替える) のは setup からはしない。日本語入力は全部のアプリに読み込まれていて、入れ替えると
# アプリや Windows の再起動が要ることがあるため。--apply を付けて手で流すと、-Check を付けずに流して揃える
# (bootstrap-windows-openssh.sh と同じ。差があれば UAC の確認が出る)。

set -eu -o pipefail

usage() {
  cat <<'EOS'
Windows の Google 日本語入力 (winget の Google.JapaneseIME) が、dotfiles で固定した版に揃っているかを確かめる。

使い方:
  bootstrap-windows-google-ime-install.sh            確かめる (入っていなければ入れる。差があれば ⚠ で知らせる)
  bootstrap-windows-google-ime-install.sh --apply    揃える (上げるときは Windows に UAC の確認が出る)
EOS
}

apply=0
for arg in "$@"; do
  case ${arg} in
    --apply) apply=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "不明な引数です: ${arg}" >&2
      usage >&2
      exit 2
      ;;
  esac
done

script_dir=$(
  cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null || exit
  pwd -P
)
state_file="${HOME}/.local/state/dotfiles/windows-files.json"

# ⚠ の枠を色付きで出すか。端末のときだけ (パイプや NO_COLOR では付けない)
if [[ -t 2 && -z ${NO_COLOR-} ]]; then
  c_warn=$'\e[1;33m'
  c_reset=$'\e[0m'
else
  c_warn=""
  c_reset=""
fi

# 自動で確かめられないときに、同じことを手で確かめるコマンドを出す
manual() {
  echo "   Windows の PowerShell で次を打つと、同じことを確かめられます:" >&2
  echo "     Install-GoogleJapaneseInput -Check" >&2
}

# jq が無くても setup は止めない (この手順は知らない引数の 2 以外で 0 以外を返さない)
if ! command -v jq &>/dev/null; then
  echo "jq が見つかりません。先に home-manager switch を実行してください。この手順は飛ばします。" >&2
  exit 0
fi

if [[ ! -r ${state_file} ]]; then
  echo "配り先の設定がありません (${state_file})。この手順は飛ばします。"
  exit 0
fi
if [[ $(jq -r '.enable' "${state_file}") != true ]]; then
  echo "このマシンは Windows 側へ配りません (dotfiles.wsl.windowsFiles.enable = false)。"
  exit 0
fi
windows_home=$(jq -r '.windowsHome // ""' "${state_file}")
deployed="${windows_home}/.config/powershell/Install-GoogleJapaneseInput.ps1"
if [[ -z ${windows_home} || ! -f ${deployed} ]]; then
  echo "Install-GoogleJapaneseInput.ps1 がまだ配られていません (${deployed})。この手順は飛ばします。"
  exit 0
fi

if ! command -v pwsh.exe &>/dev/null; then
  echo "!! pwsh.exe が見つかりません (PowerShell 7 が無いか、WSL の PATH に Windows の PATH が入っていない)。" >&2
  manual
  exit 0
fi
if ! win_script=$(wslpath -w "${deployed}" 2>/dev/null) || [[ -z ${win_script} ]]; then
  echo "!! Install-GoogleJapaneseInput.ps1 の場所を Windows のパスに直せませんでした: ${deployed}" >&2
  manual
  exit 0
fi

# pwsh.exe に渡すコマンド。$1 はスクリプトに渡す引数 (" -Check" など。空なら揃える)。
# 出力は UTF-8 にする (日本語と ⚠ が化けないよう)。パスは '' で囲む (中の ' は '' に)。
# 呼ぶ前に $LASTEXITCODE を 2 にしておく。スクリプトが exit まで届かずに終わる (構文の誤りなど) と、
# exit $LASTEXITCODE が中で打った外部コマンドの値 (winget の 0 など) を返し、成功に見えてしまうため。
quoted=${win_script//\'/\'\'}
pwsh_command() {
  echo "[Console]::OutputEncoding = [Text.Encoding]::UTF8; \$global:LASTEXITCODE = 2; & '${quoted}'$1; exit \$LASTEXITCODE"
}

# CRLF と、PowerShell が付けうる色のエスケープを落とす (枠の色はこちらで付ける)
esc=$'\e'
clean() {
  tr -d '\r' | sed "s/${esc}\[[0-9;]*[A-Za-z]//g"
}

# ⚠ で囲んだ注意を出す。$1: 見出し、$2: 枠に入れる出力 (状態の表など)
rule="⚠️ ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ ⚠️"
warn_frame() {
  {
    printf '%s%s%s\n' "${c_warn}" "${rule}" "${c_reset}"
    printf '%s⚠️  %s%s\n' "${c_warn}" "$1" "${c_reset}"
    printf '%s%s%s\n' "${c_warn}" "${rule}" "${c_reset}"
    # PowerShell の締めの 1 行 (⚠️ … → Install-GoogleJapaneseInput …) は、下の揃えるコマンドと重なるので落とす
    printf '%s\n' "$2" | grep -v '^⚠️ ' | sed 's/^/    /' || true
    if grep -qF '(下げない)' <<<"$2"; then
      # 入っている版の方が新しい: 揃えるコマンドを打っても下げないので、repo の版の上げ方だけを出す
      printf '%s⚠️  入っている版の方が新しいので、下げはしません。上の ※ のとおり、repo の版 (Install-GoogleJapaneseInput.ps1 の -Version) を上げてください%s\n' "${c_warn}" "${c_reset}"
    else
      printf '%s⚠️  揃えるには次のどちらかを打つ (入れる・上げるときは Windows に UAC の確認が出ます。上げる前に、日本語入力を使っているアプリをできるだけ閉じる):%s\n' "${c_warn}" "${c_reset}"
      printf '%s⚠️    WSL:        %s/bootstrap-windows-google-ime-install.sh --apply%s\n' "${c_warn}" "${script_dir}" "${c_reset}"
      printf '%s⚠️    PowerShell: Install-GoogleJapaneseInput%s\n' "${c_warn}" "${c_reset}"
    fi
    printf '%s%s%s\n' "${c_warn}" "${rule}" "${c_reset}"
  } >&2
}

if ((apply)); then
  # 手で流す前提なので、進み具合をそのまま見せる (UAC を押すまで待つので timeout は付けない)
  echo "+ pwsh.exe -NoProfile -ExecutionPolicy Bypass -Command \"& '${win_script}'\""
  rc=0
  pwsh.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$(pwsh_command "")" </dev/null | clean || rc=$?
  if ((rc == 0)); then
    echo "揃いました。"
    exit 0
  fi
  echo "!! 揃いませんでした (終了コード ${rc})。上の出力を確かめてください。" >&2
  exit 1
fi

# WSL の interop を通る。落ちていると Exec format error などで失敗する。
# winget show (ネットワーク) を挟むので、少し長めに待つ。
rc=0
out=$(timeout 120 pwsh.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$(pwsh_command " -Check")" </dev/null 2>&1) || rc=$?
out=$(printf '%s\n' "${out}" | clean)

# 差がある・入っていないときの出力には、状態の表の見出し (パッケージ名) が必ず入る。
# 終了コードが 1 や 3 でも見出しが無ければ、スクリプトが動いていない (差とは扱わない)。
header=0
if grep -qF 'Google.JapaneseIME' <<<"${out}"; then
  header=1
fi

if ((rc == 0)); then
  echo "Windows の Google 日本語入力は、dotfiles で固定した版に揃っています。"
  # winget に新しい版がある、などの ※ の行は、揃っていても見せる (ずれではないので枠には入れない)
  grep '^※' <<<"${out}" | sed 's/^/  /' || true
  exit 0
fi
if ((rc == 1 && header)); then
  warn_frame "Windows の Google 日本語入力が、dotfiles で固定した版と揃っていません" "${out}"
  exit 0
fi
if ((rc == 3 && header)); then
  echo "Windows に Google 日本語入力が入っていないので、winget で固定した版を入れます (Install-GoogleJapaneseInput.ps1 -IfMissing)。"
  echo "Windows のデスクトップに UAC の確認が出たら「はい」を押してください (600 秒まで待ちます)。"
  # MSI のダウンロードと、UAC を押すのを待つので長めに待つ
  rc=0
  out=$(timeout 600 pwsh.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$(pwsh_command " -IfMissing")" </dev/null 2>&1) || rc=$?
  out=$(printf '%s\n' "${out}" | clean)
  if ((rc == 0)); then
    printf '%s\n' "${out}" | sed 's/^/  /'
    echo "Windows に Google 日本語入力を入れました。"
    echo "Google 日本語入力で一度何か打ってから、setup --update を流し直してください (bootstrap-windows-google-ime.sh が設定と辞書を置きます)。"
    exit 0
  fi
  if ((rc == 124)); then
    warn_frame "Windows に Google 日本語入力を入れられませんでした (600 秒待っても終わらない。UAC の確認が出たままかもしれません)" "${out}"
    exit 0
  fi
  warn_frame "Windows に Google 日本語入力を入れられませんでした (終了コード ${rc})" "${out}"
  exit 0
fi
echo "!! pwsh.exe で Windows の Google 日本語入力を確かめられませんでした (終了コード ${rc}。WSL の interop が落ちているかもしれません):" >&2
if [[ -n ${out} ]]; then
  printf '%s\n' "${out}" | sed 's/^/   /' >&2
fi
manual
exit 0
```

- [ ] **Step 4: 実行ビットを付ける**

Run: `chmod +x nix/scripts/bootstrap-windows-google-ime-install.sh && ls -l nix/scripts/bootstrap-windows-google-ime-install.sh`
Expected: `-rwxr-xr-x …`

- [ ] **Step 5: テストが通ることを確かめる**

Run: `bash nix/tests/bootstrap-windows-google-ime-install.test.sh | tail -1`
Expected: `== 25 passed, 0 failed`

- [ ] **Step 6: flake の checks に載せる**

`nix/flake.nix` を Edit で、old_string:

```nix
          bootstrap-windows-powertoys-test = scriptTest "bootstrap-windows-powertoys" ./scripts/bootstrap-windows-powertoys.sh;
```

new_string:

```nix
          bootstrap-windows-powertoys-test = scriptTest "bootstrap-windows-powertoys" ./scripts/bootstrap-windows-powertoys.sh;
          bootstrap-windows-google-ime-install-test = scriptTest "bootstrap-windows-google-ime-install" ./scripts/bootstrap-windows-google-ime-install.sh;
```

- [ ] **Step 7: Nix のサンドボックスで流す**

新しいファイルは flake から見えるように先に `git add` する。

Run: `git add nix/scripts/bootstrap-windows-google-ime-install.sh nix/tests/bootstrap-windows-google-ime-install.test.sh nix/flake.nix && git ls-files -s nix/scripts/bootstrap-windows-google-ime-install.sh | cut -c1-6`
Expected: `100755`

Run: `nix build --no-link -L './nix#checks.x86_64-linux.bootstrap-windows-google-ime-install-test' 2>&1 | grep -E '== [0-9]|FAIL'`
Expected: `bootstrap-windows-google-ime-install-test> == 25 passed, 0 failed` (FAIL の行は無い)

- [ ] **Step 8: 静的な確かめと、setup のメニューに並ぶ順**

Run: `nix develop ./nix --command bash -c 'shfmt -d nix/scripts/bootstrap-windows-google-ime-install.sh nix/tests/bootstrap-windows-google-ime-install.test.sh && shellcheck nix/scripts/bootstrap-windows-google-ime-install.sh nix/tests/bootstrap-windows-google-ime-install.test.sh && nixfmt --check nix/flake.nix && echo LINT_OK'`
Expected: `LINT_OK`

Run: `nix/scripts/setup.sh --list | grep -o 'bootstrap-windows-[a-z-]*' | uniq`
Expected (この順):

```text
bootstrap-windows-files
bootstrap-windows-powertoys
bootstrap-windows-google-ime-install
bootstrap-windows-powershell-profile
bootstrap-windows-openssh
bootstrap-windows-herdr
bootstrap-windows-google-ime
```

- [ ] **Step 9: Commit**

```bash
git add nix/scripts/bootstrap-windows-google-ime-install.sh nix/tests/bootstrap-windows-google-ime-install.test.sh nix/flake.nix
git commit -F - <<'EOF'
feat(nix): Google 日本語入力の版を setup で確かめ、無ければ入れる bootstrap-windows-google-ime-install.sh を足す (TKT-143)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01YSF6gCGyvBHzRBtjbB61Fm
EOF
```

---

### Task 5: `bootstrap-windows-powertoys.sh` (order 91) で、読み直させる前に PowerToys が無ければ入れる

**Files:**
- Modify: `nix/tests/bootstrap-windows-powertoys.test.sh` (全体を差し替える。今のテスト 1〜9 はそのまま中に入っている)
- Modify: `nix/scripts/bootstrap-windows-powertoys.sh` (全体を差し替える。今の読み直しの部分はそのまま中に入っている。mode 100755 のまま)

**Interfaces:**
- Consumes: Task 2 の出力の約束 (`-Check` の終了コード 0 / 3 / 2、見出しの `Microsoft.PowerToys`、締めの `⚠️ ` の行、`-IfMissing` の 0 / 1 / 2)。Task 3 の置き先 `<windowsHome>/.config/powershell/Install-PowerToys.ps1`
- Produces: 今までの 91 の振る舞いに加えて、`default.json` があるか・読み直し済みかによらず、毎回 `Install-PowerToys.ps1 -Check` を流し、3 なら `-IfMissing` で入れる。終了コードは知らない引数の 2 以外は 0

- [ ] **Step 1: テストを差し替える `nix/tests/bootstrap-windows-powertoys.test.sh`**

`new_home` に 4 つ目の引数 (Install-PowerToys.ps1 を配るか) を足し、偽の `pwsh.exe` と `wslpath` を置く。`run` の 2 つ目の引数に 2 (`pwsh.exe` だけ置かない) を足す。テスト 1〜9 は今のまま (Install-PowerToys.ps1 を配らないので pwsh.exe は呼ばれない)。

```bash
#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/scripts/bootstrap-windows-powertoys.sh の振る舞いを、使い捨ての HOME と
# 偽の powershell.exe / pwsh.exe / wslpath で確かめる。
#
#   bash nix/tests/bootstrap-windows-powertoys.test.sh [<script のパス>]
#
# flake の checks (bootstrap-windows-powertoys-test) が Nix のサンドボックスで流す。
# 使うのは bash・jq・coreutils・grep・sed だけ。
#
# ## 確かめること
#
#   - 配らないマシン・default.json が無いときは powershell.exe を呼ばずに飛ばす
#   - 送れたら記録し、同じ default.json では呼ばない。変われば呼ぶ。--force なら変わらなくても呼ぶ
#   - PowerToys が動いていない (absent) ときも記録する。interop が使えない・出力がおかしいときは
#     手で読み直す方法を出し、記録しない。どれも exit 0
#   - 読み直させる前に Install-PowerToys.ps1 -Check を流し、3 (入っていない) なら -IfMissing で入れる。
#     入っていれば入れない。スクリプトが無い・pwsh.exe が無い・失敗する・入れられないときも、
#     知らせて読み直しへ進む (exit 0)。default.json が無くても、読み直し済みでも確かめる
#   - script に実行ビットがある (setup.sh は -x でない bootstrap を流さずに止まる)
#
# 本物の powershell.exe と pwsh.exe を見せないよう、要るコマンドだけを symlink で並べた PATH で流す。
# 偽のコマンドの shebang は $BASH から作る (サンドボックスに /usr/bin/env が無い)。

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../scripts/bootstrap-windows-powertoys.sh}
work=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-windows-powertoys-test.XXXXXX")
trap 'rm -rf "${work}"' EXIT

pass=0
fail=0
ok() {
  pass=$((pass + 1))
  echo "  ok   $1"
}
ng() {
  fail=$((fail + 1))
  echo "  FAIL $1"
  if [[ -n ${2:-} ]]; then
    echo "       ${2//$'\n'/$'\n'       }"
  fi
}

# Install-PowerToys.ps1 -Check の出力 (入っている / 入っていない)
installed_out='PowerToys (winget の Microsoft.PowerToys。版は固定しない)
  入っている場所 : C:\Users\u\AppData\Local\PowerToys\PowerToys.exe
  入っている版   : 0.100.2.0
入っている'
missing_out='PowerToys (winget の Microsoft.PowerToys。版は固定しない)
⚠ 入っている場所 : 入っていない → user スコープで入れる
⚠️ PowerToys が入っていない → Install-PowerToys で入れる ⚠️'
# Install-PowerToys.ps1 -IfMissing が入れ終えたときの出力
added_out="winget install --id Microsoft.PowerToys --exact --source winget --scope user --silent --accept-source-agreements --disable-interactivity --accept-package-agreements
  Successfully installed

${installed_out%入っている}入った"

sys_bin="${work}/sys-bin"
mkdir -p "${sys_bin}"
for c in env jq grep sed tr cat head tail cut mkdir dirname sha256sum timeout od; do
  if ! p=$(command -v "${c}"); then
    echo "見つからない: ${c}" >&2
    exit 1
  fi
  ln -s "${p}" "${sys_bin}/${c}"
done

# $1: 名前、$2: windows-files.json の中身 (空なら作らない)、$3: 1 なら default.json を置く、
# $4: 1 なら Install-PowerToys.ps1 を配った状態にする (省略は 0)
new_home() {
  local h="${work}/$1"
  mkdir -p "${h}/.local/state/dotfiles" "${h}/bin" "${h}/win"
  if [[ -n $2 ]]; then
    printf '%s\n' "${2//@WIN@/${h}/win}" >"${h}/.local/state/dotfiles/windows-files.json"
  fi
  if [[ $3 == 1 ]]; then
    mkdir -p "${h}/win/AppData/Local/Microsoft/PowerToys/Keyboard Manager"
    printf '{"remapKeys":{"inProcess":[{"originalKeys":"20","newRemapKeys":"124"}]}}' \
      >"${h}/win/AppData/Local/Microsoft/PowerToys/Keyboard Manager/default.json"
  fi
  if [[ ${4:-0} == 1 ]]; then
    mkdir -p "${h}/win/.config/powershell"
    printf '# Install-PowerToys.ps1\n' >"${h}/win/.config/powershell/Install-PowerToys.ps1"
  fi
  # 偽の powershell.exe。引数を記録し、FAKE_PS_OUT (既定 set) を CRLF で出して FAKE_PS_RC で終わる
  {
    printf '#!%s\n' "${BASH}"
    cat <<'EOF'
printf '%s\n' "$*" >>"${HOME}/ps-calls"
printf '%s\r\n' "${FAKE_PS_OUT-set}"
exit "${FAKE_PS_RC:-0}"
EOF
  } >"${h}/bin/powershell.exe"
  # 偽の pwsh.exe (Install-PowerToys.ps1 を呼ぶ)。引数を記録し、出力を行ごとに CRLF で出して終わる。
  # -IfMissing の呼び出しは FAKE_PWSH_OUT2 / FAKE_PWSH_RC2、ほかは FAKE_PWSH_OUT (既定は入っている) / FAKE_PWSH_RC を使う
  {
    printf '#!%s\n' "${BASH}"
    printf 'installed_out=%q\n' "${installed_out}"
    cat <<'EOF'
printf '%s\n' "$*" >>"${HOME}/pwsh-calls"
case "$*" in
  *-IfMissing*)
    out=${FAKE_PWSH_OUT2-}
    rc=${FAKE_PWSH_RC2:-0}
    ;;
  *)
    out=${FAKE_PWSH_OUT-${installed_out}}
    rc=${FAKE_PWSH_RC:-0}
    ;;
esac
if [[ -n ${out} ]]; then
  while IFS= read -r l; do printf '%s\r\n' "${l}"; done <<<"${out}"
fi
exit "${rc}"
EOF
  } >"${h}/bin/pwsh.exe"
  # 偽の wslpath。-w <パス> を C:\fake\<ファイル名> にする
  {
    printf '#!%s\n' "${BASH}"
    cat <<'EOF'
[[ $1 == -w ]] || exit 1
printf 'C:\\fake\\%s\n' "${2##*/}"
EOF
  } >"${h}/bin/wslpath"
  chmod +x "${h}/bin/powershell.exe" "${h}/bin/pwsh.exe" "${h}/bin/wslpath"
  echo "${h}"
}

# $1: HOME、$2: 0 なら偽のコマンドを全部置く。1 なら Windows のコマンドを 1 つも置かない。
# 2 なら pwsh.exe だけ置かない (powershell.exe と wslpath は置く)、残り: script の引数
run() {
  local h=$1 mode=$2
  shift 2
  local path="${h}/bin:${sys_bin}"
  if [[ ${mode} == 1 ]]; then
    path="${sys_bin}"
  elif [[ ${mode} == 2 ]]; then
    mkdir -p "${h}/bin-nopwsh"
    ln -sf "${h}/bin/powershell.exe" "${h}/bin-nopwsh/powershell.exe"
    ln -sf "${h}/bin/wslpath" "${h}/bin-nopwsh/wslpath"
    path="${h}/bin-nopwsh:${sys_bin}"
  fi
  env HOME="${h}" PATH="${path}" "${BASH}" "${script}" "$@" >"${h}/out" 2>"${h}/err"
  echo $? >"${h}/rc"
}

rc() { cat "$1/rc"; }
outerr() { cat "$1/out" "$1/err"; }
ncalls() { grep -c '' "$1/ps-calls" 2>/dev/null || echo 0; }
npwsh() { grep -c '' "$1/pwsh-calls" 2>/dev/null || echo 0; }
pwsh_calls() { cat "$1/pwsh-calls" 2>/dev/null; }
record() { echo "$1/.local/state/dotfiles/powertoys-keyboard-manager.reloaded"; }

state_on='{"enable":true,"version":1,"windowsHome":"@WIN@"}'
state_off='{"enable":false,"version":1,"windowsHome":null}'

echo "== bootstrap-windows-powertoys.sh: ${script}"

# 1. 状態ファイルが無い / enable = false / default.json が無い: 呼ばずに飛ばす
for t in "nostate::1" "off:${state_off}:1" "nojson:${state_on}:0"; do
  name=${t%%:*}
  rest=${t#*:}
  state=${rest%:*}
  json=${rest##*:}
  h=$(new_home "t1-${name}" "${state}" "${json}")
  run "${h}" 0
  if [[ $(rc "${h}") == 0 && $(ncalls "${h}") == 0 && ! -e $(record "${h}") ]]; then
    ok "飛ばす (${name}): powershell.exe を呼ばない"
  else
    ng "飛ばす (${name})" "rc=$(rc "${h}") calls=$(ncalls "${h}") $(outerr "${h}")"
  fi
done

# 2. 送れた: 記録する。名前付きイベントの名前を渡す
h=$(new_home t2 "${state_on}" 1)
run "${h}" 0
if [[ $(rc "${h}") == 0 && $(ncalls "${h}") == 1 && -s $(record "${h}") ]] && outerr "${h}" | grep -q '読み直させました' \
  && grep -qF 'PowerToys_KeyboardManager_Event_Settings' "${h}/ps-calls" && grep -qF -- '-NoProfile' "${h}/ps-calls"; then
  ok "送れたら記録し、イベントの名前を渡す (CRLF の出力も読める)"
else
  ng "送れた" "rc=$(rc "${h}") calls=$(ncalls "${h}") $(outerr "${h}")"
fi

# 3. 同じ default.json: 呼ばない
run "${h}" 0
if [[ $(rc "${h}") == 0 && $(ncalls "${h}") == 1 ]] && outerr "${h}" | grep -q '読み直し済み'; then
  ok "同じ default.json なら呼ばない"
else
  ng "同じ default.json" "rc=$(rc "${h}") calls=$(ncalls "${h}") $(outerr "${h}")"
fi

# 4. --force: 同じでも呼ぶ
run "${h}" 0 --force
if [[ $(rc "${h}") == 0 && $(ncalls "${h}") == 2 ]]; then
  ok "--force なら同じでも呼ぶ"
else
  ng "--force" "rc=$(rc "${h}") calls=$(ncalls "${h}") $(outerr "${h}")"
fi

# 5. default.json が変わった: 呼んで記録を更新する
printf '{"remapKeys":{"inProcess":[]}}' >"${h}/win/AppData/Local/Microsoft/PowerToys/Keyboard Manager/default.json"
before=$(cat "$(record "${h}")")
run "${h}" 0
if [[ $(rc "${h}") == 0 && $(ncalls "${h}") == 3 && $(cat "$(record "${h}")") != "${before}" ]]; then
  ok "default.json が変わったら呼んで記録を更新する"
else
  ng "変わった" "rc=$(rc "${h}") calls=$(ncalls "${h}") $(outerr "${h}")"
fi

# 6. PowerToys が動いていない (absent): 記録する
h=$(new_home t6 "${state_on}" 1)
FAKE_PS_OUT=absent run "${h}" 0
if [[ $(rc "${h}") == 0 && -s $(record "${h}") ]] && outerr "${h}" | grep -q '動いていません'; then
  ok "PowerToys が動いていなければ記録する (起動したときに読む)"
else
  ng "absent" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 7. powershell.exe が無い: 手で読み直す方法を出し、記録しない
h=$(new_home t7 "${state_on}" 1)
run "${h}" 1
if [[ $(rc "${h}") == 0 && ! -e $(record "${h}") ]] && outerr "${h}" | grep -q 'オフにしてオンに戻す'; then
  ok "powershell.exe が無ければ手で読み直す方法を出し、記録しない"
else
  ng "powershell.exe が無い" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 8. powershell.exe が失敗する / 知らない出力: 手で読み直す方法を出し、記録しない
for t in "126:" "0:Exec format error"; do
  h=$(new_home "t8-${t%%:*}" "${state_on}" 1)
  FAKE_PS_RC=${t%%:*} FAKE_PS_OUT=${t#*:} run "${h}" 0
  if [[ $(rc "${h}") == 0 && ! -e $(record "${h}") ]] && outerr "${h}" | grep -q 'オフにしてオンに戻す'; then
    ok "powershell.exe が失敗・知らない出力 (rc=${t%%:*}) なら記録しない"
  else
    ng "失敗 (rc=${t%%:*})" "rc=$(rc "${h}") $(outerr "${h}")"
  fi
done

# 9. 知らない引数: exit 2
h=$(new_home t9 "${state_on}" 1)
run "${h}" 0 --bogus
if [[ $(rc "${h}") == 2 && $(ncalls "${h}") == 0 ]]; then
  ok "知らない引数は exit 2"
else
  ng "知らない引数" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 10. Install-PowerToys.ps1 が配られていない: pwsh.exe は呼ばず、確かめずに読み直しへ進む
h=$(new_home t10 "${state_on}" 1)
run "${h}" 0
if [[ $(rc "${h}") == 0 && $(npwsh "${h}") == 0 && $(ncalls "${h}") == 1 ]] && outerr "${h}" | grep -q 'Install-PowerToys.ps1 がまだ配られていません'; then
  ok "Install-PowerToys.ps1 が配られていなければ pwsh.exe を呼ばずに、読み直しへ進む"
else
  ng "Install-PowerToys.ps1 が無い" "rc=$(rc "${h}") pwsh=$(npwsh "${h}") ps=$(ncalls "${h}") $(outerr "${h}")"
fi

# 11. 入っている (-Check が 0): 入れずに読み直させる。pwsh.exe は -NoProfile -Check で、配った場所を渡す
h=$(new_home t11 "${state_on}" 1 1)
run "${h}" 0
if [[ $(rc "${h}") == 0 && $(npwsh "${h}") == 1 && $(ncalls "${h}") == 1 ]] && outerr "${h}" | grep -q 'PowerToys は入っています' \
  && outerr "${h}" | grep -q '読み直させました' && pwsh_calls "${h}" | grep -q -- '-NoProfile' \
  && pwsh_calls "${h}" | grep -q -- '-Check' && ! pwsh_calls "${h}" | grep -q -- '-IfMissing' \
  && pwsh_calls "${h}" | grep -qF 'C:\fake\Install-PowerToys.ps1'; then
  ok "入っていれば入れずに読み直させる (pwsh.exe は -NoProfile -Check、配った場所を渡す)"
else
  ng "入っている" "rc=$(rc "${h}") calls=$(pwsh_calls "${h}") ps=$(ncalls "${h}") $(outerr "${h}")"
fi

# 11b. スクリプトが exit まで届かずに終わっても成功扱いにしない: 呼ぶ前に $LASTEXITCODE を 2 にしておく
# shellcheck disable=SC2016 # PowerShell の $global:… を文字のまま探す
if pwsh_calls "${h}" | grep -qF '$global:LASTEXITCODE = 2; &'; then
  ok "pwsh.exe には、スクリプトを呼ぶ前に \$LASTEXITCODE を 2 にするコマンドを渡す"
else
  ng "\$LASTEXITCODE を先に 2 にしていない" "calls=$(pwsh_calls "${h}")"
fi

# 12. 読み直し済みでも、入っているかは毎回確かめる (確かめてから「読み直し済み」で終わる)
run "${h}" 0
if [[ $(rc "${h}") == 0 && $(npwsh "${h}") == 2 && $(ncalls "${h}") == 1 ]] && outerr "${h}" | grep -q '読み直し済み'; then
  ok "読み直し済みでも、入っているかは毎回確かめる"
else
  ng "読み直し済み" "rc=$(rc "${h}") pwsh=$(npwsh "${h}") ps=$(ncalls "${h}") $(outerr "${h}")"
fi

# 13. 入っていない (-Check が 3): -IfMissing で入れてから読み直させる
h=$(new_home t13 "${state_on}" 1 1)
FAKE_PWSH_RC=3 FAKE_PWSH_OUT="${missing_out}" FAKE_PWSH_RC2=0 FAKE_PWSH_OUT2="${added_out}" run "${h}" 0
if [[ $(rc "${h}") == 0 && $(npwsh "${h}") == 2 && $(ncalls "${h}") == 1 && -s $(record "${h}") ]] \
  && pwsh_calls "${h}" | tail -n 1 | grep -q -- '-IfMissing' && outerr "${h}" | grep -q 'PowerToys を入れました' \
  && outerr "${h}" | grep -q '読み直させました' && ! outerr "${h}" | grep -q '⚠️'; then
  ok "入っていなければ -IfMissing で入れてから読み直させる"
else
  ng "入っていない → 入れる" "rc=$(rc "${h}") calls=$(pwsh_calls "${h}") ps=$(ncalls "${h}") $(outerr "${h}")"
fi

# 14. 入れられない (-IfMissing が 1): ⚠ で囲んで知らせ、それでも読み直しへ進む
h=$(new_home t14 "${state_on}" 1 1)
FAKE_PWSH_RC=3 FAKE_PWSH_OUT="${missing_out}" FAKE_PWSH_RC2=1 FAKE_PWSH_OUT2='winget が失敗した (終了コード 0x8A150011)' run "${h}" 0
if [[ $(rc "${h}") == 0 && $(ncalls "${h}") == 1 ]] && outerr "${h}" | grep -q 'PowerToys を入れられませんでした (終了コード 1)' \
  && outerr "${h}" | grep -qF '0x8A150011' && outerr "${h}" | grep -qF 'PowerShell: Install-PowerToys' \
  && [[ $(outerr "${h}" | grep -c '⚠️') -ge 2 ]] && ! outerr "${h}" | grep -q $'\e\['; then
  ok "入れられなければ ⚠ で囲んで知らせ、読み直しへ進んで exit 0 (端末でなければ色を付けない)"
else
  ng "入れられない" "rc=$(rc "${h}") ps=$(ncalls "${h}") $(outerr "${h}")"
fi

# 15. -Check が 3 でもこちらの出力が無い・pwsh.exe が失敗する: 入れには行かず、手で打つコマンドを出して読み直しへ進む
for t in "3:Exec format error" "126:"; do
  h=$(new_home "t15-${t%%:*}" "${state_on}" 1 1)
  FAKE_PWSH_RC=${t%%:*} FAKE_PWSH_OUT=${t#*:} run "${h}" 0
  if [[ $(rc "${h}") == 0 && $(npwsh "${h}") == 1 && $(ncalls "${h}") == 1 ]] && outerr "${h}" | grep -q '確かめられませんでした' \
    && outerr "${h}" | grep -qF 'Install-PowerToys'; then
    ok "pwsh.exe の出力が来ない・失敗する (rc=${t%%:*}) なら、入れずに手で打つコマンドを出して読み直しへ進む"
  else
    ng "pwsh.exe の失敗 (rc=${t%%:*})" "rc=$(rc "${h}") pwsh=$(npwsh "${h}") ps=$(ncalls "${h}") $(outerr "${h}")"
  fi
done

# 16. pwsh.exe が無い (powershell.exe はある): 手で打つコマンドを出して、読み直しへ進む
h=$(new_home t16 "${state_on}" 1 1)
run "${h}" 2
if [[ $(rc "${h}") == 0 && $(ncalls "${h}") == 1 && -s $(record "${h}") ]] && outerr "${h}" | grep -q 'pwsh.exe が見つかりません' \
  && outerr "${h}" | grep -qF 'Install-PowerToys'; then
  ok "pwsh.exe が無ければ手で打つコマンドを出して、読み直しへ進む"
else
  ng "pwsh.exe が無い" "rc=$(rc "${h}") ps=$(ncalls "${h}") $(outerr "${h}")"
fi

# 17. default.json がまだ無くても、PowerToys が入っているかは確かめる (入れるのは default.json に依らない)
h=$(new_home t17 "${state_on}" 0 1)
FAKE_PWSH_RC=3 FAKE_PWSH_OUT="${missing_out}" FAKE_PWSH_RC2=0 FAKE_PWSH_OUT2="${added_out}" run "${h}" 0
if [[ $(rc "${h}") == 0 && $(npwsh "${h}") == 2 && $(ncalls "${h}") == 0 ]] && outerr "${h}" | grep -q 'PowerToys を入れました' \
  && outerr "${h}" | grep -q 'default.json がまだありません'; then
  ok "default.json が無くても、入っていなければ入れてから飛ばす"
else
  ng "default.json が無い" "rc=$(rc "${h}") pwsh=$(npwsh "${h}") ps=$(ncalls "${h}") $(outerr "${h}")"
fi

# 18. script に実行ビットがある (setup.sh は実行ビットの無い bootstrap を「実行できません」で止める)
if [[ -x ${script} ]]; then
  ok "script に実行ビットがある (setup.sh は実行できない bootstrap で止まる)"
else
  ng "script に実行ビットが無い" "$(ls -l "${script}")"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
```

- [ ] **Step 2: テストが落ちることを確かめる**

Run: `bash nix/tests/bootstrap-windows-powertoys.test.sh | tail -1`
Expected: `== 13 passed, 10 failed` (今の script では pwsh.exe を呼ばないので、10〜17 の確かめが落ちる)。

- [ ] **Step 3: script を差し替える `nix/scripts/bootstrap-windows-powertoys.sh`**

```bash
#!/usr/bin/env bash
# shellcheck shell=bash
#
# win/ から配った PowerToys の Keyboard Manager の割り当て (default.json) を、Keyboard Manager に読み直させる。
# 冪等。`setup.sh --update` でも毎回走る。PowerToys が入っていなければ、先に winget で入れる。
#
# order: 91
#
# ^ setup.sh が読む実行順。bootstrap-windows-files.sh (order: 90) が default.json と
#   Install-PowerToys.ps1 を置いた後に走らせる。仕組みは nix/README.md「bootstrap の実行順」。
#
# ## 何のために
#
# Keyboard Manager のエンジンは、起動したときと、名前付きイベント
# PowerToys_KeyboardManager_Event_Settings を受けたときにしか default.json を読まない
# (docs/adr/015_win_google_ime_powertoys_*)。win/ の割り当てを配っても、そのままでは効かない。
# 新しいマシンでは PowerToys そのものが入っていないので、読み直させる前に入れる (docs/adr/017_win_apps_winget_*)。
#
# ## 何をするか
#
# 1. ~/.local/state/dotfiles/windows-files.json を読み、配らないマシンなら飛ばす
# 2. pwsh.exe で <windowsHome>/.config/powershell/Install-PowerToys.ps1 -Check を流し、3 (入っていない) なら
#    -IfMissing で入れる (user スコープ。管理者は要らない)。版は固定しないので、入っていれば何もしない。
#    スクリプトが無い・interop が使えない・入れられないときは、知らせて 3 へ進む
# 3. <windowsHome>/AppData/Local/Microsoft/PowerToys/Keyboard Manager/default.json が無ければ飛ばす
# 4. default.json の sha256 が、前回読み直させたときの記録
#    (~/.local/state/dotfiles/powertoys-keyboard-manager.reloaded) と同じなら何もしない (--force なら比べない)
# 5. powershell.exe でイベントを送る。送れたら記録する。イベントが無い (PowerToys が動いていない) ときも
#    記録する (起動したときに読むため)。interop が使えなければ手で読み直す方法を出し、記録しない
#
# どの場合も exit 0 (後ろの手順を止めない)。知らない引数だけ exit 2。

set -eu -o pipefail

usage() {
  cat <<'EOS'
win/ から配った PowerToys の Keyboard Manager の割り当て (default.json) を、Keyboard Manager に読み直させる。
PowerToys が入っていなければ、先に winget で入れる。

使い方:
  bootstrap-windows-powertoys.sh          前回から変わっていれば読み直させる
  bootstrap-windows-powertoys.sh --force  変わっていなくても読み直させる
EOS
}

force=0
for arg in "$@"; do
  case ${arg} in
    --force) force=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "不明な引数です: ${arg}" >&2
      usage >&2
      exit 2
      ;;
  esac
done

script_dir=$(
  cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null || exit
  pwd -P
)
state_file="${HOME}/.local/state/dotfiles/windows-files.json"
record_file="${HOME}/.local/state/dotfiles/powertoys-keyboard-manager.reloaded"
event=PowerToys_KeyboardManager_Event_Settings

# ⚠ の枠を色付きで出すか。端末のときだけ (パイプや NO_COLOR では付けない)
if [[ -t 2 && -z ${NO_COLOR-} ]]; then
  c_warn=$'\e[1;33m'
  c_reset=$'\e[0m'
else
  c_warn=""
  c_reset=""
fi

manual() {
  echo "   PowerToys の設定 → Keyboard Manager を一度オフにしてオンに戻すと、読み直します。" >&2
}

# PowerToys が入っているかを自動で確かめられないときに、手で確かめて入れるコマンドを出す
install_manual() {
  echo "   Windows の PowerShell で次を打つと、確かめて、入っていなければ入れられます:" >&2
  echo "     Install-PowerToys" >&2
}

# CRLF と、PowerShell が付けうる色のエスケープを落とす (枠の色はこちらで付ける)
esc=$'\e'
clean() {
  tr -d '\r' | sed "s/${esc}\[[0-9;]*[A-Za-z]//g"
}

# ⚠ で囲んだ注意を出す。$1: 見出し、$2: 枠に入れる出力 (状態の表など)
rule="⚠️ ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ ⚠️"
warn_frame() {
  {
    printf '%s%s%s\n' "${c_warn}" "${rule}" "${c_reset}"
    printf '%s⚠️  %s%s\n' "${c_warn}" "$1" "${c_reset}"
    printf '%s%s%s\n' "${c_warn}" "${rule}" "${c_reset}"
    # PowerShell の締めの 1 行 (⚠️ … → Install-PowerToys …) は、下の入れるコマンドと重なるので落とす
    printf '%s\n' "$2" | grep -v '^⚠️ ' | sed 's/^/    /' || true
    printf '%s⚠️  入れるには次のどちらかを打つ (管理者は要りません):%s\n' "${c_warn}" "${c_reset}"
    printf '%s⚠️    WSL:        %s/bootstrap-windows-powertoys.sh (流し直すと、もう一度入れにいく)%s\n' "${c_warn}" "${script_dir}" "${c_reset}"
    printf '%s⚠️    PowerShell: Install-PowerToys%s\n' "${c_warn}" "${c_reset}"
    printf '%s%s%s\n' "${c_warn}" "${rule}" "${c_reset}"
  } >&2
}

# PowerToys が入っていなければ、Install-PowerToys.ps1 -IfMissing で入れる (docs/adr/017_win_apps_winget_*)。
# 入っているかは -Check (PowerToys.exe があるか) で見る。何があっても 0 を返し、読み直しへ進む
install_powertoys() {
  local deployed="${windows_home}/.config/powershell/Install-PowerToys.ps1"
  local win_script quoted rc out header=0
  if [[ -z ${windows_home} || ! -f ${deployed} ]]; then
    echo "Install-PowerToys.ps1 がまだ配られていません (${deployed})。PowerToys が入っているかは確かめずに進みます。"
    return 0
  fi
  if ! command -v pwsh.exe &>/dev/null; then
    echo "!! pwsh.exe が見つかりません (PowerShell 7 が無いか、WSL の PATH に Windows の PATH が入っていない)。PowerToys が入っているかを確かめられません。" >&2
    install_manual
    return 0
  fi
  if ! win_script=$(wslpath -w "${deployed}" 2>/dev/null) || [[ -z ${win_script} ]]; then
    echo "!! Install-PowerToys.ps1 の場所を Windows のパスに直せませんでした: ${deployed}" >&2
    install_manual
    return 0
  fi
  # 呼ぶ前に $LASTEXITCODE を 2 にしておく (bootstrap-windows-herdr.sh と同じ。スクリプトが exit まで
  # 届かずに終わったときに、中で打った外部コマンドの 0 を返して成功に見せないため)
  quoted=${win_script//\'/\'\'}
  rc=0
  out=$(timeout 60 pwsh.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "[Console]::OutputEncoding = [Text.Encoding]::UTF8; \$global:LASTEXITCODE = 2; & '${quoted}' -Check; exit \$LASTEXITCODE" </dev/null 2>&1) || rc=$?
  out=$(printf '%s\n' "${out}" | clean)
  # 入っていないときの出力には、状態の表の見出し (パッケージ名) が必ず入る。
  # 3 でも見出しが無ければ、スクリプトが動いていない (入っていないとは扱わない)
  if grep -qF 'Microsoft.PowerToys' <<<"${out}"; then
    header=1
  fi
  if ((rc == 0)); then
    echo "PowerToys は入っています。"
    return 0
  fi
  if ((rc == 3 && header)); then
    echo "Windows に PowerToys が入っていないので、winget で入れます (Install-PowerToys.ps1 -IfMissing。user スコープ)。"
    # installer のダウンロードを待つので長めに待つ
    rc=0
    out=$(timeout 600 pwsh.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "[Console]::OutputEncoding = [Text.Encoding]::UTF8; \$global:LASTEXITCODE = 2; & '${quoted}' -IfMissing; exit \$LASTEXITCODE" </dev/null 2>&1) || rc=$?
    out=$(printf '%s\n' "${out}" | clean)
    if ((rc == 0)); then
      printf '%s\n' "${out}" | sed 's/^/  /'
      echo "Windows に PowerToys を入れました。動いていなければ、スタートメニューから PowerToys を起動してください。"
      return 0
    fi
    warn_frame "Windows に PowerToys を入れられませんでした (終了コード ${rc})" "${out}"
    return 0
  fi
  echo "!! pwsh.exe で PowerToys が入っているかを確かめられませんでした (終了コード ${rc}。WSL の interop が落ちているかもしれません):" >&2
  if [[ -n ${out} ]]; then
    printf '%s\n' "${out}" | sed 's/^/   /' >&2
  fi
  install_manual
  return 0
}

if ! command -v jq &>/dev/null; then
  echo "jq が見つかりません。先に home-manager switch を実行してください。" >&2
  exit 0
fi
if [[ ! -r ${state_file} ]]; then
  echo "配り先の設定がありません (${state_file})。この手順は飛ばします。"
  exit 0
fi
if [[ $(jq -r '.enable' "${state_file}") != true ]]; then
  echo "このマシンは Windows 側へ配りません (dotfiles.wsl.windowsFiles.enable = false)。"
  exit 0
fi
windows_home=$(jq -r '.windowsHome // ""' "${state_file}")

install_powertoys

default_json="${windows_home}/AppData/Local/Microsoft/PowerToys/Keyboard Manager/default.json"
if [[ -z ${windows_home} || ! -f ${default_json} ]]; then
  echo "Keyboard Manager の default.json がまだありません (${default_json})。この手順は飛ばします。"
  exit 0
fi

sum=$(sha256sum <"${default_json}" | cut -d' ' -f1)
if ((! force)) && [[ -r ${record_file} && $(head -n 1 "${record_file}") == "${sum}" ]]; then
  echo "Keyboard Manager は、今の default.json を読み直し済みです。"
  exit 0
fi

# PowerShell に渡すコマンド。イベントがあれば Set() して set、無ければ absent を出す
ps="\$h = \$null; if ([System.Threading.EventWaitHandle]::TryOpenExisting('${event}', [ref]\$h)) { [void]\$h.Set(); \$h.Dispose(); 'set' } else { 'absent' }"

rc=0
out=$(timeout 60 powershell.exe -NoProfile -NonInteractive -Command "${ps}" </dev/null 2>&1) || rc=$?
out=$(printf '%s\n' "${out}" | tr -d '\r')

remember() {
  mkdir -p "$(dirname -- "${record_file}")"
  printf '%s\n' "${sum}" >"${record_file}"
}

if ((rc == 0)) && [[ ${out} == set ]]; then
  remember
  echo "Keyboard Manager に default.json を読み直させました。"
  exit 0
fi
if ((rc == 0)) && [[ ${out} == absent ]]; then
  remember
  echo "PowerToys (Keyboard Manager) が動いていません。起動したときに今の default.json を読みます。"
  exit 0
fi
echo "!! powershell.exe で Keyboard Manager に読み直させられませんでした (終了コード ${rc}。WSL の interop が落ちているかもしれません):" >&2
if [[ -n ${out} ]]; then
  printf '%s\n' "${out}" | sed 's/^/   /' >&2
fi
manual
exit 0
```

- [ ] **Step 4: mode が変わっていないことを確かめる**

Run: `git diff --summary nix/scripts/bootstrap-windows-powertoys.sh; ls -l nix/scripts/bootstrap-windows-powertoys.sh`
Expected: `git diff --summary` は何も出さない (`mode change` の行が出たら `chmod +x nix/scripts/bootstrap-windows-powertoys.sh`)。`ls` は `-rwxr-xr-x …`。

- [ ] **Step 5: テストが通ることを確かめる**

Run: `bash nix/tests/bootstrap-windows-powertoys.test.sh | tail -1`
Expected: `== 23 passed, 0 failed`

Run: `nix build --no-link -L './nix#checks.x86_64-linux.bootstrap-windows-powertoys-test' 2>&1 | grep -E '== [0-9]|FAIL'`
Expected: `bootstrap-windows-powertoys-test> == 23 passed, 0 failed`

- [ ] **Step 6: 静的な確かめ**

Run: `nix develop ./nix --command bash -c 'shfmt -d nix/scripts/bootstrap-windows-powertoys.sh nix/tests/bootstrap-windows-powertoys.test.sh && shellcheck nix/scripts/bootstrap-windows-powertoys.sh nix/tests/bootstrap-windows-powertoys.test.sh && echo LINT_OK'`
Expected: `LINT_OK`

- [ ] **Step 7: Commit**

```bash
git add nix/scripts/bootstrap-windows-powertoys.sh nix/tests/bootstrap-windows-powertoys.test.sh
git commit -F - <<'EOF'
feat(nix): bootstrap-windows-powertoys.sh で、読み直させる前に PowerToys が無ければ winget で入れる (TKT-143)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01YSF6gCGyvBHzRBtjbB61Fm
EOF
```

---

### Task 6: `bootstrap-windows-google-ime.sh` (order 98) で、入っているがまだ使っていない Google 日本語入力を案内し、`--import` の確かめを 3 つのテキストに絞る

2 段に分けて commit する。前半 (Step 1〜7) は ADR 017 の決定 C、後半 (Step 8〜14) は plan で足した変更 (「ADR の読み方」の表の太字の行)。後半を採らないときは Step 7 で止める。

**Files:**
- Modify: `nix/tests/bootstrap-windows-google-ime.test.sh` (冒頭の「確かめること」に 2 行、末尾の集計の前にテスト 31〜33)
- Modify: `nix/scripts/bootstrap-windows-google-ime.sh` (冒頭のコメント、`ime_dir` の判定、`--import` の git status の 2 か所)

**Interfaces:**
- Consumes: Task 1 のファイル名 `Install-GoogleJapaneseInput.ps1` (テスト 33 は偽の repo に同じ名前のファイルを置く)
- Produces: IME のディレクトリが無く、`<ドライブ>/Program Files/Google/Google Japanese Input/GoogleIMEJaConverter.exe` か `<ドライブ>/Program Files (x86)/…` があれば、`!! Google 日本語入力は入っていますが、まだ使われていません …` を stderr に出して exit 0。`--import` は `config.txtpb`・`keymap.tsv`・`romaji.tsv` (と辞書のディレクトリ) の commit していない変更だけで止まる

このテストは `pjp-google-ime` と protobuf の入った python が要るので、flake の check (Nix のサンドボックス) で流す。追っているファイルの変更は commit しなくても flake から見える。

- [ ] **Step 1: 冒頭の「確かめること」に 1 行足す**

`nix/tests/bootstrap-windows-google-ime.test.sh` を Edit で、old_string:

```bash
#   - 辞書の衝突は語を出さず、辞書ごとの行の数だけを出す (--show-words で diff)
```

new_string:

```bash
#   - 辞書の衝突は語を出さず、辞書ごとの行の数だけを出す (--show-words で diff)
#   - 入っているがまだ使っていない (置き先が無い) ときは、一度使ってから流し直すよう出す (exit 0)
```

- [ ] **Step 2: 末尾の集計の前にテスト 31・32 を足す**

old_string (ファイルの最後から 2 行目。この 1 行だけ):

```bash
echo "== ${pass} passed, ${fail} failed"
```

new_string (足すテストのあとに、同じ 1 行を残す):

```bash
# 31〜32. Google 日本語入力は入っているが、まだ使っていない (置き先が無い): 一度使ってから流し直すよう出して exit 0。
#     Program Files は 64 ビットと x86 のどちらにあってもよい。windowsHome は本物と同じく <ドライブ>/Users/<名前> の形にする
for t in "t31:Program Files (x86)" "t32:Program Files"; do
  h=$(new_home "${t%%:*}" "" 0)
  mkdir -p "${h}/c/Users/u" "${h}/c/${t#*:}/Google/Google Japanese Input"
  printf 'exe' >"${h}/c/${t#*:}/Google/Google Japanese Input/GoogleIMEJaConverter.exe"
  printf '{"enable":true,"version":1,"windowsHome":"%s"}\n' "${h}/c/Users/u" >"${h}/.local/state/dotfiles/windows-files.json"
  run "${h}" 0
  if [[ $(rc "${h}") == 0 && ! -e ${h}/tasklist-calls && ! -e "${h}/c/Users/u/AppData/LocalLow/Google/Google Japanese Input" ]] \
    && outerr "${h}" | grep -q 'まだ使われていません' && outerr "${h}" | grep -q '一度何か打ってから' \
    && ! outerr "${h}" | grep -q '入っていません'; then
    ok "入っているがまだ使っていなければ (${t#*:})、一度使ってから流し直すよう出して exit 0 (置き先は作らない)"
  else
    ng "入っているが使っていない (${t#*:})" "rc=$(rc "${h}") $(outerr "${h}")"
  fi
done

echo "== ${pass} passed, ${fail} failed"
```

- [ ] **Step 3: テストが落ちることを確かめる**

Run: `nix build --no-link -L './nix#checks.x86_64-linux.bootstrap-windows-google-ime-test' 2>&1 | grep -E '== [0-9]|FAIL'`
Expected: build は失敗し、`FAIL 入っているが使っていない (Program Files (x86))`・`FAIL 入っているが使っていない (Program Files)`・`== 34 passed, 2 failed`。

- [ ] **Step 4: script の冒頭のコメントに 1 行足す**

`nix/scripts/bootstrap-windows-google-ime.sh` を Edit で、old_string:

```bash
# 1. 前提を確かめる。配らないマシン・Google 日本語入力が入っていないマシンは exit 0 で飛ばす。
#    interop (tasklist.exe) が使えなければ置かずに exit 0 (変換サーバーを再起動できず、置いたものが
```

new_string:

```bash
# 1. 前提を確かめる。配らないマシン・Google 日本語入力が入っていないマシンは exit 0 で飛ばす。
#    入っているがまだ使っていない (置き先が無い) マシンは、一度使ってから流し直すよう出して exit 0。
#    interop (tasklist.exe) が使えなければ置かずに exit 0 (変換サーバーを再起動できず、置いたものが
```

- [ ] **Step 5: IME のディレクトリが無いときに、入っているかを見分ける**

old_string:

```bash
ime_dir="${windows_home}/AppData/LocalLow/Google/Google Japanese Input"
if [[ ! -d ${ime_dir} ]]; then
  echo "Google 日本語入力が入っていません (${ime_dir} が無い)。この手順は飛ばします。"
  exit 0
fi
```

new_string:

```bash
ime_dir="${windows_home}/AppData/LocalLow/Google/Google Japanese Input"
if [[ ! -d ${ime_dir} ]]; then
  # 置き先は、Google 日本語入力が初めて起動したときに作る。入れただけでまだ使っていないマシン
  # (新しいマシンの 1 回目の setup) では無いので、変換サーバーの exe で「入っている」を見分けて案内する
  # (docs/adr/017_win_apps_winget_*)。置き先を先に作って置くことはしない (Google 日本語入力が作るときの
  # 権限と揃わないおそれがある)。Program Files は Windows のホーム (/mnt/c/Users/<名前>) と同じドライブにある
  windows_root=${windows_home%/Users/*}
  for d in "${windows_root}/Program Files" "${windows_root}/Program Files (x86)"; do
    if [[ -f "${d}/Google/Google Japanese Input/GoogleIMEJaConverter.exe" ]]; then
      {
        echo "!! Google 日本語入力は入っていますが、まだ使われていません (${ime_dir} が無い)。この手順は飛ばします。"
        echo "   Google 日本語入力で一度何か打ってから (置き先ができる)、setup --update を流し直してください。"
      } >&2
      exit 0
    fi
  done
  echo "Google 日本語入力が入っていません (${ime_dir} が無い)。この手順は飛ばします。"
  exit 0
fi
```

- [ ] **Step 6: テストが通ることを確かめる**

Run: `nix build --no-link -L './nix#checks.x86_64-linux.bootstrap-windows-google-ime-test' 2>&1 | grep -E '== [0-9]|FAIL'`
Expected: `bootstrap-windows-google-ime-test> == 36 passed, 0 failed`

Run: `nix develop ./nix --command bash -c 'shfmt -d nix/scripts/bootstrap-windows-google-ime.sh nix/tests/bootstrap-windows-google-ime.test.sh && shellcheck nix/scripts/bootstrap-windows-google-ime.sh nix/tests/bootstrap-windows-google-ime.test.sh && echo LINT_OK'`
Expected: `LINT_OK`

- [ ] **Step 7: Commit**

```bash
git add nix/scripts/bootstrap-windows-google-ime.sh nix/tests/bootstrap-windows-google-ime.test.sh
git commit -F - <<'EOF'
feat(nix): bootstrap-windows-google-ime.sh で、入っているがまだ使っていない Google 日本語入力を案内する (TKT-143)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01YSF6gCGyvBHzRBtjbB61Fm
EOF
```

- [ ] **Step 8: 「確かめること」にもう 1 行足す**

`nix/tests/bootstrap-windows-google-ime.test.sh` を Edit で、old_string:

```bash
#   - 入っているがまだ使っていない (置き先が無い) ときは、一度使ってから流し直すよう出す (exit 0)
```

new_string:

```bash
#   - 入っているがまだ使っていない (置き先が無い) ときは、一度使ってから流し直すよう出す (exit 0)
#   - --import は、同じディレクトリの Install-GoogleJapaneseInput.ps1 の変更では止まらない
```

- [ ] **Step 9: 末尾の集計の前にテスト 33 を足す**

old_string:

```bash
echo "== ${pass} passed, ${fail} failed"
```

new_string:

```bash
# 33. --import は、同じディレクトリの Install-GoogleJapaneseInput.ps1 に commit していない変更 (版を上げる途中) があっても止まらない
h=$(new_home t33 "${state_on}" 1)
printf '# Install-GoogleJapaneseInput.ps1\n' >"${h}/repo/win/google-japanese-input/Install-GoogleJapaneseInput.ps1"
git -C "${h}/repo" add -A
git -C "${h}/repo" commit --quiet -m 'Install-GoogleJapaneseInput.ps1 を足した'
run "${h}" 0
put_windows "${h}" $'status\tkey\tcommand\nDirectInput\tF13\tIMEOn\n'
printf "    [string]\$Version = '3.35.0.0',\n" >>"${h}/repo/win/google-japanese-input/Install-GoogleJapaneseInput.ps1"
run "${h}" 0 --import
if [[ $(rc "${h}") == 0 ]] && ! grep -q '^Precomposition' "${h}/repo/win/google-japanese-input/keymap.tsv" \
  && grep -qF '3.35.0.0' "${h}/repo/win/google-japanese-input/Install-GoogleJapaneseInput.ps1" \
  && outerr "${h}" | grep -q '取り込みました'; then
  ok "--import は Install-GoogleJapaneseInput.ps1 に commit していない変更があっても止まらず、テキストだけを取り込む"
else
  ng "--import と Install-GoogleJapaneseInput.ps1" "rc=$(rc "${h}") $(outerr "${h}")"
fi

echo "== ${pass} passed, ${fail} failed"
```

- [ ] **Step 10: テストが落ちることを確かめる**

Run: `nix build --no-link -L './nix#checks.x86_64-linux.bootstrap-windows-google-ime-test' 2>&1 | grep -E '== [0-9]|FAIL|M Install'`
Expected: build は失敗し、`FAIL --import と Install-GoogleJapaneseInput.ps1`・`M Install-GoogleJapaneseInput.ps1` (今の確かめはスクリプトの変更でも止まる)・`== 36 passed, 1 failed`。

- [ ] **Step 11: `--import` の確かめを 3 つのテキストに絞る**

old_string:

```bash
  # --untracked-files=normal は、未追跡を見せない設定 (status.showUntrackedFiles=no) でも見るため
  for d in "${config_dir}" ${dict_dir:+"${dict_dir}"}; do
    if ! changes=$(git --no-optional-locks -C "${d}" status --porcelain --untracked-files=normal -- . 2>"${tmp}/git-status.err"); then
```

new_string:

```bash
  # --untracked-files=normal は、未追跡を見せない設定 (status.showUntrackedFiles=no) でも見るため。
  # 設定の側で見るのは取り込みが書き換える 3 つだけ。同じディレクトリの Install-GoogleJapaneseInput.ps1
  # (ADR 017) は取り込みで変わらないので、版を上げる途中 (-Version を変えて commit する前) でも取り込める
  for d in "${config_dir}" ${dict_dir:+"${dict_dir}"}; do
    if [[ ${d} == "${config_dir}" ]]; then
      watched=(config.txtpb keymap.tsv romaji.tsv)
    else
      watched=(.)
    fi
    if ! changes=$(git --no-optional-locks -C "${d}" status --porcelain --untracked-files=normal -- "${watched[@]}" 2>"${tmp}/git-status.err"); then
```

- [ ] **Step 12: 変わったファイルの一覧も同じ対象で出す**

old_string:

```bash
        git --no-optional-locks -c core.quotePath=false -C "${d}" status --short --untracked-files=normal -- . | sed 's/^/   /'
```

new_string:

```bash
        git --no-optional-locks -c core.quotePath=false -C "${d}" status --short --untracked-files=normal -- "${watched[@]}" | sed 's/^/   /'
```

- [ ] **Step 13: テストが通ることを確かめる**

Run: `nix build --no-link -L './nix#checks.x86_64-linux.bootstrap-windows-google-ime-test' 2>&1 | grep -E '== [0-9]|FAIL'`
Expected: `bootstrap-windows-google-ime-test> == 37 passed, 0 failed` (テスト 27 の「keymap.tsv に commit していない変更があると止まる」も通ったまま)。

Run: `nix develop ./nix --command bash -c 'shfmt -d nix/scripts/bootstrap-windows-google-ime.sh nix/tests/bootstrap-windows-google-ime.test.sh && shellcheck nix/scripts/bootstrap-windows-google-ime.sh nix/tests/bootstrap-windows-google-ime.test.sh && echo LINT_OK'`
Expected: `LINT_OK`

- [ ] **Step 14: Commit**

```bash
git add nix/scripts/bootstrap-windows-google-ime.sh nix/tests/bootstrap-windows-google-ime.test.sh
git commit -F - <<'EOF'
fix(nix): --import の commit していない変更の確かめを、取り込みが書き換える 3 つのテキストに絞る (TKT-143)

win/google-japanese-input/ に Install-GoogleJapaneseInput.ps1 を置いたので、今のままでは
版を上げる途中 (-Version を変えて commit する前) の --import が止まる (ADR 017 §7)。

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01YSF6gCGyvBHzRBtjbB61Fm
EOF
```

---

### Task 7: README と ADR を今の形に合わせる

**Files:**
- Modify: `win/README.md` (W1〜W6)
- Modify: `nix/README.md` (N1〜N7)
- Modify: `docs/adr/017_win_apps_winget_20261012T115007JST/README.md` (A1〜A4。§2.C と §3)
- Modify: `docs/adr/015_win_google_ime_powertoys_20261011T234247JST/README.md` (B1〜B2。冒頭の表と §7)

**Interfaces:**
- Consumes: Task 1〜6 で決まった名前・引数・終了コード・件数 (PowerShell 80 / 24、bootstrap 25 / 23 / 37)
- Produces: なし

どれも Edit で、old_string を new_string に置き換える (old_string はファイルの中に 1 か所だけある)。Task 6 の後半を採らなかったときは、W5・A1・A2 を飛ばす (A2 で直す 98 の行は、今のままで前半の変更を表している)。

- [ ] **Step 1: `win/README.md`**

**W1** — 冒頭の表に 2 つのスクリプトの行を足し、`google-japanese-input/` の行にテキストのファイル名を足す。old_string:

````text
| `powertoys/keyboard-manager/editorSettings.json` | `%LOCALAPPDATA%\Microsoft\PowerToys\Keyboard Manager\editorSettings.json` | Keyboard Manager の新しいエディタが持つ割り当ての一覧 ([後述](#powertoys)) |
| `google-japanese-input/` | `%USERPROFILE%\AppData\LocalLow\Google\Google Japanese Input\` | Google 日本語入力の設定とキー設定のテキスト。manifest では配らず、組み立てて配る ([後述](#google-日本語入力)、[TKT-139](https://app.notion.com/p/Windows-Google-dotfiles-win-3f679149a66f81b1a592d85d7300a62b)) |
````

new_string:

````text
| `powertoys/keyboard-manager/editorSettings.json` | `%LOCALAPPDATA%\Microsoft\PowerToys\Keyboard Manager\editorSettings.json` | Keyboard Manager の新しいエディタが持つ割り当ての一覧 ([後述](#powertoys)) |
| `powertoys/Install-PowerToys.ps1` | `%USERPROFILE%\.config\powershell\Install-PowerToys.ps1` | Windows の PowerToys が入っていなければ winget で入れる。PowerShell の `Install-PowerToys` から呼ぶ ([後述](#powertoys-を入れる-winget)、[TKT-143](https://app.notion.com/p/winget-Windows-Google-PowerToys-Google-dotfiles-3f779149a66f817a8944c9e4e460383f)) |
| `google-japanese-input/` | `%USERPROFILE%\AppData\LocalLow\Google\Google Japanese Input\` | Google 日本語入力の設定とキー設定のテキスト (`config.txtpb`・`keymap.tsv`)。manifest では配らず、組み立てて配る ([後述](#google-日本語入力)、[TKT-139](https://app.notion.com/p/Windows-Google-dotfiles-win-3f679149a66f81b1a592d85d7300a62b)) |
| `google-japanese-input/Install-GoogleJapaneseInput.ps1` | `%USERPROFILE%\.config\powershell\Install-GoogleJapaneseInput.ps1` | Windows の Google 日本語入力を winget で固定した版に揃える。PowerShell の `Install-GoogleJapaneseInput` から呼ぶ ([後述](#google-日本語入力を入れる-winget)、[TKT-143](https://app.notion.com/p/winget-Windows-Google-PowerToys-Google-dotfiles-3f779149a66f817a8944c9e4e460383f)) |
````

**W2** — PowerToys の読み直しの箇条に、先に入れることを足す。old_string:

````text
- 配ったあと、続く `nix/scripts/bootstrap-windows-powertoys.sh` (order 91) が、名前付きイベント
````

new_string:

````text
- 配ったあと、続く `nix/scripts/bootstrap-windows-powertoys.sh` (order 91) が、PowerToys が入っていなければ先に入れ
  ([PowerToys を入れる](#powertoys-を入れる-winget))、名前付きイベント
````

**W3** — PowerToys の節の末尾に「PowerToys を入れる (winget)」と「Install-PowerToys.ps1 を書くときの注意」。old_string:

````text
  cp "${d}/default.json" "${d}/editorSettings.json" win/powertoys/keyboard-manager/
  ```

## Google 日本語入力
````

new_string:

````text
  cp "${d}/default.json" "${d}/editorSettings.json" win/powertoys/keyboard-manager/
  ```

### PowerToys を入れる (winget)

PowerToys は winget の `Microsoft.PowerToys` を user スコープ (`PowerToysUserSetup-…exe`。管理者は要らない) で入れる。
版は固定せず、winget pin も足さない。PowerToys は自分で新しい版を知らせる
([ADR 017](../docs/adr/017_win_apps_winget_20261012T115007JST/README.md)、[TKT-143](https://app.notion.com/p/winget-Windows-Google-PowerToys-Google-dotfiles-3f779149a66f817a8944c9e4e460383f))。

| 打つもの | すること |
| --- | --- |
| `Install-PowerToys -Check` (PowerShell) | 入っているかを出すだけ。入っていれば終了コード 0、入っていなければ 3 |
| `Install-PowerToys` (PowerShell) | 入っていなければ入れる (`-IfMissing` を付けても同じ) |
| `nix/scripts/bootstrap-windows-powertoys.sh` (WSL) | `setup --update` でも毎回走る。読み直させる前に `-Check` を流し、入っていなければ `-IfMissing` で入れる |

- 入っているかは、`PowerToys.exe` が `%LOCALAPPDATA%\PowerToys\` (user スコープ) か `C:\Program Files\PowerToys\`
  (machine スコープ) にあるかで見る。この PC は user スコープ
- 入れられなかったら (ネットワーク・winget の失敗)、⚠ で囲んで知らせ、そのまま `default.json` の読み直しへ進む
  (setup は止めない)。次の `setup --update` でも、もう一度入れにいく
- 入れた直後は PowerToys が動いていないことがある。スタートメニューから起動すると、配った `default.json` を読む
- 入れたばかりのマシンで、Keyboard Manager が配った割り当てを読むか (`settings.json` ができるか) は、まだ確かめていない
  (次の新しいマシンで確かめる。ADR 017 §1 の 7)

### Install-PowerToys.ps1 を書くときの注意

- `dotfiles.ps1` と同じく **BOM 付きの UTF-8** で保存する
- 副作用の無い関数 (置き場所の候補・winget の引数・状態の表・流れ) は `powertoys/Install-PowerToys.Tests.ps1` で
  確かめる。Linux の pwsh で流すので Windows には触らない (このファイルは manifest に無いので配られない):

  ```sh
  nix shell nixpkgs#powershell -c pwsh -NoProfile -File win/powertoys/Install-PowerToys.Tests.ps1
  ```

- winget やファイルに触る部分は、実機で `-Check` を打って確かめる

## Google 日本語入力
````

**W4** — Google 日本語入力の箇条に「入っているがまだ使っていない」を足す。old_string:

````text
  使えない (exit 2)
- 置き換える前のファイルは
````

new_string:

````text
  使えない (exit 2)
- Google 日本語入力は入っているが置き先 (`%USERPROFILE%\AppData\LocalLow\Google\Google Japanese Input`) がまだ無い
  (入れただけで一度も使っていない) ときは、一度使ってから流し直すよう出して飛ばす (exit 0)。置き先は Google 日本語入力が
  初めて起動したときに作るので、先に作って置くことはしない (作るときの権限と揃わないおそれがある)。新しいマシンの流れは
  [Google 日本語入力を入れる](#google-日本語入力を入れる-winget)
- 置き換える前のファイルは
````

**W5** — `--import` が止まる対象を書く (Task 6 の後半を採らないときは飛ばす)。old_string:

````text
  - repo 側 (`win/google-japanese-input/` と dotfiles-private の辞書) に commit していない変更 (未追跡の
    ファイルも) があると、変わったファイル名を出して何も書かずに止まる (exit 1)。先に commit するか、
    戻してから流し直す。git の checkout か確かめられないときも止まる
````

new_string:

````text
  - repo 側 (`win/google-japanese-input/` の `config.txtpb`・`keymap.tsv`・`romaji.tsv` と dotfiles-private の辞書) に
    commit していない変更 (未追跡のファイルも) があると、変わったファイル名を出して何も書かずに止まる (exit 1)。
    先に commit するか、戻してから流し直す。git の checkout か確かめられないときも止まる。同じディレクトリの
    `Install-GoogleJapaneseInput.ps1` の変更では止まらない (版を上げる途中でも取り込めるように)
````

**W6** — Google 日本語入力の節の `### pjp-google-ime` の前に「Google 日本語入力を入れる (winget)」と「Install-GoogleJapaneseInput.ps1 を書くときの注意」。old_string:

````text
- テキストは画面のエクスポートと同じ形なので、仕組みが動かないときも、GUI の「インポート」で手で戻せる

### pjp-google-ime
````

new_string:

````text
- テキストは画面のエクスポートと同じ形なので、仕組みが動かないときも、GUI の「インポート」で手で戻せる

### Google 日本語入力を入れる (winget)

Google 日本語入力は winget の `Google.JapaneseIME` (machine スコープの MSI。入れる・上げるときは Windows のデスクトップに
UAC の確認が出る) で入れ、版を `google-japanese-input/Install-GoogleJapaneseInput.ps1` の `-Version` の既定値
(今は `3.34.6260.0`) の 1 か所で固定する。設定 (`config.txtpb`) を読み書きできると確かめた版に留めるため
([ADR 017](../docs/adr/017_win_apps_winget_20261012T115007JST/README.md)、[TKT-143](https://app.notion.com/p/winget-Windows-Google-PowerToys-Google-dotfiles-3f779149a66f817a8944c9e4e460383f))。

| 打つもの | すること |
| --- | --- |
| `Install-GoogleJapaneseInput -Check` (PowerShell) | 差を出すだけ。揃っていれば終了コード 0、差があれば 1、入っていなければ 3 |
| `Install-GoogleJapaneseInput` (PowerShell) | 揃える (入れる・上げる・pin を足す)。入れる・上げるときは UAC の確認が出る |
| `nix/scripts/bootstrap-windows-google-ime-install.sh` (WSL) | `setup --update` でも毎回走る (order 95)。入っていなければ入れ (UAC の確認が出る)、差があれば ⚠ で囲んで知らせる (上げはしない) |
| `nix/scripts/bootstrap-windows-google-ime-install.sh --apply` (WSL) | WSL から揃える。UAC の確認は Windows のデスクトップに出る |

- 版は `GoogleIMEJaConverter.exe` の ProductVersion で読む。`C:\Program Files\` と `C:\Program Files (x86)\` の
  `Google\Google Japanese Input\` の両方を見る (この PC の 2.29 は x86 の方。3.34 の MSI は x64)
- 上げるのは setup からはしない。日本語入力は全部のアプリに読み込まれていて、入れ替えるとアプリや Windows の
  再起動が要ることがあるため。上げる前に、日本語入力を使っているアプリをできるだけ閉じる。上げた後も `-Check` が
  古い版を出すなら、Windows を再起動してからもう一度 `-Check` で確かめる
- 入れた後と上げた後に `winget pin add` で `winget upgrade --all` から外す (上げるときは先に pin を外し、上げた後に足し直す)
- 入っている版の方が新しい (Google 日本語入力が自分で上がった) ときは下げない。`-Check` と setup が ⚠ で知らせ続けるので、
  下の「版を上げる」で repo の版を追いつかせる
- setup が入れるときに UAC を押さないまま 600 秒たつと、⚠ と手で打つコマンドを出して先へ進む

新しいマシンでは setup を 2 回流す (98 の置き先は、Google 日本語入力を初めて使ったときにできるため):

1. `~/dotfiles/setup --update` を流す。UAC の確認が出たら「はい」を押す
2. Google 日本語入力で一度何か打つ (入力方式が別なら切り替えてから)
3. もう一度 `~/dotfiles/setup --update` を流す。`bootstrap-windows-google-ime.sh` が設定と辞書を置く

版を上げる:

1. `Install-GoogleJapaneseInput.ps1` の `-Version` の既定値を、`winget show --id Google.JapaneseIME --versions` にある新しい版にする
2. この PC で `Install-GoogleJapaneseInput` を打って揃え、`nix/scripts/bootstrap-windows-google-ime.sh --dry-run` と
   `--import` で設定を読み書きできるかを見る (`--import` は `Install-GoogleJapaneseInput.ps1` の変更では止まらない)
3. `--import` が「今の .proto に無い項目がある」で止まったら、`nix/pkgs/pjp-google-ime/proto/` の写しを新しくする
   ([pjp-google-ime](#pjp-google-ime))
4. commit して `~/dotfiles/setup --update` を流し、`bootstrap-windows-google-ime-install.sh` が 1 行で終わることを見る

### Install-GoogleJapaneseInput.ps1 を書くときの注意

- `dotfiles.ps1` と同じく **BOM 付きの UTF-8** で保存する
- 副作用の無い関数 (版の読み方・探す場所・plan・winget の引数・状態の表・流れ) は
  `google-japanese-input/Install-GoogleJapaneseInput.Tests.ps1` で確かめる。Linux の pwsh で流すので Windows には触らない
  (このファイルは manifest に無いので配られない):

  ```sh
  nix shell nixpkgs#powershell -c pwsh -NoProfile -File win/google-japanese-input/Install-GoogleJapaneseInput.Tests.ps1
  ```

- winget やファイルに触る部分は、実機で `-Check` と本番を打って確かめる

### pjp-google-ime
````

- [ ] **Step 2: `nix/README.md`**

**N1** — 「bootstrap の実行順」の表: 91 の行を直し、95 の行を足す。old_string:

````text
| `bootstrap-windows-powertoys.sh` | 91 | `bootstrap-windows-files.sh` が置いた PowerToys の `default.json` を Keyboard Manager に読み直させる (exit 1 にしない) |
| `bootstrap-windows-powershell-profile.sh` | 95 | `bootstrap-windows-files.sh` が置いた `dotfiles.ps1` を `$PROFILE` から読ませる |
````

new_string:

````text
| `bootstrap-windows-powertoys.sh` | 91 | `bootstrap-windows-files.sh` が置いた `Install-PowerToys.ps1` で PowerToys が入っているかを確かめ (無ければ入れる)、置いた `default.json` を Keyboard Manager に読み直させる (exit 1 にしない) |
| `bootstrap-windows-google-ime-install.sh` | 95 | `bootstrap-windows-files.sh` が置いた `Install-GoogleJapaneseInput.ps1` で、Windows の Google 日本語入力が固定した版に揃っているかを確かめる (入っていなければ入れる。UAC の確認が出る。上げはしない)。設定を置く `bootstrap-windows-google-ime.sh` (98) より先に走る。`bootstrap-windows-powershell-profile.sh` と同じ 95 で、同じ値は辞書順なのでこちらが先 (どちらも相手を使わない) |
| `bootstrap-windows-powershell-profile.sh` | 95 | `bootstrap-windows-files.sh` が置いた `dotfiles.ps1` を `$PROFILE` から読ませる |
````

**N2** — 「新規マシンの手順」の表: 6.8.1 を直し、6.8.2 を足す。old_string:

````text
| 6.8.1 | `./nix/scripts/bootstrap-windows-powertoys.sh` | `bootstrap-windows-powertoys` | 配った PowerToys の割り当てを Keyboard Manager に読み直させる（[`win/README.md`](../win/README.md#powertoys)） |
````

new_string:

````text
| 6.8.1 | `./nix/scripts/bootstrap-windows-powertoys.sh` | `bootstrap-windows-powertoys` | PowerToys が入っていなければ winget で入れ、配った割り当てを Keyboard Manager に読み直させる（[`win/README.md`](../win/README.md#powertoys-を入れる-winget)） |
| 6.8.2 | `./nix/scripts/bootstrap-windows-google-ime-install.sh` | `bootstrap-windows-google-ime-install` | Windows の Google 日本語入力が固定した版に揃っているかを確かめる（無ければ入れる。UAC の確認が出る。上げはしない。[`win/README.md`](../win/README.md#google-日本語入力を入れる-winget)） |
````

**N3** — 「新規マシンの手順」の表: 6.11.1 に新しいマシンのことを足す。old_string:

````text
| 6.11.1 | `./nix/scripts/bootstrap-windows-google-ime.sh` | `bootstrap-windows-google-ime` | Google 日本語入力の設定とユーザー辞書を、テキストから組み立てて配る（[`win/README.md`](../win/README.md#google-日本語入力)） |
````

new_string:

````text
| 6.11.1 | `./nix/scripts/bootstrap-windows-google-ime.sh` | `bootstrap-windows-google-ime` | Google 日本語入力の設定とユーザー辞書を、テキストから組み立てて配る。新しいマシンでは置き先が Google 日本語入力を一度使うまで無いので、使ってから setup を流し直す（[`win/README.md`](../win/README.md#google-日本語入力を入れる-winget)） |
````

**N4** — 「Windows 側のファイルを配る」の反映のコマンド。old_string:

````text
./nix/scripts/bootstrap-windows-powertoys.sh         # 配った PowerToys の割り当てを Keyboard Manager に読み直させる部分だけ
````

new_string:

````text
./nix/scripts/bootstrap-windows-powertoys.sh         # PowerToys が無ければ入れ、配った割り当てを Keyboard Manager に読み直させる部分だけ
./nix/scripts/bootstrap-windows-google-ime-install.sh  # Google 日本語入力が固定した版かを確かめる部分だけ（無ければ入れる。--apply で揃える）
````

**N5** — 「Windows 側のファイルを配る」の箇条に、2 つのアプリの本体のことを足す。old_string:

````text
  コマンドを出して exit 0。配る経路 (コピー) には exe を挟まない（[`win/README.md`](../win/README.md#powershell)）
````

new_string:

````text
  コマンドを出して exit 0。配る経路 (コピー) には exe を挟まない（[`win/README.md`](../win/README.md#powershell)）
- PowerToys と Google 日本語入力の本体は、`bootstrap-windows-powertoys.sh` (order 91) と
  `bootstrap-windows-google-ime-install.sh` (order 95) が、配った `Install-PowerToys.ps1`・
  `Install-GoogleJapaneseInput.ps1` を `pwsh.exe` で呼び、入っていなければ winget で入れる。Google 日本語入力は
  版を固定し、ずれは ⚠ で知らせるだけ (上げるのは手で打つ。UAC の確認が出る)。PowerToys は版を固定しない
  （[`win/README.md`](../win/README.md#google-日本語入力を入れる-winget)、[ADR 017](../docs/adr/017_win_apps_winget_20261012T115007JST/README.md)）
````

**N6** — 「テスト」の表: 98 と 91 の行を直し、95 の行を足す。old_string:

````text
| `bootstrap-windows-google-ime.test.sh` | 組み立てて配る判定 (飛ばす・interop が無い・設定画面が開いている・壊れたテキスト・置く・同じ・時刻だけ違う・repo 側が進んだ・衝突・`--dry-run` / `--import` / `--force` / `--check`・読めないファイル・辞書が無い・退避の間引き・taskkill の 128・落とし直しの印・`--import` と commit していない変更・単語登録の形の辞書・辞書の衝突で語を出さない・`--show-words`)。偽の `tasklist.exe` と `taskkill.exe` で流し、偽の repo と dotfiles-private は git の checkout にする（34 件） | `bootstrap-windows-google-ime-test`（Linux） |
| `bootstrap-windows-powertoys.test.sh` | Keyboard Manager に読み直させる判定 (飛ばす・送れた・同じなら送らない・`--force`・動いていない・interop が無い)。偽の `powershell.exe` で流す（12 件） | `bootstrap-windows-powertoys-test`（Linux） |
````

new_string:

````text
| `bootstrap-windows-google-ime.test.sh` | 組み立てて配る判定 (飛ばす・interop が無い・設定画面が開いている・壊れたテキスト・置く・同じ・時刻だけ違う・repo 側が進んだ・衝突・`--dry-run` / `--import` / `--force` / `--check`・読めないファイル・辞書が無い・退避の間引き・taskkill の 128・落とし直しの印・`--import` と commit していない変更・単語登録の形の辞書・辞書の衝突で語を出さない・`--show-words`・入っているがまだ使っていない・`--import` と `Install-GoogleJapaneseInput.ps1` の変更)。偽の `tasklist.exe` と `taskkill.exe` で流し、偽の repo と dotfiles-private は git の checkout にする（37 件） | `bootstrap-windows-google-ime-test`（Linux） |
| `bootstrap-windows-google-ime-install.test.sh` | Google 日本語入力の版を確かめる判定 (飛ばす・手で打つ案内・揃っている・差がある・入っている版の方が新しい・入っていなければ UAC を知らせて入れる・入れられない・時間切れ・`--apply`・実行ビット・jq が無い)。偽の `pwsh.exe` と `wslpath` で流す（25 件） | `bootstrap-windows-google-ime-install-test`（Linux） |
| `bootstrap-windows-powertoys.test.sh` | Keyboard Manager に読み直させる判定 (飛ばす・送れた・同じなら送らない・`--force`・動いていない・interop が無い) と、その前に PowerToys が入っているかを確かめる判定 (入っている・無ければ入れる・入れられない・スクリプトや `pwsh.exe` が無い・読み直し済みでも確かめる・実行ビット)。偽の `powershell.exe`・`pwsh.exe`・`wslpath` で流す（23 件） | `bootstrap-windows-powertoys-test`（Linux） |
````

**N7** — 「ディレクトリ」の木: 91 の行を直し、95 の行を足す。old_string:

````text
    ├── bootstrap-windows-powertoys.sh  win/ から配った PowerToys の割り当てを Keyboard Manager に読み直させる (冪等。更新時も毎回走る)
````

new_string:

````text
    ├── bootstrap-windows-powertoys.sh  win/ から配った PowerToys の割り当てを Keyboard Manager に読み直させる (冪等。更新時も毎回走る。PowerToys が無ければ先に入れる)
    ├── bootstrap-windows-google-ime-install.sh  Windows の Google 日本語入力が固定した版に揃っているかを確かめる (冪等。更新時も毎回走る。無ければ入れ、上げはしない)
````

- [ ] **Step 3: `docs/adr/017_win_apps_winget_20261012T115007JST/README.md`**

**A1** — 決定 C に `--import` の確かめのことを足す (Task 6 の後半を採らないときは飛ばす)。old_string:

````text
- ディレクトリを先に作って置くことはしない。Google 日本語入力が作るときの権限と揃わないおそれがある
````

new_string:

````text
- ディレクトリを先に作って置くことはしない。Google 日本語入力が作るときの権限と揃わないおそれがある
- `--import` が commit していない変更を確かめるのは、取り込みが書き換える `config.txtpb`・`keymap.tsv`・`romaji.tsv` だけにする。同じディレクトリに置く `Install-GoogleJapaneseInput.ps1` の変更で止まると、§7 の「版を上げる」(`-Version` を変えてから、commit する前に `--import` で確かめる) が通らないため
````

**A2** — §3 の 98 の行。old_string:

````text
| `nix/scripts/bootstrap-windows-google-ime.sh` | 入っているが使っていないときの案内 |
````

new_string:

````text
| `nix/scripts/bootstrap-windows-google-ime.sh` | 入っているが使っていないときの案内。`--import` の、commit していない変更の確かめを 3 つのテキストに絞る (決定 C) |
````

**A3** — §3 の README の行。old_string:

````text
| `win/README.md`・`nix/README.md` | 使い方・bootstrap の実行順・新しいマシンの手順・テストの表 |
````

new_string:

````text
| `win/README.md`・`nix/README.md` | 使い方 (「Google 日本語入力を入れる」「PowerToys を入れる」と、スクリプトを書くときの注意)・bootstrap の実行順・新しいマシンの手順・テストの表・ディレクトリの木 |
````

**A4** — §3 に ADR 015 の行を足す。old_string:

````text
| `docs/adr/README.md` | 一覧に 017 を足す |
````

new_string:

````text
| `docs/adr/README.md` | 一覧に 017 を足す |
| `docs/adr/015_win_google_ime_powertoys_20261011T234247JST/README.md` | 冒頭の表に後続 ADR (この ADR) の行。§7「新しいマシン」を今の形に (本文の決定はそのまま) |
````

- [ ] **Step 4: `docs/adr/015_win_google_ime_powertoys_20261011T234247JST/README.md`**

**B1** — 冒頭の表に後続 ADR の行を足す。old_string:

````text
| 運用手順 | [`win/README.md`「Google 日本語入力」「PowerToys」](../../../win/README.md)、[`nix/README.md`「bootstrap の実行順」](../../../nix/README.md#bootstrap-の実行順) |
````

new_string:

````text
| 運用手順 | [`win/README.md`「Google 日本語入力」「PowerToys」](../../../win/README.md)、[`nix/README.md`「bootstrap の実行順」](../../../nix/README.md#bootstrap-の実行順) |
| 後続 ADR | [017_win_apps_winget](../017_win_apps_winget_20261012T115007JST/README.md)（2 つのアプリの本体を、setup の中で winget から入れるようにした。**「7. 移行・運用手順」の「新しいマシン」は現行の形に更新済み。**本文の決定はそのまま） |
````

**B2** — §7「新しいマシン」の 1 つ目の箇条を今の形に。old_string:

````text
- Google 日本語入力と PowerToys は手で入れる (この ADR の範囲の外)
````

new_string:

````text
- Google 日本語入力と PowerToys は、setup が winget で入れる ([ADR 017](../017_win_apps_winget_20261012T115007JST/README.md))。Google 日本語入力の置き先は一度使うまで無いので、何か打ってから setup をもう一度流す
````

- [ ] **Step 5: 確かめる**

Run: `grep -c 'bootstrap-windows-google-ime-install' nix/README.md win/README.md`
Expected: `nix/README.md:6` と `win/README.md:3`

Run: `grep -n '^### ' win/README.md | grep -E 'PowerToys を入れる|Google 日本語入力を入れる|Install-PowerToys.ps1|Install-GoogleJapaneseInput.ps1'`
Expected: 4 行 (`### PowerToys を入れる (winget)`・`### Install-PowerToys.ps1 を書くときの注意`・`### Google 日本語入力を入れる (winget)`・`### Install-GoogleJapaneseInput.ps1 を書くときの注意`)

Run: `git diff --stat`
Expected: 4 つの README.md だけが変わっている。

- [ ] **Step 6: Commit**

```bash
git add win/README.md nix/README.md docs/adr/017_win_apps_winget_20261012T115007JST/README.md docs/adr/015_win_google_ime_powertoys_20261011T234247JST/README.md
git commit -F - <<'EOF'
docs: Google 日本語入力と PowerToys を winget で入れる手順を README に書き、ADR 015・017 を実装に合わせる (TKT-143)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01YSF6gCGyvBHzRBtjbB61Fm
EOF
```

---

### Task 8: 実機で確かめ、ADR 017 の検証の表を埋める (ユーザーと一緒に進める)

subagent には任せない。Windows 側に書き、Google 日本語入力を上げ (UAC)、変換サーバーを落とし、ユーザーに日本語を打ってもらうため。始める前に、次の Step 1 の内容をユーザーに伝えて許可を取る。ユーザー辞書の語は出さない (98 の辞書の差は件数だけ。`--show-words` は付けない。dotfiles-private の `git diff` は `--stat` だけ)。

**Files:**
- Modify: `docs/adr/017_win_apps_winget_20261012T115007JST/README.md` (§6 の「実装で確かめること」の結果の列)
- Modify (差が出たときだけ): `win/google-japanese-input/config.txtpb`・`keymap.tsv`

- [ ] **Step 1: ユーザーに伝えて許可を取る**

伝えること: (1) `/mnt/c/Users/polle/.config/powershell/` に 2 つのスクリプトを置き、`dotfiles.ps1` を上書きする、(2) 91 と 95 を流す (PowerToys は入っているので入れない。Google 日本語入力は差を知らせるだけ)、(3) ユーザーに PowerShell で `Install-GoogleJapaneseInput` を打ってもらう (UAC の確認が出る。日本語入力を使っているアプリはできるだけ閉じる。再起動が要ることがある)、(4) 98 を流して変換サーバーを落とし、句読点を変えて効くかを見る (打ってもらう)。

- [ ] **Step 2: スクリプトを配る**

Run: `nix/scripts/bootstrap-windows-files.sh --dry-run`
Expected: `[dry-run] コピー: /mnt/c/Users/polle/.config/powershell/Install-GoogleJapaneseInput.ps1`・`[dry-run] コピー: /mnt/c/Users/polle/.config/powershell/Install-PowerToys.ps1`・`[dry-run] 上書き (repo 側が更新された): /mnt/c/Users/polle/.config/powershell/dotfiles.ps1`、最後の行が `[dry-run] コピー 2 / 上書き 1 / 同じ 6 / 衝突 0` (2026-10-12 の時点ではほかの 6 件は「同じです」。違う行が出たら、この PR と関係の無い変更なのでユーザーに確かめてから進む)。

Run: `nix/scripts/bootstrap-windows-files.sh`
Expected: 上の 3 件を置き、manifest の hint (`PowerShell で Install-GoogleJapaneseInput -Check を打つと…` など) が出る。終了コード 0。

- [ ] **Step 3: 91 は入れずに今までどおり読み直させる**

Run: `nix/scripts/bootstrap-windows-powertoys.sh; echo "rc=$?"`
Expected: 1 行目が `PowerToys は入っています。`、続いて `Keyboard Manager は、今の default.json を読み直し済みです。` か `Keyboard Manager に default.json を読み直させました。`、`rc=0`。winget は打たない。

表そのものも 1 回見ておく (何も変えない):

Run: `bash -c 'pwsh.exe -NoProfile -NonInteractive -File "$(wslpath -w /mnt/c/Users/polle/.config/powershell/Install-PowerToys.ps1)" -Check </dev/null | tr -d "\r"; echo "rc=${PIPESTATUS[0]}"'`
Expected: `  入っている場所 : C:\Users\polle\AppData\Local\PowerToys\PowerToys.exe`・`  入っている版   : 0.100.2.0` (PowerToys が自分で上がっていれば新しい版)・`入っている`・`rc=0`。

- [ ] **Step 4: 95 が 2.29 と 3.34 のずれを ⚠ で出す**

Run: `nix/scripts/bootstrap-windows-google-ime-install.sh; echo "rc=$?"`
Expected (色は端末なら黄色。pin を前から足していれば `winget pin      : あり`):

```text
⚠️ ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ ⚠️
⚠️  Windows の Google 日本語入力が、dotfiles で固定した版と揃っていません
⚠️ ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ ⚠️
    Google 日本語入力 (winget の Google.JapaneseIME)
      入っている版    : 2.29.5370.0 (C:\Program Files (x86)\Google\Google Japanese Input)
    ⚠ 固定した版      : 3.34.6260.0 → 上げる
      winget の最新版 : 3.34.6260.0
    ⚠ winget pin      : 無し → 足す
⚠️  揃えるには次のどちらかを打つ (入れる・上げるときは Windows に UAC の確認が出ます。上げる前に、日本語入力を使っているアプリをできるだけ閉じる):
⚠️    WSL:        /home/pollenjp/.herdr/worktrees/dotfiles/worktree-calm-stone-6931/nix/scripts/bootstrap-windows-google-ime-install.sh --apply
⚠️    PowerShell: Install-GoogleJapaneseInput
⚠️ ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ ⚠️
rc=0
```

上げはしない (pwsh.exe は `-Check` で 1 回だけ呼ばれる)。

- [ ] **Step 5: ユーザーに揃えてもらう (UAC)**

ユーザーに頼む: 日本語入力を使っているアプリをできるだけ閉じ、PowerShell 7 で `. $PROFILE` (新しい `dotfiles.ps1` を読み直す) のあと `Install-GoogleJapaneseInput` を打ち、UAC の確認で「はい」を押す。

Expected (ユーザーの画面): 状態の表、`上げる前に、日本語入力を使っているアプリをできるだけ閉じる …`、`Windows のデスクトップに UAC の確認が出る。「はい」を押す`、`winget upgrade --id Google.JapaneseIME --exact --source winget --silent --accept-source-agreements --disable-interactivity --version 3.34.6260.0 --accept-package-agreements`、`winget pin を足した (winget upgrade --all から外れる)`、読み直した表の `入っている版    : 3.34.6260.0 (C:\Program Files\Google\Google Japanese Input)` (x86 の方なら `(x86)`)、最後に `揃った`。

`版が揃っていない。使用中のファイルが Windows の再起動待ちになったなら …` が出たら、ユーザーに Windows を再起動してもらい、PowerShell で `Install-GoogleJapaneseInput -Check` を打ってもらう。`winget upgrade` が失敗したら、出た終了コードと最後の 5 行をユーザーと見る。次に、ユーザーに PowerShell で `winget upgrade --id Google.JapaneseIME --exact --source winget --version 3.34.6260.0` (`--silent` を付けない。installer の画面とエラーの文面が見える) を打ってもらい、出たものを見て進め方を決める。入った場所 (x64 / x86) と、再起動が要ったかを控える (Step 9 で書く)。

- [ ] **Step 6: 上げた後の 95 は 1 行**

Run: `nix/scripts/bootstrap-windows-google-ime-install.sh; echo "rc=$?"`
Expected: `Windows の Google 日本語入力は、dotfiles で固定した版に揃っています。` と `rc=0`。

- [ ] **Step 7: 98 が 3.34 の設定と辞書を読み書きできる**

Run: `nix shell ./nix#pjp-google-ime --command nix/scripts/bootstrap-windows-google-ime.sh --dry-run; echo "rc=$?"`
Expected: `同じです: …/config1.db`・`同じです: …/user_dictionary.db`・`rc=0`。3.34 が設定を書き直して衝突になったら、設定の diff (`--- Windows 側/config.txtpb`) をユーザーと見る (辞書は件数の行だけが出る)。

Run: `nix shell ./nix#pjp-google-ime --command nix/scripts/bootstrap-windows-google-ime.sh --import; echo "rc=$?"`
Expected: `取り込みました。…` と `rc=0` (3.34 の `config1.db` と `user_dictionary.db` を、今の .proto で読めた。「今の .proto に無い項目がある」で止まったら、win/README.md の「版を上げる」の 3 の手順をユーザーと進める)。

Run: `git status --short win/google-japanese-input; git -C ~/ghq/github.com/pollenjp/dotfiles-private status --short`
Expected: どちらも何も出ない (取り込んでもテキストは変わらない)。出たら `git diff win/google-japanese-input` をユーザーと見て (dotfiles-private は `git -C … diff --stat` だけ)、残すなら commit する (`fix(win): Google 日本語入力 3.34 が書き直した設定を取り込む (TKT-143)`。dotfiles-private の commit はユーザーが自分の端末で diff を見てから)。

- [ ] **Step 8: 句読点を変えて配ると効く**

`win/google-japanese-input/config.txtpb` の `punctuation_method: TOUTEN_KUTEN` を `punctuation_method: COMMA_PERIOD` に替える (commit しない)。

Run: `nix shell ./nix#pjp-google-ime --command nix/scripts/bootstrap-windows-google-ime.sh; echo "rc=$?"`
Expected: `上書き (repo 側が進んだ): …/config1.db`、退避の行、`変換サーバー (GoogleIMEJaConverter.exe) を落としました。…`、`rc=0`。

ユーザーに、日本語入力で「、。」を打つと「，．」になることを確かめてもらう。そのあと `punctuation_method` を `TOUTEN_KUTEN` に戻し (`git diff win/google-japanese-input` が空になることを先に見る)、もう一度流して、「、。」に戻ったことを確かめてもらう。

- [ ] **Step 9: ADR 017 §6 の「実装で確かめること」の結果の列を埋める**

`docs/adr/017_win_apps_winget_20261012T115007JST/README.md` の §6 の 2 つ目の表で、`—` を実際に出たもので置き換える。見込み (違ったら出たとおりに書く):

| 確認 | 結果に書くこと |
| --- | --- |
| 副作用の無い関数 | `Install-GoogleJapaneseInput.Tests.ps1` 87 件・`Install-PowerToys.Tests.ps1` 29 件、すべて通過 |
| bootstrap | Google 日本語入力の版 29 件・PowerToys 29 件・Google 日本語入力の設定 41 件、すべて通過 |
| 静的 | 指摘なし |
| 実機: 91 | 「PowerToys は入っています。」のあと読み直し (rc 0)。winget は打たなかった |
| 実機: 95 のずれ | ⚠ の枠に「2.29.5370.0 (C:\Program Files (x86)\…)」「3.34.6260.0 → 上げる」「pin 無し」が出た (rc 0) |
| 実機: 揃える | Step 5 の結果 (upgrade と pin、入った場所、再起動が要ったか)。上げた後の 95 は「揃っています」の 1 行 |
| 実機: 上げた後の設定 | Step 7・8 の結果 (`--dry-run` は「同じです」か衝突か、`--import` が通ったか、「，．」になり戻すと「、。」) |

「新しいマシン」の行は `まだ (次の新しいマシンで確かめる)` のまま。表の上の「実装で確かめること (実装の PR で結果を埋める)。」は「実装で確かめたこと (2026-10-12、TKT-143 の PR。実機はこの PC)。」に替える。

- [ ] **Step 10: Commit**

```bash
git add docs/adr/017_win_apps_winget_20261012T115007JST/README.md
git commit -F - <<'EOF'
docs(adr): ADR 017 の検証に、実装の結果と実機で確かめたことを書く (TKT-143)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01YSF6gCGyvBHzRBtjbB61Fm
EOF
```

---

### Task 9: 全体を確かめて PR を出す (ユーザーと一緒に進める)

- [ ] **Step 1: 全体の check を流す**

Run: `nix flake check --all-systems --no-build ./nix 2>&1 | tail -2`
Expected: error が無い (最後の `warning: … unchecked` は前からある)。

Run: `nix build --no-link './nix#checks.x86_64-linux.bootstrap-windows-google-ime-install-test' './nix#checks.x86_64-linux.bootstrap-windows-powertoys-test' './nix#checks.x86_64-linux.bootstrap-windows-google-ime-test' && for c in bootstrap-windows-google-ime-install-test bootstrap-windows-powertoys-test bootstrap-windows-google-ime-test; do nix log "./nix#checks.x86_64-linux.${c}" 2>/dev/null | grep '== [0-9]'; done`
Expected: `== 29 passed, 0 failed`・`== 29 passed, 0 failed`・`== 41 passed, 0 failed` (build が通れば全部通っている。`nix log` は前に作った check の log も出す)。

Run: `nix shell nixpkgs#powershell -c pwsh -NoProfile -File win/google-japanese-input/Install-GoogleJapaneseInput.Tests.ps1 | tail -1; nix shell nixpkgs#powershell -c pwsh -NoProfile -File win/powertoys/Install-PowerToys.Tests.ps1 | tail -1`
Expected: `すべて通った` が 2 行。

Run: `nix develop ./nix --command bash -c 'set -uo pipefail; mapfile -t files < <(find nix -type f -name "*.sh" | sort); rc=0; shfmt -d "${files[@]}" || rc=1; shellcheck "${files[@]}" || rc=1; find nix -name "*.nix" -print0 | xargs -0 nixfmt --check || rc=1; echo "lint rc=${rc}"'`
Expected: `lint rc=0` (CI の lint と同じ)。

Run: `nix/scripts/bootstrap-windows-files.sh --check && nix shell ./nix#pjp-google-ime --command ./nix/scripts/bootstrap-windows-google-ime.sh --check && nix/scripts/check-herdr-keys.sh`
Expected: `win/manifest.toml: OK (9 件)`、`OK: …/win/google-japanese-input …`、herdr のキーが同じという行。

Run: `bash -c 'for f in win/google-japanese-input/*.ps1 win/powertoys/*.ps1 win/powershell/dotfiles.ps1; do printf "%s %s\n" "$(head -c3 "$f" | od -An -tx1 | tr -d " ")" "$f"; done'; git ls-files -s nix/scripts/bootstrap-windows-google-ime-install.sh nix/scripts/bootstrap-windows-powertoys.sh | cut -c1-6`
Expected: 5 行とも `efbbbf …`、mode は 2 行とも `100755`。

- [ ] **Step 2: この plan を commit する**

```bash
git add docs/superpowers/plans/2026-10-12-winget-ime-powertoys.md
git commit -F - <<'EOF'
docs: TKT-143 の実装計画を docs/superpowers/plans/ に置く (TKT-143)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01YSF6gCGyvBHzRBtjbB61Fm
EOF
```

- [ ] **Step 3: push して PR を作る**

ユーザーに確かめてから push する (Claude の git は gh の HTTPS で通る)。PR の本文の 1 行目はチケットの URL (`~/.claude/skills/pjp-dev-tracker/scripts/ticket.sh show TKT-143 --url` の出力。ADR の冒頭のリンクと同じはず)。

```bash
git push -u origin feat/TKT-143-winget-ime-powertoys
url=$(~/.claude/skills/pjp-dev-tracker/scripts/ticket.sh show TKT-143 --url)
gh pr create --base main --title "TKT-143 Google 日本語入力と PowerToys を setup の中で winget から入れる" --body-file - <<EOF
${url}

## 変更

- \`win/google-japanese-input/Install-GoogleJapaneseInput.ps1\` (新規): Google 日本語入力 (winget の \`Google.JapaneseIME\`) を \`3.34.6260.0\` に揃える (入れる・上げる・pin)。\`-Check\` は 0 / 1 / 3
- \`win/powertoys/Install-PowerToys.ps1\` (新規): PowerToys が無ければ user スコープで入れる (版は固定しない)
- \`nix/scripts/bootstrap-windows-google-ime-install.sh\` (新規、order 95): setup のたびに版を確かめ、無ければ入れる (UAC の確認が出る)。ずれは ⚠ で知らせ、上げるのは手で (\`--apply\` か PowerShell の \`Install-GoogleJapaneseInput\`)
- \`nix/scripts/bootstrap-windows-powertoys.sh\` (91): 読み直させる前に、PowerToys が無ければ入れる
- \`nix/scripts/bootstrap-windows-google-ime.sh\` (98): 入っているがまだ使っていないときに、一度使ってから流し直すよう案内する。\`--import\` の commit していない変更の確かめを、取り込みが書き換える 3 つのテキストに絞る
- \`win/manifest.toml\`・\`win/powershell/dotfiles.ps1\`・\`nix/flake.nix\`・README・ADR 015 / 017

## 確かめたこと

- PowerShell のテスト (Linux の pwsh): \`Install-GoogleJapaneseInput.Tests.ps1\` 87 件・\`Install-PowerToys.Tests.ps1\` 29 件
- bootstrap のテスト (flake の checks): 29 件・29 件・41 件
- 実機 (この PC): ADR 017 §6 の表

理由と採らなかった案は ADR 017。

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01YSF6gCGyvBHzRBtjbB61Fm
EOF
```

Expected: PR の URL が出る。

- [ ] **Step 4: チケットに結ぶ**

Run: `~/.claude/skills/pjp-dev-tracker/scripts/ticket.sh pr TKT-143 && ~/.claude/skills/pjp-dev-tracker/scripts/ticket.sh link TKT-143 "$(gh pr view --json url -q .url)" "PR"`
Expected: PR 列に 1 行足され、Status が PR に合わせて変わる (`ticket.sh pr` はこの作業ツリーの branch で PR を引く)。

`pjp-video-explainer-offer` が skill の一覧にあれば読み、解説動画を作るかをユーザーに聞く (`~/.claude/CLAUDE.md` の「解説動画を作るか聞く」)。

- [ ] **Step 5: merge の後にユーザーが打つものを伝える**

`~/dotfiles/setup --update` (main の `win/` から配り直す。95 は「揃っています」の 1 行、91 は「PowerToys は入っています。」のあと読み直し)。新しいマシンでは setup を 2 回流す (win/README.md の「Google 日本語入力を入れる」)。次の新しいマシンで、ADR 017 §6 の「新しいマシン」の行 (`-IfMissing` で 2 つが入る・2 回で揃う・Keyboard Manager が置いた割り当てを読む) を確かめる。
