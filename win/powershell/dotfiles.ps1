# dotfiles の win/powershell/dotfiles.ps1 から配る、PowerShell の共有設定。
# $PROFILE から dot-source で読む (読み込み方は win/README.md の「PowerShell」)。
#
# BOM 付きの UTF-8 で保存すること。Windows PowerShell 5.1 は BOM の無い UTF-8 を
# CP932 として読み、日本語コメントの次の行を黙って読み飛ばすことがある。

# e でシェルを抜ける。WSL の fish の abbr (nix/home/modules/fish.nix) と bash の alias
# (nix/home/modules/bash.nix) の e と同じ。下の略語の表 ($DotfilesAbbr) にも同じ中身で置く。
# exit はコマンドではなくキーワードなので、Set-Alias では指せない (e を打つと
# 「The term 'exit' is not recognized」になる)。function にすれば、プロンプトで打った
# e の中の exit がセッションを終わらせる。
function e { exit }

# herdr。WSL の fish の abbr (nix/home/modules/fish.nix) と bash の alias
# (nix/home/modules/bash.nix) と同じ名前・同じ中身にそろえる。下の略語の表 ($DotfilesAbbr) もそろえる。
#
# PowerShell の alias は引数を持てないので、h 以外は function にする。
# h は PowerShell 既定の alias (Get-History) と重なり、alias は function より先に
# 引かれるので Set-Alias で上書きする (履歴は ghy / history で引ける)。5.1 の既定の
# h には AllScope が付いていて、-Option AllScope を付けないと上書きできない。
Set-Alias -Name h -Value herdr -Option AllScope -Force
function hss { herdr --session @args }
function hls { herdr session list @args }
function ha { herdr session attach @args }
function hkill { herdr session stop @args }
function hdel { herdr session delete @args }
function hst { herdr status @args }
function hreload { herdr server reload-config @args }
function hsvstop { herdr server stop @args }
function hr { herdr --remote @args }

# Claude Code。WSL の fish の abbr と bash の alias の c、herdr-app の prefix の mod (win/herdr-app/mods/pjp-prefix/main.js の
# CLAUDE。worktree を作って Claude Code を起こす argv)、下の略語の表 ($DotfilesAbbr) の c と同じ中身にそろえる。
# Remote Control を有効にし、権限の確認を飛ばし、effort を max、モデルを Opus 5.5 に固定して
# claude.exe (Install-ClaudeCode が winget で入れたもの) を起動する。末尾の --remote-control に = で空の値を渡す理由は、fish.nix の同じ節に
# 書いてある。
function c { claude --dangerously-skip-permissions --effort max --model claude-opus-5-5 --remote-control= @args }

# claude のアカウント (素の claude と claude-<名前>)・権限・effort・モデル・Remote Control を矢印キーで段ごとに選び、組み立てた
# コマンド行を見せてから起こす (claude-selector.exe。runner の手順 claude-selector が nix/pkgs/claude-selector から作って
# %LOCALAPPDATA%\dotfiles\bin に置く)。Enter だけで進むと c から --remote-control= を外した中身になり、cs の後ろの引数は組み立てた
# 引数の後ろにそのまま付く。WSL の fish の abbr と bash の alias の cs、下の略語の表 ($DotfilesAbbr) の cs と同じ中身にそろえる。
function cs { claude-selector @args }

# 略語の展開 (WSL の fish の abbr に似せる)。上の e・h・hss … c・cs を、打った所 (入力行の中) で中身に広げてから実行する。
# 何をどこで広げるか・キー・fish との違いは win/README.md の「略語を広げる」。
#
# 表の中身は上の function・alias とそろえる (function の本体は「表の中身 @args」、h は alias の先、e は exit。
# win/powershell/dotfiles.Tests.ps1 が突き合わせる)。function と alias は消さない (script や PSReadLine の無い所でも今どおり動かす)。
# 大文字小文字を区別する (fish の abbr と同じ。@{} は区別しないので、Dictionary を Ordinal で作る)。
$DotfilesAbbr = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
$DotfilesAbbr.Add('e', 'exit')
$DotfilesAbbr.Add('h', 'herdr')
$DotfilesAbbr.Add('hss', 'herdr --session')
$DotfilesAbbr.Add('hls', 'herdr session list')
$DotfilesAbbr.Add('ha', 'herdr session attach')
$DotfilesAbbr.Add('hkill', 'herdr session stop')
$DotfilesAbbr.Add('hdel', 'herdr session delete')
$DotfilesAbbr.Add('hst', 'herdr status')
$DotfilesAbbr.Add('hreload', 'herdr server reload-config')
$DotfilesAbbr.Add('hsvstop', 'herdr server stop')
$DotfilesAbbr.Add('hr', 'herdr --remote')
$DotfilesAbbr.Add('c', 'claude --dangerously-skip-permissions --effort max --model claude-opus-5-5 --remote-control=')
$DotfilesAbbr.Add('cs', 'claude-selector')

# 入力行 $Line のカーソル $Cursor の直前で終わる語が、コマンドの名前の位置にあり表 $Table にあれば、置き換える所 (Start・Length) と
# 中身 (Text) を返す (広げないなら何も返さない)。コマンドの位置かは構文で見る: 行を PowerShell の Parser で読み、名前がカーソルの
# 位置で終わるコマンド (CommandAst) を探す。& と . で呼ぶ形 (& hr・. hr) は広げない。名前は打った字のまま表と比べるので、引用符で
# 囲んだ名前は広がらない。引数・変数・コメントはコマンドの名前でないので広げない。PSReadLine には触れない (dotfiles.Tests.ps1 が確かめる)。
function Get-DotfilesAbbrExpansion {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Line,
        [Parameter(Mandatory)][int]$Cursor,
        [Parameter(Mandatory)][System.Collections.Generic.Dictionary[string, string]]$Table
    )
    # カーソルの前が表の語で終わらなければ、構文を読まずに返す (カーソルで終わる名前が表の語になることはない)。貼り付けた長い行で、
    # 広げるきっかけのキーのたびに行全体を読まないため
    if ($Cursor -lt 1 -or $Cursor -gt $Line.Length) { return }
    $before = $Line.Substring(0, $Cursor)
    $endsWithAbbr = $false
    foreach ($abbr in $Table.Keys) {
        if ($before.EndsWith($abbr, [System.StringComparison]::Ordinal)) { $endsWithAbbr = $true; break }
    }
    if (-not $endsWithAbbr) { return }
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Line, [ref]$tokens, [ref]$errors)
    $command = $ast.Find({
            param($node)
            ($node -is [System.Management.Automation.Language.CommandAst]) -and
            ($node.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Unknown) -and
            ($node.CommandElements[0].Extent.EndOffset -eq $Cursor)
        }, $true)
    if ($null -eq $command) { return }
    $name = $command.CommandElements[0].Extent
    $text = $null
    if (-not $Table.TryGetValue($name.Text, [ref]$text)) { return }
    # 中身の頭がキーワード (e の exit) なら、広げた後の行でもキーワードとして読まれるときだけ広げる。| の後と ( の中 (7 では && || の
    # 後も) では、キーワードがコマンドの名前として読まれ (exit というコマンドは無いので落ちる)、function (e) を呼ぶときと動きが変わる。
    # 文字列の中の $( ) のトークンは、文字列のトークンの NestedTokens にある
    $afterTokens = $null
    $null = [System.Management.Automation.Language.Parser]::ParseInput($Line.Substring(0, $name.StartOffset) + $text + $Line.Substring($name.EndOffset), [ref]$afterTokens, [ref]$errors)
    $all = [System.Collections.Generic.List[System.Management.Automation.Language.Token]]::new($afterTokens)
    for ($i = 0; $i -lt $all.Count; $i++) {
        if ($all[$i] -is [System.Management.Automation.Language.StringExpandableToken] -and $all[$i].NestedTokens) { $all.AddRange($all[$i].NestedTokens) }
        if ($all[$i].Extent.StartOffset -eq $name.StartOffset -and
            [System.Management.Automation.Language.TokenTraits]::HasTrait($all[$i].Kind, [System.Management.Automation.Language.TokenFlags]::Keyword) -and
            -not ($all[$i].TokenFlags -band [System.Management.Automation.Language.TokenFlags]::Keyword)) { return }
    }
    [pscustomobject]@{ Start = $name.StartOffset; Length = $name.Text.Length; Text = $text }
}

# PSReadLine の入力行で、カーソルの直前の略語を広げる (下の割り当てから呼ぶ)。字を選んでいる間は広げない。
# 置き換えは 1 回の Undo (Ctrl+Z) で戻る。
function Invoke-DotfilesAbbrExpansion {
    $line = $null
    $cursor = $null
    [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
    $selectionStart = $null
    $selectionLength = $null
    [Microsoft.PowerShell.PSConsoleReadLine]::GetSelectionState([ref]$selectionStart, [ref]$selectionLength)
    if ($selectionLength -gt 0) { return }
    $expansion = Get-DotfilesAbbrExpansion -Line $line -Cursor $cursor -Table $DotfilesAbbr
    if ($null -ne $expansion) {
        [Microsoft.PowerShell.PSConsoleReadLine]::Replace($expansion.Start, $expansion.Length, $expansion.Text)
    }
}

# 割り当ては、PSReadLine を読み込んだ対話の PowerShell でだけする。script・CI (-File・-NonInteractive) の PowerShell は PSReadLine を
# 読み込まないので、割り当てずに抜ける (Get-Module は読み込まないが、Set-PSReadLineKeyHandler は打つと PSReadLine を読み込む)。
# 広げるところで落ちても、打ったキーの字を入れる・実行するところは流す (Space や Enter を打てなくしない)。
if (Get-Module -Name PSReadLine) {
    # Space ; | & ) は、広げてから打った字を入れる。fish の abbr は > と < でも広げるが、PowerShell では > が前の語にくっつき
    # (Write-Output x> $null は x> を出す)、広げると最後の語が変わる。< は PowerShell で使えない。どちらも割り当てない
    Set-PSReadLineKeyHandler -Chord 'Spacebar', ';', '|', '&', ')' -BriefDescription DotfilesAbbrExpandAndInsert -Description '略語を広げてから字を入れる (dotfiles.ps1)' -ScriptBlock {
        param($key, $arg)
        try { Invoke-DotfilesAbbrExpansion } catch { }
        [Microsoft.PowerShell.PSConsoleReadLine]::SelfInsert($key, $arg)
    }
    # Enter は、広げてから実行する
    Set-PSReadLineKeyHandler -Chord Enter -BriefDescription DotfilesAbbrExpandAndAcceptLine -Description '略語を広げてから実行する (dotfiles.ps1)' -ScriptBlock {
        param($key, $arg)
        try { Invoke-DotfilesAbbrExpansion } catch { }
        [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine($key, $arg)
    }
    # Ctrl+Space と Shift+Space は、広げずに空白を入れる (Ctrl+Space は fish の ctrl-space と同じ)。
    # Ctrl+Space は、端末が NUL の字で送ると (herdr・hc の端末・WSL から開いたとき) Ctrl+@ として届くので、Ctrl+Spacebar と Ctrl+@ の両方に
    # 割り当てる。PSReadLine の Ctrl+Space の補完メニュー (MenuComplete) は使えなくなる。
    # Shift+Space は、IME の切り替えに Ctrl+Space を割り当てた PC (Ctrl+Space を IME が先に取り、PowerShell に届かない) で使う。Windows Terminal・
    # conhost は Shift+Space を Shift 付きの Space のキーで送るので、ここに当たる (割り当てが無くても PSReadLine は字だけを入れて広げないが、
    # 割り当ててキーの一覧 (Get-PSReadLineKeyHandler) に出し、PSReadLine のその振る舞いに頼らない)。herdr・hc の端末は Shift+Space をただの
    # 空白の字で送るので、Shift の無い Space として届き、Space と同じに広がる。
    # 空白は Space のキーとして入れる (Space と同じく、選んだ字を置き換え、数引数 (Alt+3 など) の数だけ入れる)
    Set-PSReadLineKeyHandler -Chord 'Ctrl+Spacebar', 'Ctrl+@', 'Shift+Spacebar' -BriefDescription DotfilesAbbrInsertSpace -Description '略語を広げずに空白を入れる (dotfiles.ps1)' -ScriptBlock {
        param($key, $arg)
        [Microsoft.PowerShell.PSConsoleReadLine]::SelfInsert([System.ConsoleKeyInfo]::new(' ', [System.ConsoleKey]::Spacebar, $false, $false, $false), $arg)
    }

    # bash (readline) でよく使う語の移動と消し方の 4 つを、bash と同じ動きにする (win/README.md の「bash に似たキー」)。EditMode は Windows
    # (Windows の既定) のままにし、この 4 つだけを Emacs モードと同じ関数に割り当てる (Emacs モードにすると Ctrl+a・Ctrl+v・Tab などほかのキーも替わる)。
    # - Alt+f・Alt+b: 語の終わりへ・語の頭へ (bash の forward-word・backward-word。Windows モードには割り当てが無い)
    # - Ctrl+w: 前の空白まで消す (unix-word-rubout。cd foo/bar なら foo/bar を丸ごと。Windows モードの既定は記号でも止まる BackwardKillWord)
    # - Alt+d: 語の終わりまで消す (kill-word。Windows モードの既定も KillWord だが、PSReadLine の既定が変わっても同じに動くよう書く)
    # herdr-app の端末は Ctrl+←・Ctrl+→・Ctrl+Backspace を ESC b・ESC f・^W で送り (herdr-app の既定の keys.json の terminal の節)、PowerShell には
    # Alt+b・Alt+f・Ctrl+w として届くので、herdr-app ではこの割り当てがそのキーにも効く。語の区切り (WordDelimiters) はほかのキーにも効くので替えない
    Set-PSReadLineKeyHandler -Chord 'Alt+f' -Function ForwardWord
    Set-PSReadLineKeyHandler -Chord 'Alt+b' -Function BackwardWord
    Set-PSReadLineKeyHandler -Chord 'Ctrl+w' -Function UnixWordRubout
    Set-PSReadLineKeyHandler -Chord 'Alt+d' -Function KillWord
}

# Windows の OpenSSH (winget の Microsoft.OpenSSH.Preview) を、dotfiles で固定した版に揃える。
# 中身は同じ場所へ配る Install-OpenSSH.ps1 (win/README.md の「OpenSSH」)。-Check なら確かめるだけ。
# @args で引数をそのまま渡す (-Check / -Version / -Force もスクリプトの引数として効く)。
function Install-OpenSSH { & "$HOME\.config\powershell\Install-OpenSSH.ps1" @args }

# Windows の herdr (winget の Herdr.Herdr) を、dotfiles で固定した版に揃える。
# 中身は同じ場所へ配る Install-Herdr.ps1 (win/README.md の「herdr を入れる」)。-Check なら確かめるだけ。
# 入れ替えが要るときは、先に herdr の外の PowerShell で hsvstop を打つ (動いていると止まる)。
# 前に入れていた Herdr.Herdr.Preview が残っていれば、-Check が外す手順を出す (Install-Herdr は外さない)。
function Install-Herdr { & "$HOME\.config\powershell\Install-Herdr.ps1" @args }

# Windows の herdr-app (herdr の desktop app) と herdr-core を、dotfiles が固定した版で、公式の install.ps1 と同じ置き場所に入れる。
# 中身は同じ場所へ配る Install-HerdrApp.ps1 (win/README.md の「herdr-app」)。-Check なら固定どおりかを確かめるだけ。
# 自己更新の取得元は、固定した版だけを載せた手元のフィードに替える。-Uninstall で外す (設定は残す。app と core を止めてから打つ)。
function Install-HerdrApp { & "$HOME\.config\powershell\Install-HerdrApp.ps1" @args }

# Windows の Google 日本語入力 (winget の Google.JapaneseIME) を、dotfiles で固定した版に揃える。
# 中身は同じ場所へ配る Install-GoogleJapaneseInput.ps1 (win/README.md の「Google 日本語入力を入れる」)。-Check なら確かめるだけ。
# 入れる・上げるときは Windows に UAC の確認が出る。上げる前に、日本語入力を使っているアプリをできるだけ閉じる。
function Install-GoogleJapaneseInput { & "$HOME\.config\powershell\Install-GoogleJapaneseInput.ps1" @args }

# Windows の PowerToys (winget の Microsoft.PowerToys) が入っていなければ、user スコープで入れる。
# 中身は同じ場所へ配る Install-PowerToys.ps1 (win/README.md の「PowerToys を入れる」)。-Check なら確かめるだけ。
# 版は固定しない (PowerToys が自分で新しい版を知らせる)。
function Install-PowerToys { & "$HOME\.config\powershell\Install-PowerToys.ps1" @args }

# ssh の Host と port の組を選んで、port forwarding (ssh -NT -L …) をいまの PowerShell の中で張る。
# 中身は同じ場所へ配る Start-PortForward.ps1 (win/README.md の「port forwarding (pf)」)。PowerShell 7 だけで動く。
# pf <Host> で Host を選ぶ画面を飛ばす。張った後は Ctrl+C で止める。WSL・Linux の版は無い。
function pf { & "$HOME\.config\powershell\Start-PortForward.ps1" @args }

# Windows の type-clipboard (クリップボードの文字を選んだ窓へキー入力として打ち込む自作のアプリ) を、dotfiles で固定した版に揃える。
# 中身は同じ場所へ配る Install-TypeClipboard.ps1 (win/README.md の「type-clipboard」)。-Check なら確かめるだけ。
# GitHub の Release から落とし、SHA-256 が合うときだけ置く。入れ替えが要るときは、先に type-clipboard の窓を閉じる (動いていると止まる)。
function Install-TypeClipboard { & "$HOME\.config\powershell\Install-TypeClipboard.ps1" @args }

# Windows の op-reason (WSL の op の Windows の部品。1Password CLI の wrapper の自作の OSS) を、dotfiles で固定した版に揃える。
# 中身は同じ場所へ配る Install-OpReason.ps1 (win/README.md の「op-reason」)。-Check なら確かめるだけ。
# GitHub の Release の zip を、SHA-256 が合うときだけ %LOCALAPPDATA%\Programs\op-reason に展開する。op の呼び出しの途中
# (op-reason.exe が動いている) なら止まるので、終わってから打ち直す。setup --update でも揃える。
function Install-OpReason { & "$HOME\.config\powershell\Install-OpReason.ps1" @args }

# Windows の ntn (Notion の CLI。winget の Notion.ntn) を、dotfiles で固定した版に揃える。
# 中身は同じ場所へ配る Install-Ntn.ps1 (win/README.md の「ntn」)。-Check なら確かめるだけ。
# 入れ替えが要るときは、動いている ntn を先に終わらせる (動いていると止まる)。setup --update でも揃える。
function Install-Ntn { & "$HOME\.config\powershell\Install-Ntn.ps1" @args }

# Windows の Claude Code (winget の Anthropic.ClaudeCode) を、dotfiles で固定した版に揃える。
# 中身は同じ場所へ配る Install-ClaudeCode.ps1 (win/README.md の「Claude Code」)。-Check なら確かめるだけ。
# 入れ替えが要るときは、Windows で開いている Claude Code の会話を先に閉じる (動いていると止まる)。setup --update でも揃える。
function Install-ClaudeCode { & "$HOME\.config\powershell\Install-ClaudeCode.ps1" @args }

# Windows の Tailscale (winget の Tailscale.Tailscale。machine スコープの MSI) を、dotfiles で固定した版で入れる。
# 中身は同じ場所へ配る Install-Tailscale.ps1 (win/README.md の「Tailscale」)。-Check なら確かめるだけ。
# 入れる・上げるときは Windows に UAC の確認が出る (上げる間、Tailscale の接続が少しの間切れる)。入っている版の方が新しければ下げない
# (Tailscale が自分で上がる)。tailnet へのログインは、入れた後にタスクトレイの Tailscale のアイコンから手でする。
function Install-Tailscale { & "$HOME\.config\powershell\Install-Tailscale.ps1" @args }

# Windows に sshd (OpenSSH Server) を入れ、Tailscale と localhost からだけ、鍵でだけ SSH で入れる形に揃える。
# 中身は同じ場所へ配る Install-Sshd.ps1 (win/README.md の「sshd」)。-Check なら確かめるだけ。揃えるときは Windows に UAC の確認が
# 1 回出る (sshd を起こし直すと、つないでいる SSH が切れることがある)。鍵は setup が置く写し (%LOCALAPPDATA%\dotfiles\sshd\authorized_keys)
# どおりに置く。iPhone の Herdr のアプリや hc からつなぐときは、この PC で Herdr を開いたままにしておく。
function Install-Sshd { & "$HOME\.config\powershell\Install-Sshd.ps1" @args }

# Windows 側の runner (dotfiles の win/runner/。Rust)。dotfiles check で手順を順に確かめ (何も書かない)、dotfiles apply で揃え
# (このホストの受け持ちが runner のときだけ。dotfiles-private の win/hosts/<ユーザー>@<PC>.toml の [runner] enable = true)、
# dotfiles list で手順と on/off を見る (win/README.md の「runner」)。bootstrap が clone した dotfiles の中の runner を cargo run で
# build して起こす。cargo は win\runner に入ってから打つ: rustup は rust-toolchain.toml を今のディレクトリから探し、bootstrap は
# 既定の toolchain を入れていないので、--manifest-path だけでは toolchain が決まらずに落ちる。--locked で Cargo.lock のまま build する。
function dotfiles {
    $runner = [IO.Path]::Combine($HOME, 'ghq', 'github.com', 'pollenjp', 'dotfiles', 'win', 'runner')
    if (-not (Test-Path -LiteralPath (Join-Path $runner 'Cargo.toml'))) {
        Write-Host "dotfiles の runner がありません: $runner (先に win\bootstrap\Install-Bootstrap.ps1 で clone する)" -ForegroundColor Yellow
        $global:LASTEXITCODE = 2
        return
    }
    $runnerArgs = @(ConvertTo-DotfilesRunnerArgs -Arguments $args)
    Push-Location -LiteralPath $runner
    try {
        # '--' は引用符で囲む。素の -- は PowerShell が引数の終わりの印として読み、版や呼び先によっては cargo に届かない
        # (届かないと、runner への --steps などを cargo が自分の引数として読んで落ちる)
        cargo run --quiet --release --locked '--' @runnerArgs
    } finally {
        Pop-Location
    }
}

# dotfiles 関数が runner に渡す引数。PowerShell は `--steps files,ntn` の `files,ntn` を配列にし (`--steps=files,ntn` も
# `--steps=files` と `ntn` の配列にする)、関数の @args はそれを別々の引数に広げるので、配列は , でつなぎ直して 1 つの引数にする
# (runner は `--steps a,b` の形で受ける)。
function ConvertTo-DotfilesRunnerArgs {
    param([object[]]$Arguments)
    foreach ($a in $Arguments) {
        if ($a -is [array]) { ($a | ForEach-Object { "$_" }) -join ',' } else { "$a" }
    }
}
