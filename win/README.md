# win/

Windows 側のアプリの設定を置く場所。WSL から `/mnt/c` 越しにコピーして配る
(経緯は [ADR 010](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/010_win_files_from_wsl_20260928T003933JST/README.md))。

新しい Windows で最初に流す bootstrap も置く ([後述](#bootstrap-新しい-windows-で最初に流す))。Windows の環境は Windows 側の runner
(`runner/`。Rust。[後述](#runner-windows-の側で確かめて揃える)) で作る途中で、ホストごとに受け持ちを runner へ切り替えるまでは、WSL の setup と
同じ手順 (files と `Install-*.ps1`) は今までどおり WSL が配り、runner は確かめるだけ。Windows にしか無い手順 (claude-skills を Windows の
Claude Code で使う W0-2 の手順・Windows の Claude Code に dotfiles の設定を配る手順・git の設定など) は、受け持ちによらず runner が流す (経緯は
[ADR 058](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/058_win_runner_bootstrap_20261115T225331JST/README.md) と
dotfiles-private の ADR 060 (`docs/adr/060_win_runner_core_*`)・ADR 064 (`docs/adr/064_win_w02_claude_skills_hub_*`)・ADR 065
(`docs/adr/065_win_claude_config_*`)・ADR 066 (`docs/adr/066_win_git_config_*`))。

| ファイル | 置き先 (Windows) | 中身 |
| --- | --- | --- |
| `bootstrap/Install-Bootstrap.ps1` | (配らない。新しい Windows で URL から落として流し、clone した後は clone の中のものを流す) | 新しい Windows で最初に流す setup。Git for Windows・GitHub CLI・Visual Studio Build Tools・rustup (MSVC の host) を固定した版で入れ、dotfiles・dotfiles-private・claude-skills を Windows の ghq に clone する ([後述](#bootstrap-新しい-windows-で最初に流す)) |
| `runner/` | (配らない。Windows の clone の中で `dotfiles` 関数が `cargo run` で build して起こす) | Windows 側の runner (Rust の `dotfiles-win`)。WSL の setup の Windows の手順を写したもので、`dotfiles check` で確かめ、受け持ちを切り替えたホストでは `dotfiles apply` で揃える ([後述](#runner-windows-の側で確かめて揃える)) |
| `orca/keybindings.json` | `%USERPROFILE%\.orca\keybindings.json` | Orca のキーバインド ([TKT-25](https://app.notion.com/p/Orca-worktree-Ctrl-Alt-Ctrl-Ctrl-W-3e779149a66f8177809ac8632bf68b2c)) |
| `powershell/dotfiles.ps1` | `%USERPROFILE%\.config\powershell\dotfiles.ps1` | PowerShell の共有設定 (herdr と Claude Code の alias、`e` = `exit`、runner を流す `dotfiles`)。`$PROFILE` から読む ([後述](#powershell)、[TKT-77](https://app.notion.com/p/PowerShell-profile-dotfiles-win-herdr-alias-h-hss-hls-Windows-3ef79149a66f817abc28dd3fa5241903)) |
| `herdr/config.toml` | `%APPDATA%\herdr\config.toml` | Windows の herdr の設定。キーバインドと sidebar の行は WSL と同じ ([後述](#herdr)、[TKT-92](https://app.notion.com/p/herdr-Windows-win-herdr-config-toml-3f079149a66f819fb49ef2d13e6a76f5)) |
| `openssh/Install-OpenSSH.ps1` | `%USERPROFILE%\.config\powershell\Install-OpenSSH.ps1` | Windows の OpenSSH を winget で固定した版に揃える。PowerShell の `Install-OpenSSH` から呼ぶ ([後述](#openssh)、[TKT-109](https://app.notion.com/p/winget-Windows-OpenSSH-win-3f179149a66f812fba25c6b2d6ce5d31)) |
| `herdr/Install-Herdr.ps1` | `%USERPROFILE%\.config\powershell\Install-Herdr.ps1` | Windows の herdr を winget で固定した版に揃える。PowerShell の `Install-Herdr` から呼ぶ。setup が入れて揃えるのは `dotfiles.wsl.windowsFiles.herdr.enable = true` (既定は設定グループで決まる) のマシン ([後述](#herdr-を入れる-winget)、[TKT-112](https://app.notion.com/p/winget-Windows-herdr-Herdr-Herdr-Preview-dotfiles-3f179149a66f81858e0cf4555c9c598f)) |
| `herdr-app/claude-skill-head.md` | (配らない。runner の `herdr-app-skill` の手順が、`herdr-app --skill` の頭に足して `%USERPROFILE%\.claude\skills\herdr-app\SKILL.md` を作る) | herdr-app の Claude Code の skill の frontmatter と、作った版を書くコメント。hc の skill の頭は Linux と同じ `nix/pkgs/herdr-core/claude-skill-head.md` ([後述](#claude-skills-と-windows-のハブ-w0-2)) |
| `herdr-app/Install-HerdrApp.ps1` | `%USERPROFILE%\.config\powershell\Install-HerdrApp.ps1` | Windows の herdr-app (herdr の desktop app) と herdr-core を、dotfiles が固定した版で公式の install.ps1 と同じ置き場所に入れる・外す。自己更新の取得元を、固定した版だけを載せた手元のフィードに替える。PowerShell の `Install-HerdrApp` から呼ぶ。setup が入れて揃えるのは herdr と同じ `dotfiles.wsl.windowsFiles.herdr.enable = true` のマシン ([後述](#herdr-app)) |
| (`nix/pkgs/herdr-core/releases.json`) | `%USERPROFILE%\.config\powershell\herdr-releases.json` | herdr-app と herdr-core の固定した版と sha256。`Install-HerdrApp.ps1` が読む。Linux の home-manager も同じファイルを読むので `nix/` に置き、manifest の `base = "nix"` で配る ([後述](#固定した版を上げる)) |
| `powertoys/keyboard-manager/default.json` | `%LOCALAPPDATA%\Microsoft\PowerToys\Keyboard Manager\default.json` | PowerToys の Keyboard Manager の割り当て (CapsLock → F13 など)。エンジンが読む ([後述](#powertoys)、[TKT-139](https://app.notion.com/p/Windows-Google-dotfiles-win-3f679149a66f81b1a592d85d7300a62b)) |
| `powertoys/keyboard-manager/editorSettings.json` | `%LOCALAPPDATA%\Microsoft\PowerToys\Keyboard Manager\editorSettings.json` | Keyboard Manager の新しいエディタが持つ割り当ての一覧 ([後述](#powertoys)) |
| `powertoys/fancyzones/custom-layouts.json` | `%LOCALAPPDATA%\Microsoft\PowerToys\FancyZones\custom-layouts.json` の中のレイアウト | FancyZones のエディターの「カスタム」に登録したレイアウト。manifest では配らず、`bootstrap-windows-fancyzones.sh` が uuid ごとに足す (PC にだけあるレイアウトには触らない。[後述](#fancyzones)) |
| `powertoys/fancyzones/layout-rules.json` | `%LOCALAPPDATA%\Microsoft\PowerToys\FancyZones\applied-layouts.json` の組と、`default-layouts.json` の横向きの既定 | ディスプレイの解像度から、あてるレイアウトを決める決まり。manifest では配らず、`bootstrap-windows-fancyzones.sh` が横向きの既定を決まりの `default` にそろえ、テンプレートのままのディスプレイの組を決まりのレイアウトで埋め、組の無い仮想デスクトップに組を作る (手であてたものは残す。[後述](#ディスプレイへのあて方)) |
| `powertoys/fancyzones/managed.json` | `%LOCALAPPDATA%\Microsoft\PowerToys\FancyZones\settings.json` の一部のキー | FancyZones の設定のうち、dotfiles が持つキーだけ (今は「Windows スナップのオーバーライド」)。manifest では配らず、`bootstrap-windows-fancyzones.sh` が書く ([後述](#fancyzones)) |
| `powertoys/Install-PowerToys.ps1` | `%USERPROFILE%\.config\powershell\Install-PowerToys.ps1` | Windows の PowerToys が入っていなければ winget で入れる。PowerShell の `Install-PowerToys` から呼ぶ ([後述](#powertoys-を入れる-winget)、[TKT-143](https://app.notion.com/p/winget-Windows-Google-PowerToys-Google-dotfiles-3f779149a66f817a8944c9e4e460383f)) |
| `google-japanese-input/` | `%USERPROFILE%\AppData\LocalLow\Google\Google Japanese Input\` | Google 日本語入力の設定とキー設定のテキスト (`config.txtpb`・`keymap.tsv`)。manifest では配らず、組み立てて配る ([後述](#google-日本語入力)、[TKT-139](https://app.notion.com/p/Windows-Google-dotfiles-win-3f679149a66f81b1a592d85d7300a62b)) |
| `google-japanese-input/Install-GoogleJapaneseInput.ps1` | `%USERPROFILE%\.config\powershell\Install-GoogleJapaneseInput.ps1` | Windows の Google 日本語入力を winget で固定した版に揃える。PowerShell の `Install-GoogleJapaneseInput` から呼ぶ ([後述](#google-日本語入力を入れる-winget)、[TKT-143](https://app.notion.com/p/winget-Windows-Google-PowerToys-Google-dotfiles-3f779149a66f817a8944c9e4e460383f)) |
| (dotfiles-private の `ssh/*.ssh_config`) | `%USERPROFILE%\.ssh\config` と `config.d\` | ssh の接続先。manifest では配らず、`bootstrap-windows-ssh-config.sh` がコピーする ([後述](#ssh-の設定)、[TKT-145](https://app.notion.com/p/Windows-OS-Windows-ssh-3f779149a66f81c4a2cff0233027c26e)) |
| `port-forward/Start-PortForward.ps1` | `%USERPROFILE%\.config\powershell\Start-PortForward.ps1` | ssh の Host と port の組を選んで port forwarding を張る。PowerShell 7 の `pf` から呼ぶ ([後述](#port-forwarding-pf)) |
| (dotfiles-private の `ssh/port-forward.toml`) | `%USERPROFILE%\.config\port-forward\hosts.json` | `pf` が出す port の組 (共有の組)。manifest では配らず、`bootstrap-windows-port-forward.sh` が JSON にして置く ([後述](#port-forwarding-pf)) |
| `windows-terminal/managed.json` | Store 版の `settings.json` (`%LOCALAPPDATA%\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\`) の一部のキー | Windows Terminal の設定のうち、dotfiles が持つキーだけ (今は bell の音)。manifest では配らず、`bootstrap-windows-terminal.sh` がキーごとに書き足す ([後述](#windows-terminal)、[TKT-167](https://app.notion.com/p/Windows-Terminal-settings-json-dotfiles-bell-3fb79149a66f81e6a695c581b5ab5cef)) |
| `international/managed.json` | ユーザーのレジストリ `HKCU\Control Panel\International` の一部の値 | Windows の日付と時刻の形式のうち、dotfiles が持つ値だけ (短い日付・長い時刻・短い時刻)。manifest では配らず、`bootstrap-windows-international.sh` が SetLocaleInfoW で書く ([後述](#日付と時刻の形式)) |
| `type-clipboard/Install-TypeClipboard.ps1` | `%USERPROFILE%\.config\powershell\Install-TypeClipboard.ps1` | 自作の type-clipboard を、GitHub の Release から固定した版 (SHA-256 も固定) で入れる。PowerShell の `Install-TypeClipboard` から呼ぶ。setup が入れるのは `dotfiles.wsl.windowsFiles.typeClipboard.enable = true` のマシンだけ ([後述](#type-clipboard)) |
| `op-reason/Install-OpReason.ps1` | `%USERPROFILE%\.config\powershell\Install-OpReason.ps1` | WSL の op (自作の OSS の op-reason。1Password CLI の wrapper) の Windows の部品 `op-reason-windows.zip` を、GitHub の Release から固定した版 (SHA-256 も固定) で `%LOCALAPPDATA%\Programs\op-reason` に入れる。PowerShell の `Install-OpReason` から呼ぶ。setup が入れて揃えるのは、WSL の op の wrapper を入れるマシン (`dotfiles.wsl.enable` と `dotfiles.onePassword.enable` が両方 true) だけ ([後述](#op-reason)) |
| `ntn/Install-Ntn.ps1` | `%USERPROFILE%\.config\powershell\Install-Ntn.ps1` | Notion の CLI の ntn を winget の `Notion.ntn` で固定した版に揃える。PowerShell の `Install-Ntn` から呼ぶ。setup が入れて揃えるのは `dotfiles.wsl.windowsFiles.ntn.enable = true` (既定は設定グループで決まる) のマシン ([後述](#ntn)) |
| `claude-code/Install-ClaudeCode.ps1` | `%USERPROFILE%\.config\powershell\Install-ClaudeCode.ps1` | Claude Code を winget の `Anthropic.ClaudeCode` で固定した版に揃える。PowerShell の `Install-ClaudeCode` から呼ぶ。setup が入れて揃えるのは `dotfiles.wsl.windowsFiles.claudeCode.enable = true` (既定は設定グループで決まる) のマシン ([後述](#claude-code)) |
| `claude-code/CLAUDE.windows.md` | (配らない。runner の `claude-files` の手順が、`nix/files/claude/CLAUDE.md` の冒頭をこれに差し替えて `%USERPROFILE%\.claude\CLAUDE.md` を作る) | Windows の Claude Code の CLAUDE.md の冒頭 (runner が配ること・直し方) ([後述](#claude-code-の設定)) |
| `claude-code/skip-skills.txt` | (配らない。runner の `claude-files` の手順が読む) | Windows の Claude Code に張らない dotfiles の skill (Nix・そのマシンの `~/dotfiles` を前提にするもの) ([後述](#claude-code-の設定)) |
| (`nix/home/modules/git.toml`) | `%USERPROFILE%\.config\git\config`・`ignore`・`config.<owner>` | git の設定のうち、どの OS でも同じにする値 (名前とメール・pollenjp-sub の名前とメール・alias・core など・ignore) の正本。WSL の home-manager (`nix/home/modules/git.nix`) と runner の `git-config` の手順が同じファイルを読む ([後述](#git-の設定)) |

## bootstrap (新しい Windows で最初に流す)

新しい Windows で最初に流す PowerShell の script (`bootstrap/Install-Bootstrap.ps1`)。Rust の runner を動かせるところまで (Git for Windows・
GitHub CLI・Visual Studio Build Tools・rustup と、dotfiles・dotfiles-private・claude-skills の clone) を揃える。WSL は要らない。Windows の
環境を Windows 側の runner で作る最初の段で、その後は runner (`runner/`。[後述](#runner-windows-の側で確かめて揃える)) が受け持つ。ホストごとに
受け持ちを runner に切り替えるまで、Windows のアプリと設定を配るのは今までどおり WSL の setup ([配る](#配る))。経緯は
[ADR 058](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/058_win_runner_bootstrap_20261115T225331JST/README.md)
(ADR 010 の前提「WSL のある Windows だけ」を改めた)。

- 対象は設定グループ personal の Windows (ハブにする PC)。個人の gh のアカウントでログインして private な repo を取るので、自社・客先の
  Windows では流さない
- 普通の (管理者でない) PowerShell で流す。管理者の PowerShell だと何も変えずに止まる (clone と rustup が管理者の持ち物になり、普通の
  権限の git が `dubious ownership` で止まるため)。UAC は道具ごとに出る
- 対象の CPU は x64 だけ (ARM64 の Windows は今は対象外)

### bootstrap を流す

新しい Windows (git が無い) では、Windows PowerShell でファイルに落としてから流す (`irm … | iex` にしない。読んでから流せるように):

```powershell
$f = Join-Path $env:TEMP 'Install-Bootstrap.ps1'
Invoke-WebRequest -UseBasicParsing -OutFile $f https://raw.githubusercontent.com/pollenjp/dotfiles/main/win/bootstrap/Install-Bootstrap.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File $f -Check   # 何も変えずに状態を出す
powershell -NoProfile -ExecutionPolicy Bypass -File $f          # 揃える
```

clone した後は、clone の中のものを流す (冪等。揃っていれば何もしない):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File $HOME\ghq\github.com\pollenjp\dotfiles\win\bootstrap\Install-Bootstrap.ps1 -Check
```

| 終了コード | 意味 |
| --- | --- |
| 0 | 直すことが無い |
| 3 | 入っていない・無いものだけ (引数なしで流せば揃う。締めの行は「入っていない・無いものがある → 引数なしで流すと揃える」) |
| 1 | ほかに直すことがある (表の ⚠ の行を見る)。足りない・ずれているもの (pin・Build Tools の部品・rustup の設定と既定の host・gh のログイン) は引数なしで流せば直り (締めの行は「足りないもの・ずれているものがある → 引数なしで流すと直す」)、bootstrap では直らない差は ※ の手順で直す。Ctrl+C で止めた・揃えきれなかったときも |
| 2 | winget が無い (Microsoft Store の「アプリ インストーラー」を入れる)・思わぬ例外 |

- 道具を入れるときの UAC で「はい」を押さない・installer の窓を閉じると、その道具は入らず「インストーラーが取り消された」と出て、
  締めの表の ⚠ とともに終了コード 1 で終わる。流し直すと、もう一度入れる

### bootstrap がすること

1. 最初に Smart App Control (SAC) を確かめる (`-Check` でも)。オフでなければ (オン・評価モード) 警告を出して続ける (止めない)。
   オンだと cargo が作った exe (Rust の runner・build script) が止められて動かないので、runner を流す前にオフにする (Windows セキュリティ →
   アプリとブラウザーの制御 → スマート アプリ コントロールの設定。Windows によっては戻すのに再インストールが要る)。script は SAC を変えない
2. 道具を固定した版で入れ、winget の pin を足す (この順。rustup-init が MSVC を見るので、Build Tools を rustup より先に入れる):

   | 道具 | winget の ID | 固定した版 (param) | 入れ方 |
   | --- | --- | --- | --- |
   | Git for Windows | `Git.Git` | `2.56.0.4` (`-GitVersion`) | machine の scope (`C:\Program Files\Git`)。インストーラーの選択肢は既定のまま |
   | GitHub CLI | `GitHub.cli` | `2.103.3` (`-GhVersion`) | MSI (`C:\Program Files\GitHub CLI`)。`--silent` を付けないので、UAC と進み具合の小さな窓が出る (per-machine の MSI は、quiet だと管理者でない PowerShell から UAC を出せずに落ちる) |
   | Visual Studio Build Tools 2022 | `Microsoft.VisualStudio.2022.BuildTools` | `17.14.44` (`-VsBuildToolsVersion`) | C++ のワークロード (`Workload.VCTools`。必須の部品だけ)・x64 の MSVC (`VC.Tools.x86.x64`)・Windows SDK (`Windows11SDK.26100`)・英語の言語パック。MSVC と SDK は rustup が自分で入れるときと同じ部品。`--silent` を付けないので、UAC と進み具合の窓が出る。数 GB を落とすので 10 分以上かかることがある |
   | rustup | `Rustlang.Rustup` | `1.29.3` (`-RustupVersion`) | 既定の host を MSVC (`--default-host x86_64-pc-windows-msvc`) にし、toolchain は入れない (`--default-toolchain none`。版は runner の `rust-toolchain.toml` が決める)。自己更新を止める (`rustup set auto-self-update disable`) |

   Rust は MSVC の host (`x86_64-pc-windows-msvc`) を使う。GNU の host (`x86_64-pc-windows-gnu`) にしないのは、`windows-sys` 0.61 が使う
   `windows-link` の `raw-dylib` の build に MinGW の `dlltool` と `as` が要り、GNU の toolchain に同梱の `dlltool` だけでは import library を
   作れないため (`windows-latest` の GitHub Actions は MinGW が入っているので通る)。
   - 入っている Build Tools に足りないもの (ワークロード・MSVC・SDK) があれば、Visual Studio Installer で足す (UAC と進み具合の窓)。Windows SDK は
     10 か 11 のどれかがあれば足りたことにする
   - 入っている rustup の既定の host (`rustup show` の `Default host`) が MSVC でなければ (GNU にしていた Windows など)、
     `rustup set default-host x86_64-pc-windows-msvc` で直す。入っている toolchain には触らない (GNU の toolchain が残っていて要らなければ
     `rustup toolchain list` で見て `rustup toolchain uninstall <名前>` で外す)
3. gh が github.com にログインしていなければ `gh auth login --hostname github.com --web --clipboard --git-protocol ssh --skip-ssh-key` を流す
   (一回限りのコードは gh がクリップボードに入れるので、Enter で開いたブラウザーに貼り付けて認める)。`--git-protocol ssh` にするのは、gh に
   `~/.gitconfig` の credential helper を書かせないため
   - コードを写そうとして Ctrl+C を押すと gh が止まる。そのときも bootstrap は止まらずに読み直しと締めの表まで出し、clone はせずに終了コード
     1 で終える (流し直すと、ログインからやり直す)。ログインのほかの所で Ctrl+C を押したときは、止めたことを 1 行出して終了コード 1 で終える
4. 無い repo を `%USERPROFILE%\ghq\github.com\pollenjp\` に clone する (dotfiles・dotfiles-private・claude-skills。ghq の既定の root)
   - gh の資格情報で HTTPS を通す組 (`nix/pkgs/git-gh` と同じ) を、clone のときだけ `-c` で渡す。origin は WSL と同じ ssh の URL
     (`git@github.com:pollenjp/<repo>.git`) のまま。`~/.gitconfig` は書かない
   - `core.autocrlf=false` をその repo に書く。Git for Windows の既定 (`true`) のままだと LF が CRLF で取り出され、WSL が配ったものと
     バイト列がずれる
   - あるディレクトリと clone には触らない (取得もしない)。git の repo でない・origin が別の repo・`core.autocrlf` が `true` なら ⚠ で
     知らせる (退けて流し直すと clone し直す)

- 入っている道具の版が固定した版と違っても揃えない (⚠ と、手で揃える手順の ※ を出す。下の「版のずれを手で揃える」)
- 見るのは固定した版の置き場所だけ。別の形で入っているもの (user の scope の Git・zip の gh・Visual Studio の Community や 2026) があっても、
  固定した版を並べて入れる。どちらが使われるかは PATH の順や rustc の探し方で決まるので、気になれば別の形のものを外す
- Git for Windows を入れると、Windows の Claude Code が Git Bash を見つけて使えるようになる

### 版のずれを手で揃える

固定した版を上げた PR が merge された後、入っている Windows では `-Check` が版のずれを ⚠ で出す (runner の `dotfiles check` も、bootstrap の
手順の行で同じずれを出す)。揃えるのは Rust の runner の受け持ちだが、今の runner は見せるだけで揃える手順はまだ無いので、それまでは手で
揃える。bootstrap が足した pin があるので、版を名指しした upgrade には `--include-pinned` を付ける (付けないと pin に止められ、終了コード
`0x8A150068` で落ちる。[winget の pin](#winget-の-pin)):

```powershell
winget upgrade --id Git.Git --exact --version <版> --include-pinned
winget upgrade --id GitHub.cli --exact --version <版> --include-pinned
winget upgrade --id Microsoft.VisualStudio.2022.BuildTools --exact --version <版> --include-pinned   # UAC が出る
winget upgrade --id Rustlang.Rustup --exact --version <版> --include-pinned --custom "--default-host x86_64-pc-windows-msvc --default-toolchain none"
```

- pin は付いたまま残る (上げた後に足し直さなくてよい)。bootstrap の `-Check` の ※ の行も、同じコマンドを出す
- 下げるときは `winget uninstall --id <ID>` の後に bootstrap を流し直す (固定した版で入れ直す)
- Git・gh は、使っているプロセス (Git Bash・Windows の Claude Code の会話など) を閉じてから

### bootstrap の固定した版の新しい版が出たとき

4 つの版も、ほかの Windows のアプリと同じく新しい版の知らせに乗る ([winget の新しい版を確かめる](#winget-の新しい版を確かめる)・
[固定した版より新しい版の知らせ](#固定した版より新しい版の知らせ))。setup の手順 97 の知らせは、Windows の ghq に dotfiles の clone がある
(bootstrap を流した) マシンでだけ出る。

- 出た日は、`git` が GitHub (`git-for-windows/git`) の release (tag `v<X.Y.Z>.windows.<N>` を winget の版 `X.Y.Z` (N が 1) か `X.Y.Z.N` に
  突き合わせる)、`gh` が GitHub (`cli/cli`) の release、`vs-buildtools`・`rustup` が winget-pkgs に載った日
- 上げるとき: release notes を読み、`bootstrap/Install-Bootstrap.ps1` の名前ごとの param の既定値と、上の道具の表の版を新しい版にし、
  `Install-Bootstrap.Tests.ps1` を流して PR を出す (`winget-versions` が、書いた版が winget にあるかを確かめる)。Build Tools はワークロードと
  部品の ID (`Workload.VCTools`・`VC.Tools.x86.x64`・`Windows11SDK.26100`) が残っているか、rustup は `--default-host`・
  `--default-toolchain none` と自己更新の止めが効くかも見る
- 見送るとき: `bootstrap/skipped-versions/<名前>.txt` に「版 理由」を 1 行足して commit する

### Install-Bootstrap.ps1 を書くときの注意

- BOM 付きの UTF-8 で保存する。新しい Windows には Windows PowerShell 5.1 しか無いので、PowerShell 7 にしか無い書き方 (`??`・`?.`・
  三項演算子・`&&`・`||`・`-AsHashtable`・3 引数の `Join-Path`) を使わない (`Install-Bootstrap.Tests.ps1` が見る)
- 固定した版は param の既定値 (`[string]$GitVersion = '<版>'` の形の行)、パッケージ ID は 1 行ずつの変数 (`$gitPackageId = '<ID>'`)。
  `nix/scripts/check-winget-version.sh` がこの行を読む
- 副作用の無い関数と、Windows に触る関数を偽物に差し替えた流れは `bootstrap/Install-Bootstrap.Tests.ps1` で確かめる (Linux の pwsh。
  [PowerShell のテスト](#powershell-のテスト))。winget・UAC・vswhere・gh のログイン・clone の本物の動きは、Windows の実機で `-Check` と
  本番を打って確かめる

## runner (Windows の側で確かめて揃える)

`runner/` は Windows の側から Windows の環境を作る Rust の runner (`dotfiles-win`)。WSL の setup の Windows の手順
(`nix/scripts/bootstrap-windows-*.sh`。order 90〜99) を 1 つずつ写したもので、判定と文言をそろえている。経緯は
[ADR 058](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/058_win_runner_bootstrap_20261115T225331JST/README.md) §2 H・I と
dotfiles-private の ADR 060 (`docs/adr/060_win_runner_core_*`)。

- 受け持ちはホストごとに一度に切り替える ([後述](#受け持ちを-runner-に切り替える))。切り替えるまでは、WSL の setup と同じ手順 (files と
  `Install-*.ps1`) は今までどおり WSL の setup が配り ([配る](#配る))、runner は `dotfiles check` で確かめるだけ (同じ commit の clone なら、WSL と
  同じ判定を出すかを突き合わせられる)。Windows にしか無い手順 (claude-skills を Windows の Claude Code で使う W0-2 の手順など。[後述](#claude-skills-と-windows-のハブ-w0-2))
  は、WSL の setup が Windows に配らないので、受け持ちによらず runner の `dotfiles apply` が流す (dotfiles-private の ADR 064 (`docs/adr/064_win_w02_claude_skills_hub_*`))
- 流すのは bootstrap が clone した dotfiles (`%USERPROFILE%\ghq\github.com\pollenjp\dotfiles`) の中の runner。PowerShell の `dotfiles` 関数
  (`powershell/dotfiles.ps1`) が `win\runner` に入って `cargo run --quiet --release --locked` を打つ (rustup は `rust-toolchain.toml` を今の
  ディレクトリから探す。初回は rustup がその版を入れ、build に少しかかる)。clone を pull すれば、次の呼び出しから新しいコードで動く

### runner を流す

```powershell
dotfiles list                          # 手順と、このホストでの on/off・runner に移したか
dotfiles check                         # 手順を順に確かめる (何も書かない)
dotfiles check --steps files,ntn       # 手順を id で絞る (PowerShell が配列にした files,ntn は dotfiles 関数が , でつなぎ直す)
dotfiles apply --dry-run               # apply がすることを出す (何も書かない。受け持ちによらず流せる)
dotfiles apply                         # 揃える (受け持ちが WSL のホストでは Windows にしか無い手順だけ。ホストの値が無ければ止まって 1)
dotfiles apply --steps files --force   # files の衝突 (Windows 側で変わっていた) も上書きする
dotfiles manifest                      # manifest.toml を検証する (--json は置き先を解いた計画)
```

- 最後に手順ごとの表 (⚠ = 直すことがある・✔ = 揃っている・↷ = このホストでは off・· = runner にまだ無い) と、種類ごとの締めの行を出す
- 終了コードは bootstrap と同じ: 0 = 直すことが無い・3 = 入っていない・無いものだけ (apply で揃う)・1 = ほかに直すことがある (足りない・
  ずれている・runner では直らない差・落ちた手順・apply を止めた)・2 = runner が動けない (引数・ホストの値・`groups.json` の誤り、Windows の
  環境変数が無い)
- 1 つの手順が落ちても、残りの手順も流す (ps1 は clone の中のものを呼ぶので、files に頼らない。WSL の setup は files の衝突で後ろを止める)
- 受け持ちが WSL のホストの apply は、Windows にしか無い手順 (`dotfiles list` の「(Windows だけ)」) だけを流し、WSL の setup と同じ手順は流さずに
  `·` の行 (受け持ちは WSL の setup) を出す。選んだ手順 (`--steps`) に Windows にしか無い手順が無ければ止まる (1)。WSL の setup と同じ手順に直すことが
  あれば、締めの行の下に WSL の `~/dotfiles/setup --update` で揃える道を添える (files の衝突の解き方も、WSL の `bootstrap-windows-files.sh --force` を出す)

### ホストの値

dotfiles-private の `win/hosts/<Windows のユーザー名>@<PC の名前>.toml` (`<PC の名前>` は `hostname` を小文字にしたもの。pjp-raiden なら
`polle@pjp-raiden.toml`)。WSL の Nix のホスト (`nix/hosts/<user>@<hostname>.nix`) に当たる。

```toml
group = "personal"            # personal (既定)・company・client (nix/README.md の「設定グループ」)

[tools]                       # 道具の switch の上書き。書かなければグループの既定 (runner/groups.json)
windowsTypeClipboard = true

[runner]
enable = false                # 受け持ちの印。true で WSL の setup と同じ手順も apply で書く

[claude.notion]               # Notion へ書く skill の宛先 (Nix の dotfiles.claude.notion と同じ名前と形)
profile = "personal"          # このマシンの既定のプロファイル (書かなければ null)
routes = { "pollenjp/some-repo" = "work" }   # このマシンだけの宛先の規則 (書かなければ空)

[claude.notion.override.personal]            # プロファイルの値を、このマシンだけ差し替える (書かなければ空)
scanData = "https://app.notion.com/p/…"
```

- 書けるのは `group`・`[tools]`・`[runner] enable`・`[claude.notion]` (`profile`・`routes`・`override`) だけ。道具の名前は `group.json` の `tools` と同じ
  (runner が使うのは `windowsClaudeCode`・`windowsHerdr`・`windowsNtn`・`windowsTypeClipboard`・`claudePrivateSkills`・`herdrHub`・`devTracker`・`gitIdentity` と、
  runner にまだ無い `op-reason` の on/off の `onePassword`)。知らないキー・名前は runner が止める (終了コード 2)
- `gitIdentity` (git の名前とメールを個人のアカウントにするか) の既定は、WSL の Nix の `git.identity.enable` と同じくグループで決まる (personal が true)。
  WSL の Nix の値で `git.identity.enable` を変えたホストは、同じ値を `[tools]` に書く ([後述](#git-の設定))
- `devTracker` はどのグループでも既定が false。Dev Tracker を使うホスト (WSL の Nix の値で `claude.devTracker.enable = true`) は、同じ値を `[tools]` に
  書く (Windows の `CLAUDE.md` に「タスク管理」の節が入り、skillOverrides の `pjp-dev-tracker` が on になる。[後述](#claude-code-の設定))
- `onePassword` はどのグループでも既定が false。1Password を使うホスト (WSL の Nix の値で `onePassword.enable = true`) は、同じ値を `[tools]` に書く
  (書かなければ `op-reason` の行は off になり、受け持ちを切り替えても ⚠ に出ない)
- `[claude.notion]` は `claude-notion` の手順が `%USERPROFILE%\.local\state\dotfiles\claude-notion.json` に書く (Linux の home-manager が書くのと同じ中身)。
  runner が確かめるのは Nix の option と同じ型だけ (`profile` は `[a-z0-9][a-z0-9_-]*`・`routes` は文字列の表・`override` は表。日時は書けない)。
  プロファイルの名前やキーの綴りは、claude-skills の pjp-notion-profile が使うときに確かめる。TOML に null は無いので、`override` で値を消す形
  (Nix の `null`) は書けない
- dotfiles-private は、runner を build した dotfiles の clone の隣を探し、無ければ bootstrap の置き場 (`%USERPROFILE%\ghq\github.com\pollenjp\dotfiles-private`)
  を探す (一時の場所の clone から流しても見つかる)。どこを読んだかは出力の頭の「ホストの値:」に出る
- ファイルが無ければ、`check` は ⚠ を出してグループ personal の既定で確かめ、`apply` は止まる。別のファイルを使うなら `--host-file <path>`
- `runner/groups.json` は生成物 (グループごとの道具の既定。Nix がグループごとの素のホストの `group.json` を集める)。`nix/lib/groups.nix` や
  option の既定を変えたら、dotfiles の root で `nix eval --raw ./nix#lib.windowsGroupsJson > win/runner/groups.json` で出し直す (古ければ
  CI の `lint` が落ちる)

### 受け持ちを runner に切り替える

ホストごとに、dotfiles-private の同じ PR で 2 つを変える (同じものを WSL と Windows の両方が配らないように):

1. そのホストの Nix の値 (`nix/hosts/<user>@<hostname>.nix`) を `wsl.windowsFiles.enable = false` にする (WSL が Windows に触らない)
2. Windows のホストの値を `[runner] enable = true` にする (runner の apply を許す)

- 切り替える前に `dotfiles check` を流し、runner にまだ無い手順 (下の表の「まだ」) をどうするかを決める。切り替えたホストでは、まだ無い手順は
  誰も流さないので ⚠ (runner では直らない差) になる。切り替えるのは、そのホストで on の手順を全部移してから (ADR 060)
- Windows にしか無い手順 (下の表の「有る (Windows だけ)」) は、切り替える前から apply で流れる (ホストの値は要る。`runner.enable = false` のままでよい)
- 初めて apply するときは記録が無いので、中身が repo と同じファイルは「同じ」(記録だけ作る) になる。WSL と Windows の clone を同じ commit に
  しておく。違う中身は「置いた記録が無く」の衝突になる ([衝突したら](#衝突したら)と同じ解き方。PowerShell では `Copy-Item` か `--force`)
- WSL の無い Windows は、はじめから 2 だけを書く

### runner の手順

| order | id | すること | on/off | runner |
| --- | --- | --- | --- | --- |
| 5 | `bootstrap` | `bootstrap/Install-Bootstrap.ps1 -Check` (確かめるだけ。揃えるのは人が bootstrap を流す) | グループ personal | 有る (Windows だけ) |
| 50 | `claude-env` | Claude Code の `%USERPROFILE%\.claude\settings.json` の `env` に、Claude の git を無署名・GitHub は gh の資格情報 (HTTPS) で通す設定を足す ([後述](#claude-skills-と-windows-のハブ-w0-2)) | `windowsClaudeCode` | 有る (Windows だけ) |
| 50 | `claude-files` | dotfiles の `CLAUDE.md` (冒頭を Windows のものに)・skill・agent・command を `%USERPROFILE%\.claude\` へ置き (ディレクトリは junction、ファイルはコピー)、hook の口 (runner の exe の写し `hooks\dotfiles-claude.exe`) を写す ([後述](#claude-code-の設定)) | `windowsClaudeCode` | 有る (Windows だけ) |
| 50 | `claude-footer-links` | `settings.json` の `footerLinksRegexes` を `nix/files/claude/footer-links.json` にする | `windowsClaudeCode` | 有る (Windows だけ) |
| 50 | `claude-hook` | `settings.json` の `hooks` に、hook の口を exec form で登録する | `windowsClaudeCode` | 有る (Windows だけ) |
| 50 | `claude-notion` | ホストの値の `[claude.notion]` から `%USERPROFILE%\.local\state\dotfiles\claude-notion.json` を書く | `windowsClaudeCode` | 有る (Windows だけ) |
| 50 | `claude-skills` | claude-skills の clone の `skills/`・`agents/`・`commands/`・`rules/` の中身を `%USERPROFILE%\.claude\` へ (ディレクトリは junction、ファイルはコピー)。clone の場所を `%USERPROFILE%\.local\state\dotfiles\claude-skills-dir` に書く | `claudePrivateSkills` | 有る (Windows だけ) |
| 50 | `claude-statusline` | `settings.json` の `statusLine` を hook の口の status line へ向ける | `windowsClaudeCode` | 有る (Windows だけ) |
| 50 | `git-config` | git の設定 (`%USERPROFILE%\.config\git\config`・`ignore`) を、WSL の home-manager と同じ `nix/home/modules/git.toml` から置く (署名と delta は除く。[後述](#git-の設定)) | いつも (名前とメールは `gitIdentity`) | 有る (Windows だけ) |
| 55 | `pjp` | shim の `pjp` を (要れば) `cargo install` し、`pjp --build` で道具を作る | `claudePrivateSkills` | 有る (Windows だけ) |
| 60 | `claude-skill-overrides` | `settings.json` の `skillOverrides` (pjp-dev-tracker の on/off・pack の skill を名前だけ・同期された skill を隠す) を書く | `windowsClaudeCode` | 有る (Windows だけ) |
| 60 | `hc-hub` | ハブ `%USERPROFILE%\h` を `pjp hub init` で作る (作り済みなら雛形との差だけ直す) | `herdrHub` | 有る (Windows だけ) |
| 90 | `files` | `manifest.toml` のファイルを配る ([配る](#配る)と同じ判定。記録は `%LOCALAPPDATA%\dotfiles\state\windows-files.deployed.json`)。runner の clone の `core.autocrlf` が true なら ⚠ (テキストが CRLF で取り出され、WSL が配った LF と合わずに衝突になる。bootstrap の clone は false) | いつも | 有る |
| 91 | `powertoys` | PowerToys を入れ、Keyboard Manager と自動起動をオンにして割り当てを読み直させる | | まだ |
| 91 | `ssh-config` | dotfiles-private の ssh の設定を `%USERPROFILE%\.ssh` へ写す | | まだ |
| 92 | `fancyzones` | FancyZones の持つキー・カスタムレイアウト・ディスプレイへのあて方 | | まだ |
| 95 | `google-ime-install` | `Install-GoogleJapaneseInput.ps1`: 入っていなければ入れる (UAC)。ずれは知らせるだけ | いつも | 有る |
| 95 | `powershell-profile` | `$PROFILE` から `dotfiles.ps1` を読ませる | | まだ |
| 96 | `openssh` | `Install-OpenSSH.ps1`: 入っていなければ入れる (UAC)。ずれは知らせるだけ | いつも | 有る |
| 97 | `claude-code` | `Install-ClaudeCode.ps1`: 入れる・揃える (PATH のずれは知らせるだけ) | `windowsClaudeCode` | 有る |
| 97 | `herdr-app` | `Install-HerdrApp.ps1 -IfMissing`: 入れる・揃える (下げない。`-ReleasesFile` に clone の `nix/pkgs/herdr-core/releases.json`) | `windowsHerdr` | 有る |
| 97 | `herdr` | `Install-Herdr.ps1`: 入っていなければ入れる。ずれと Herdr.Herdr.Preview は知らせるだけ | `windowsHerdr` | 有る |
| 97 | `ntn` | `Install-Ntn.ps1`: 入れる・揃える (PATH のずれは知らせるだけ) | `windowsNtn` | 有る |
| 97 | `op-reason` | WSL の op の Windows の部品 (op-reason の zip) を固定した版に揃える ([op-reason](#op-reason)) | `onePassword` | まだ |
| 97 | `pin-updates` | 固定した版より新しい版の知らせ | | まだ |
| 97 | `type-clipboard` | `Install-TypeClipboard.ps1`: 入っていなければ入れる。ずれは知らせるだけ | `windowsTypeClipboard` | 有る |
| 98 | `google-ime` | Google 日本語入力の設定とユーザー辞書を組み立てて置く | | まだ |
| 98 | `hc-skill`・`herdr-app-skill` | `hc --skill`・`herdr-app --skill` に頭を足して `%USERPROFILE%\.claude\skills\{hc,herdr-app}\SKILL.md` を作る | `windowsHerdr` | 有る (Windows だけ) |
| 99 | `international`・`port-forward`・`terminal` | 日付と時刻の形式・port forwarding の組・Windows Terminal の持つキー | | まだ |

- ps1 は clone の中のものを、PATH の `pwsh` (無ければ Windows PowerShell) で `-Check` してから、WSL の wrapper と同じ判断で `-IfMissing` か
  引数なしで流す (出力は UTF-8 にしてから流す)。ps1 の締めの行の文言 (「→ Install-Ntn で揃える」など) を変えるときは
  `runner/src/steps/ps1.rs` も直す (WSL の wrapper と同じ約束)
- 待つ上限も WSL と同じ (`-Check` は 60〜120 秒、入れる・揃えるのは 300〜600 秒。Claude Code だけは 1800 秒 (約 340 MB を 2 回落とす))。
  時間切れなら pwsh を止める (子の winget までは止めない)。秒数は試験が WSL の wrapper の `timeout` と突き合わせる
- WSL にしか無い手順のうち 9 つは、移す順と移し方を ADR 060 に決めてある (powershell-profile → ssh-config・port-forward → terminal・powertoys・
  fancyzones → international → google-ime → pin-updates)。`op-reason` はその後に足したもので、この順にはまだ入っていない
- まだ無い手順の on/off は、WSL の script の `# tool:` と同じ道具の switch (行が無ければいつも)

### runner の手順を足す

1. `runner/src/steps/<名前>.rs` に trait `Step` を書く (id・order・題・on/off (`Gate`)・`windows_only` (WSL の setup に同じ手順が無く、受け持ちによらず
   runner が流すなら true) と、`Mode` (check・dry-run・apply) ごとの中身)。外の
   コマンドは `ctx.sys` で打ち (試験で偽物に差し替えられる)、置き場所は `ctx` から引く (`ctx.repo_path(…)`・隣の clone の
   `ctx.sibling("claude-skills")` (隣に無ければ bootstrap の置き場)・`ctx.roots`・記録の置き場の `ctx.state_dir`)。記録が要れば `record::Records` (files と同じ形の JSON)
2. `runner/src/steps/mod.rs` の `all()` に 1 行足す (order と script の名前の順に並ぶ)。同じファイルの試験 (`order_matches_wsl_setup`) の並びにも
   足す。Windows にしか無い手順 (W0-2 など) は WSL の script を持たなくてよい (試験が WSL の script を求めるのは、WSL から写した手順とまだ無い手順だけ)
3. 偽の `Sys` (`testutil::FakeSys`) で分かれ道を試す
4. この節の表に行を足す

WSL の側に Windows の手順 (`nix/scripts/bootstrap-windows-<id>.sh`) を足したときは、runner に写すまで `runner/src/steps/pending.rs` の `PENDING`
に足し (gate は script の `# tool:` と同じにする)、`order_matches_wsl_setup` の並びと上の表にも足す。WSL の script が一覧に無い・`# tool:` と
gate が違うと、試験が落ちる

### runner を直すとき

- `win/runner` で `cargo fmt`・`cargo clippy --all-targets -- -D warnings`・`cargo test`。CI
  ([`.github/workflows/win-runner.yml`](../.github/workflows/win-runner.yml)) は Linux と `windows-latest` (MSVC) で流し、Linux では manifest の
  読み方を `nix-instantiate` (`nix/lib/windows-files.nix`) と突き合わせる (`DOTFILES_WIN_NIX_PARITY=1`。手元でも nix-instantiate があれば流れる)
- WSL や Linux で build するには C のリンカ (`cc`) が要る。無ければ flake の nixpkgs の gcc を借りる:
  `nix shell --inputs-from ../../nix nixpkgs#gcc --command cargo test`
- toolchain は `runner/rust-toolchain.toml` (1.99.1。claude-skills と同じ)、crate は `toml`・`serde_json`・`sha2` と、trait だけを使う `serde`
  (serde_json と toml が引いている版。順を保つ JSON の型 `runner/src/ojson.rs` に使う)。版は公開から 7 日以上たったものにする (`Cargo.lock` の間接の
  依存も。cargo には猶予の設定が無いので、作り直したら crates.io の公開日時を見て、新しすぎる版は `cargo update -p <名前> --precise <前の版>` で
  下げる)。C のコンパイラが要る crate と HTTP の crate は足さない。serde_json の `preserve_order` は足さない (foldhash を引き、`Map` の並びを crate
  全体で変える)
- `manifest.toml` の書き方の決まりを変えるときは、`nix/lib/windows-files.nix` と `runner/src/manifest.rs` の両方を直す (CI が突き合わせる)
- settings.json の env に足す git の組と claude-notion.json の中身も、Linux の CI が `tests/claude_parity.rs` で、Linux の
  `nix/home/modules/claude.nix` が sandbox のホストに書く claude-env.json・claude-notion.json (`nix eval`) と突き合わせる
- git の設定 (`git-config`) は、Linux の CI が `tests/git_parity.rs` で、Linux の home-manager の `programs.git` (sandbox と作り物のホスト。`nix eval`) と
  突き合わせる (Windows に入れない署名と delta の外に値の差が無いか・書き方が home-manager の toGitINI と同じか)。どの OS でも同じにする値は
  `nix/home/modules/git.toml` を直す (git.nix に直に書いた値は Windows に届かず、この突き合わせが落ちる)
- Rust に写した Claude Code の hook・status line (`src/hooks/`) と skillOverrides (`src/steps/claude_skill_overrides.rs`) は、Linux の CI が同じ入力で
  bash の版 (`nix/files/claude/hooks/*.sh`・`statusline-command.sh`・`nix/scripts/bootstrap-claude-skill-overrides.sh`) と突き合わせる
  (`DOTFILES_WIN_BASH_PARITY=1`。手元でも bash と jq があれば流れる)。コマンドを読む 3 つの guard は、bash の版の試験 (`nix/tests/<名前>.test.sh`)
  に exe の `claude-hook <名前>` を呼ぶ包みを渡して流し (`tests/guard_suites.rs`)、lexer (`src/hooks/guard/lex.rs`) は awk と突き合わせる。hook の
  登録 (`src/steps/claude_hook.rs` の `REGISTRATIONS`) は `bootstrap-claude-hook.sh` の同じ hook の行と突き合わせる。bash の版を直したら、Rust の
  写しも同じに直す

### claude-skills と Windows のハブ (W0-2)

claude-skills (private な skill 置き場。Rust の道具の入口 `pjp`) を Windows の Claude Code で使い、herdr-app と hc のハブ `%USERPROFILE%\h` を作る
手順 (claude-skills の spec `docs/superpowers/specs/2026-11-15-windows-herdr-app-hc-design.md` の §9 の Windows の項目。経緯は dotfiles-private の
ADR 064 (`docs/adr/064_win_w02_claude_skills_hub_*`))。どれも Windows にしか無い手順なので、受け持ちが WSL のホストでも `dotfiles apply` が流す
(ホストの値は要る)。Linux の側は `nix/README.md` の「claude-skills の Rust の道具 (shim の pjp)」と「hc の skill」。

```powershell
# runner は clone を取得しない。先に 3 つの clone を進める (gh の資格情報で HTTPS を通す。SSH の鍵を使わない)
foreach ($r in 'dotfiles', 'dotfiles-private', 'claude-skills') {
    git -c url.https://github.com/.insteadOf=git@github.com: -c credential.helper= -c 'credential.helper=!gh auth git-credential' `
        -C "$HOME\ghq\github.com\pollenjp\$r" pull --ff-only
}
dotfiles check                     # W0-2 の手順の差も出る (何も書かない)
dotfiles apply --dry-run           # することを出す
dotfiles apply                     # 受け持ちが WSL なら、Windows にしか無い手順だけを流す
pjp doctor                         # shim・clone・toolchain・外の道具を確かめる (新しい PowerShell で)
```

| 手順 | すること | 気をつけること |
| --- | --- | --- |
| `claude-env` | `settings.json` の `env` に `GIT_CONFIG_*` (commit・tag を無署名に・GitHub の ssh の URL を https に読み替え・資格情報を `gh auth git-credential` から) と、`CLAUDE_CODE_PLUGIN_PREFER_HTTPS=1`・`GCM_INTERACTIVE=never` を足す。Linux の `bootstrap-claude-env.sh` と同じ書き方 (この手順のキーの古い組を外し、ほかの組は残して番号を振り直す) | ほかのキーと順は残す。書く前の中身を `%LOCALAPPDATA%\dotfiles\state\claude-settings\backup\` に写す (10 回分)。Git for Windows の system の設定には Git Credential Manager (`credential.helper = manager`) があり、gh より先に呼ばれる。窓を出して止まらないよう `GCM_INTERACTIVE=never` を足す (gh で通った token は GCM にも保存される)。空の値で helper を消す組は足さない (Windows では空の値の env が消えやすく、欠けると git が全部落ちる) |
| `claude-notion` | ホストの値の `[claude.notion]` から `claude-notion.json` を書く | dotfiles が持つファイルなので、違えば書き直す |
| `claude-skills` | clone の中身を 1 つずつ `~/.claude/<種類>/` へ。ディレクトリは junction (`cmd /c mklink /J`)、ファイル (`rules/*.md` など) はコピー (記録 `%LOCALAPPDATA%\dotfiles\state\claude-skills.deployed.json`) | README.md は除く。同じ名前の実体 (手で置いたディレクトリなど)・別の先へのリンク・記録の無い違う中身のコピーは飛ばして ⚠ で知らせる (コピーは `--force` で上書き)。clone から消えたものは外す (junction の先は消さない)。ファイルはコピーなので、clone を pull したら `dotfiles apply` で写し直す |
| `pjp` | shim が無い・起きない・版が違うときだけ `cargo install --locked --root <CARGO_HOME> --target-dir <使い捨て> --path <clone>\crates\pjp-shim` (clone の中で、clone の toolchain で) を打ち、毎回 `pjp --build` | pjp を使っている会話・端末 (ハブの hook の `pjp hub guard` など) があると、shim の入れ替えが落ちることがある。入れた直後の `pjp` は新しい PowerShell で (rustup が `~/.cargo/bin` を PATH に足している) |
| `hc-hub` | `pjp hub check` で差を見て、差があれば `pjp hub init` (引数なし。`%USERPROFILE%\h`) | まだハブでない場所に雛形の外のものがある・別の repo の中などでは、`pjp hub init` が何も書かずに止まる (runner は ⚠ でわけを出す)。ハブで動いている Claude Code の会話には、作った後から hook (`pjp hub guard`) が効く |
| `hc-skill`・`herdr-app-skill` | `<道具> --skill` に頭 (frontmatter と版のコメント) を足して `~/.claude/skills/<道具>/SKILL.md` | 道具は PATH → 公式の置き場所 (`%LOCALAPPDATA%\Programs\herdr-core\hc.exe`・`…\herdr-app\herdr-app.exe`) の順に探す。手で置いた写しも書き直す。道具を上げたら `dotfiles apply` で作り直る |

- junction を手で外すなら `cmd /c rmdir "%USERPROFILE%\.claude\skills\<名前>"` (先は消えない)。Windows PowerShell 5.1 の `Remove-Item -Recurse` を junction に
  打たない (先の中身まで消すことがある)
- dotfiles の `CLAUDE.md`・skill・hook・status line・skillOverrides は次の節 ([Claude Code の設定](#claude-code-の設定))
- まだ後の PR: ハブの見回り役 `pjp-hubd` を立てる (claude-skills の W2-3 の後)・plugin・`c` の `--no-chrome`・Defender の除外・pjp-spaces・
  `~/.config/pjp/env`・runner の `self-update`

### Claude Code の設定

Windows の Claude Code (herdr-app のハブ) に、WSL の Claude Code と同じ決まり (dotfiles の `nix/files/claude/` の `CLAUDE.md`・skill と、settings.json の
hook・status line・skillOverrides・footer のリンク) を配る手順。Linux では `nix/home/modules/claude.nix` (home-manager) がファイルを置き、
`nix/scripts/bootstrap-claude-{hook,statusline,footer-links,skill-overrides}.sh` が settings.json に書く。Windows では runner の 5 つの手順が同じことをする
(経緯は dotfiles-private の ADR 065 (`docs/adr/065_win_claude_config_*`))。どれも Windows にしか無い手順なので、受け持ちが WSL のホストでも
`dotfiles apply` が流す (ホストの値は要る)。

```powershell
dotfiles check --steps claude-files,claude-hook,claude-statusline,claude-footer-links,claude-skill-overrides   # 差を見る (何も書かない)
dotfiles apply --dry-run                                                                                      # することを出す
dotfiles apply                                                                                                # 揃える
```

| 手順 | すること | 気をつけること |
| --- | --- | --- |
| `claude-files` | `CLAUDE.md` を、`claude-code/CLAUDE.windows.md` (Windows の冒頭) + 空行 + `nix/files/claude/CLAUDE.md` の最初の「## 」の行から後ろ (+ `devTracker` のホストは空行と `CLAUDE.dev-tracker.md`) にして置く (改行は LF)。`nix/files/claude/{skills,agents,commands}/` の中身を 1 つずつ置く (ディレクトリは junction、ファイルはコピー。`claude-code/skip-skills.txt` の skill は張らず、前に張ったものは外す)。runner の exe を `%USERPROFILE%\.claude\hooks\dotfiles-claude.exe` に写す (hook と status line の口) | `CLAUDE.md` とファイルは記録つきのコピー (`%LOCALAPPDATA%\dotfiles\state\claude-files.deployed.json`)。Windows 側で変えた・記録の無い違う中身は衝突で飛ばす (dotfiles に取り込むか、`dotfiles apply --steps claude-files --force` で上書き)。exe は dotfiles が持つ生成物で、違えば書き直す。動いている exe は上書きできないので、退けてから置く (退けたものは次に消す) |
| `claude-hook` | `settings.json` の `hooks` に、hook の口を exec form (`command` に exe の絶対パス、`args` に `claude-hook <名前>`) で登録する。event・matcher・if は Linux の `bootstrap-claude-hook.sh` の同じ hook の行と同じ。ただしコマンドを読む hook は PowerShell の tool にも登録する (matcher の `Bash` は `Bash\|PowerShell`、if で絞る pr-assignee-nudge は `PowerShell(gh pr create *)` の組も足す) | shell を通さないので、Git Bash が見つからない会話でも PowerShell が command を読まない (shell form の PreToolUse の hook は、Git Bash が無いと失敗が tool を止めうる)。この手順の口 (`dotfiles-claude.exe`) の登録で今は入れない組は外す。ほかの hook (ハブの `pjp hub guard` などのプロジェクトの hook は別のファイル) とキーの順は残す |
| `claude-statusline` | `settings.json` の `statusLine` を `~/.claude/hooks/dotfiles-claude.exe claude-statusline` にする (別の値は置き換える) | status line は Git Bash (無ければ PowerShell) が読む shell の文なので、Claude Code の docs のとおり `~` と `/` で書く |
| `claude-footer-links` | `settings.json` の `footerLinksRegexes` を `nix/files/claude/footer-links.json` で丸ごと置き換える (cc-page の規則の port は cc-pages の既定の 7777) | 手で足した項目も消える (Linux と同じ。足すなら repo の `footer-links.json`) |
| `claude-skill-overrides` | `settings.json` の `skillOverrides` に、`pjp-dev-tracker` (ホストの値の `devTracker` で on / off)・pack の skill (入口 `pjp-pack-<pack>` があれば `name-only`)・claude.ai から同期された skill (`anthropic-skills:<名前>` を `user-invocable-only`) を書く。選び方は Linux の `bootstrap-claude-skill-overrides.sh` と同じ | 書いた key は `%LOCALAPPDATA%\dotfiles\state\claude-skill-overrides.applied.json` に控え、書かなくなったら戻す。手で別の値を書いた key には触らない。order は 60 (claude-files と claude-skills が skill をつないだ後) |

- settings.json を書く手順 (`claude-env` も) は、どれも自分の持つキーだけを直し、ほかのキーと順を残す。キーの順を見ずに同じなら書かない。書く前の中身を
  `%LOCALAPPDATA%\dotfiles\state\claude-settings\backup\` に写す (手順をまたいで、いちばん古いもの (dotfiles の手順が初めて書く前の中身) と新しい方から 10 個)
- 効くのは新しい Claude Code の会話から (hook・status line・skillOverrides。footer のリンクは実行中の会話にも次の turn から)。確かめるのは Claude Code の
  `/hooks`・`/skills` と、status line の表示
- `dotfiles-claude.exe` は runner の exe の写しで、`claude-hook`・`claude-statusline` だけを受ける (ほかのコマンドは何もせずに知らせる。古い写しで runner
  を流さない。登録の `args` が欠けて引数なしで呼ばれても tool を止めないよう、終了コードは 0)。runner を作り直したら (clone を pull したら) `dotfiles apply`
  で写し直す

Windows に入れる hook と status line (Linux の `nix/files/claude/hooks/` の 12 個の hook と `statusline-command.sh`)。Windows の Git Bash には jq が無く
(Git for Windows が同梱しない)、bash の hook は黙って何もしないので、入れるものは Rust に写した (`runner/src/hooks/`。ふるまいと文は bash の版と同じで、
Linux の CI が同じ入力で突き合わせる)。Windows の Claude Code は PowerShell の tool を主の shell にする (Bash だけの matcher の hook は走らない) ので、
コマンドを読む hook は PowerShell の tool のコマンドも PowerShell の書き方で読む (`runner/src/hooks/guard/pslex.rs`。通す口は `$env:PJP_ALLOW_XREF='1';`
のように PowerShell の形。決めたことは dotfiles-private の `docs/adr/067_win_hook_guards_*`):

| hook | Windows | わけ |
| --- | --- | --- |
| `docs-guard.sh` | Rust に写して入れる | 小さい。Windows のパス (`C:\…`) も読み、`docs` の大文字小文字を区別しない (bash の版は `/` で始まらないパスを相対パスと読み、Windows では止めない) |
| `run-through-nudge.sh` | Rust に写して入れる | 小さい (文を返すだけ) |
| `pr-assignee-nudge.sh` | Rust に写して入れる | 小さい (コマンドの読み方の jq の式 1 つ)。Windows の会話で PR を作ったときに効く (PowerShell の tool で打った `gh pr create` にも) |
| `statusline-command.sh` | Rust に写して入れる | 毎回の表示に要る。cc-pages の 📄top は cc-pages が PATH にあるときだけ (今の Windows には無い) |
| `xref-guard.sh`・`gist-guard.sh`・`install-iac-guard.sh` | Rust に写して入れる (`runner/src/hooks/guard/`。awk の lexer は `lex.rs` に 1 つ) | Windows の会話で public な repo へ push・PR を出す、gist に上げる、system へ install するときも止める。bash の版の試験 (`nix/tests/<名前>.test.sh`) をそのまま Rust の口にも流す。Windows だけの足し: `pwsh -Command`・`cmd /c` の中も読む。`wsl` の後ろの git push は押す commit を Windows から読めないので、押す先が private と分からなければ止める。install-iac-guard は winget・scoop・choco の install と PowerShell の module の install も止め、IaC の guard を外す口は無い (いつも止める) |
| `video-offer-nudge.sh`・`lang-nudge.sh` | まだ (後の PR) | Windows のハブは spec・ADR・PR・project を自分では作らない (Linux の子が作る)。解説動画は CLAUDE.md の節が聞かせる |
| `nix-managed-guard.sh` | 入れない | `/nix/store` が無い。runner が置くのはコピー (変えると次の apply が衝突で知らせる) と clone への junction で、直し方は `CLAUDE.md` の冒頭に書いた |
| `op-reason-guard.sh` | 入れない | WSL の op の包み (op-reason) を守るもの。Windows の op は op.exe そのもの |
| `footer-links-archive.sh` | 入れない | cc-pages が Windows に無い (claude-skills の spec も Windows の cc-pages は扱わない) |
| `ssh-agent-notice.sh` | 入れない (前提が違う) | WSL の ssh は Windows の ssh.exe を包み、承認の画面がどこに出るかを知らせる hook。Windows の Claude の git は gh の HTTPS (`claude-env`) で SSH の鍵を使わず、Git Bash の ssh は 1Password の agent (Windows の named pipe) を使わない。承認の画面は、ユーザーが見ている Windows の画面に出る |

### git の設定

WSL の home-manager の `programs.git` (`nix/home/modules/git.nix`) と同じ中身の git の設定を、Windows の `%USERPROFILE%\.config\git\` に置く手順
`git-config`。Windows にしか無い手順なので、受け持ちが WSL のホストでも `dotfiles apply` が流す (ホストの値は要る)。どの OS でも同じにする値
(名前とメール・pollenjp-sub の名前とメール・alias・core など・ignore) は `nix/home/modules/git.toml` にだけ書き、git.nix と runner が同じファイルを読む
(経緯は dotfiles-private の ADR 066 (`docs/adr/066_win_git_config_*`))。

```powershell
dotfiles check --steps git-config                  # 差を見る (何も書かない)
dotfiles apply --dry-run                           # することを出す
dotfiles apply                                     # 揃える
git config --list --show-origin --show-scope       # どのファイルのどの値が効いているか
```

| 置くもの | 中身 |
| --- | --- |
| `config` | git.toml の `[settings]`・`[user]` (`gitIdentity` が true のとき)・`[filter "lfs"]` を home-manager と同じ形 (節とキーは名前の順) で並べ、`gitIdentity` なら後ろに owner ごとの `[includeIf "gitdir/i:~/ghq/github.com/<owner>/"]` |
| `config.<owner>` | owner (今は pollenjp-sub) の `[user]`。上の includeIf が読む (`gitIdentity` のときだけ) |
| `ignore` | git.toml の `ignores` (git が既定で読む全体の ignore) |

WSL と違うもの:

| もの | WSL | Windows | わけ |
| --- | --- | --- | --- |
| 1Password の署名 (`commit.gpgSign`・`tag.gpgSign`・`[gpg]`) | `onePassword.enable` のホストで書く | 書かない | Windows には入れない (Claude の commit は `claude-env` の env で無署名) |
| delta (`pager.<diff・log・show・blame>`・`interactive.diffFilter`・`[delta]`) | 書く | 書かない | Windows に delta が無い |
| `[filter "lfs"]` の git-lfs | `/nix/store` のパス | PATH の `git-lfs` | Git for Windows に同梱 (system の設定にも同じ 4 つがある) |
| pollenjp-sub の includeIf の条件 | `gitdir:~/workdir/github.com/pollenjp-sub` | `gitdir/i:~/ghq/github.com/pollenjp-sub/` | Windows の ghq の root は `%USERPROFILE%\ghq`。末尾の `/` でその下の repo に当て、`/i` で大文字小文字を区別しない。WSL の条件は旧い ghq の root (`~/workdir`) の写しで末尾に `/` が無く、今は何にも当たらない (WSL のふるまいは変えていない) |
| ignore の `.direnv/` | direnv の module が足す | 足さない | Windows に direnv が無い |
| credential helper | 書かない | 書かない | bootstrap が gh に書かせない決まりと、`claude-env` が settings.json の env に足す組を壊さない |

- 置き方は `CLAUDE.md` と同じ記録つきのコピー (`%LOCALAPPDATA%\dotfiles\state\git-config.deployed.json`)。git.toml が変われば `dotfiles apply` で書き直す。
  Windows 側で変わった・記録の無い違う中身は衝突で飛ばして ⚠ で知らせる (dotfiles の git.toml へ取り込むか、`dotfiles apply --steps git-config --force` で
  上書き)。書かなくなったファイル (`gitIdentity` を外したときの `config.<owner>`) は、中身が記録どおりなら消す
- `~/.gitconfig` が無いと、`git config --global` (gh の `auth setup-git` なども) はここの `config` に書き、次の `dotfiles check` が衝突で知らせる。Windows だけの
  設定は `~/.gitconfig` に書く (`git config --file "$HOME\.gitconfig" <キー> <値>`)。git は `~/.config/git/config` の後に `~/.gitconfig` を読むので同じキーは
  `~/.gitconfig` が勝ち、`~/.gitconfig` があれば `git config --global` もそこへ書く。`~/.gitconfig` がある間は、締めの表の ※ にそう添える
- `gitIdentity` が false のホスト (自社・客先) には名前もメールも書かない (WSL と同じ。git は commit の前に止まる)。そのホストで使う名前とメールは `~/.gitconfig` に書く
- `core.autocrlf = false` が Git for Windows の system の `true` より先に効く (WSL と同じく、取り出すときに LF を CRLF にしない)。repo に `core.autocrlf` を
  書いていない既にある clone のうち、作業ツリーが CRLF で取り出されたものは、触ったファイルが変わったように見えることがある (`git ls-files --eol` の
  `i/lf w/crlf` の行)。その repo に `git config core.autocrlf true` を書けば今までどおり。bootstrap の clone は repo に `false` を書いてある
- git は `XDG_CONFIG_HOME` があれば `%XDG_CONFIG_HOME%\git\config` を、無ければ `$HOME\.config\git\config` を読む。どちらかの環境変数で git が別の場所を
  読むなら ⚠ で知らせる (ここに置いた設定は効かない)

## 配る

WSL で流す。`home-manager switch` だけでは Windows 側に届かない。runner の `dotfiles check --steps files` は、同じ判定を Windows の側で出す
([runner](#runner-windows-の側で確かめて揃える))。

```sh
~/dotfiles/setup --update                          # switch + bootstrap をまとめて
nix/scripts/bootstrap-windows-files.sh             # 配る部分だけ (この checkout の win/ を配る)
nix/scripts/bootstrap-windows-files.sh --dry-run   # 判定だけ見る
```

- 配るのは `dotfiles.wsl.windowsFiles.enable = true` のマシンだけ (dotfiles-private に登録したファイルか、
  `~/dotfiles/flake.nix` に足したホストで書く。公開の登録簿の型には入らない)。SSH 鍵も gh のログインもまだの新しい
  WSL の PC は、`setup-local-flake.sh --initial` が書く初期用のホスト `initial` が有効にするので、1 回目の setup から配って
  Windows のアプリも入れる ([`nix/README.md`「新しい WSL の PC」](../nix/README.md#新しい-wsl-の-pc))
- 配り先の `/mnt/c/Users/<名前>` は `dotfiles.wsl.windowsUserName` で決まる
- 配るのは setup を流した checkout の作業ツリー。commit していない変更も配られる
- 置いたファイルをアプリが読み直すとは限らない。書き換えたときは manifest の `hint` が出る
  (Orca なら「設定 → キーボードショートカット → ディスクから再読み込み」)

## ファイルを足す

1. `win/<アプリ>/` に置く。今の設定から始めるなら Windows 側からコピーする
2. `manifest.toml` に `[[files]]` を 1 つ足す
3. `nix/scripts/bootstrap-windows-files.sh --check` で検証し、`--dry-run` で判定を見る
4. commit して `~/dotfiles/setup --update`

```toml
[[files]]
src = "orca/keybindings.json"                  # win/ からの相対パス
dst = "%USERPROFILE%/.orca/keybindings.json"   # Windows 側の置き先
hint = "Orca の設定 → キーボードショートカット → 「ディスクから再読み込み」"   # 任意
```

- `dst` は `%USERPROFILE%` / `%APPDATA%` / `%LOCALAPPDATA%` のどれかで始める。区切りは `/`
- 書けるキーは `src` / `dst` / `hint` / `base` だけ。`..` と `\` は書けない
- `base = "nix"` の表だけ、`src` は repo 直下の `nix/` からの相対パスになる (既定は `"win"`)。Linux の home-manager も同じファイルを
  読むときに使う (home-manager からは `nix/` しか見えないので、1 か所は `nix/` に置く。今は herdr の固定した版の `releases.json`)
- 大文字小文字だけが違う `dst` は重複として止まる (Windows では同じファイル)
- 今の設定をそのまま取り込んだなら、1 回目は「同じです」になり記録だけが作られる
- manifest から消したファイルは Windows 側から消さない

## 衝突したら

Windows 側でファイルが変わっていた (アプリの設定画面で変えた、など) と、上書きせずに
diff を出して止まる。`setup --update` はこの手順 (order 90) で失敗して止まる。前の手順は済んで
いるが、後ろの bootstrap (91〜99) と wsl-mtu-guard・exe-exec-trace、最後の「残りの手作業」は、直して
流し直すまで走らない。

```sh
# Windows 側の変更を残す: win/ へ取り込んで流し直す (中身が揃うので記録だけ更新される)
cp /mnt/c/Users/<名前>/.orca/keybindings.json win/orca/keybindings.json
nix/scripts/bootstrap-windows-files.sh
git add win/orca/keybindings.json && git commit

# repo 側で上書きする
nix/scripts/bootstrap-windows-files.sh --force
```

判定は「前回ここへ置いた中身の sha256」(`~/.local/state/dotfiles/windows-files.deployed.json`)
と比べて行う。置き先が記録どおりなら、変えたのは repo 側なので黙って上書きする。

置いた記録が無いのに、repo と違う中身の置き先が既にある (初めて配るマシンで、アプリが作っていた・
手で設定してあった) ときも衝突になり、「置いた記録が無く」と出る。手で同じ設定をしてあっても、id や
書式が違えばバイト列は揃わない ([PowerToys](#powertoys) など)。diff を見て、違いがそれだけなら
`--force` で上書きしてよい。

## winget の pin

winget で版を固定して入れるもの (OpenSSH・herdr・Google 日本語入力・ntn・Claude Code と、[bootstrap](#bootstrap-新しい-windows-で最初に流す) が
入れる 4 つ) は、入れた後に `winget pin add --id <ID> --exact` で pin (種類は Pinning) を足し、`winget upgrade --all` から外す。版を変えるときに
自分の pin に止められない打ち方は、winget の作り (`microsoft/winget-cli` の `WorkflowBase.cpp`・`PinningData.cpp`) に合わせて決めてある
([ADR 063](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/063_win_winget_pin_include_pinned_20261116T132001JST/README.md)):

| 打つもの | pin (Pinning) があるとき |
| --- | --- |
| 入っているものへの `winget upgrade --id <ID> --exact --version <版>` | 止められる (終了コード `0x8A150068`。版を名指しすると、名指しの upgrade でも pin を見る) |
| 上に `--include-pinned` を付ける | 通る (Pinning を越える。Blocking の pin と、Gating の pin の範囲の外は越えない) |
| 入っているものへの `winget install --version <版>` | 止められる (upgrade の道に移る。install は `--include-pinned` を受け付けない) |
| 入っていないものへの `winget install`・`winget uninstall`・`winget download` | pin を見ない (pin が残っていても) |

- 上げる道は `--include-pinned` を付けた upgrade (OpenSSH・Google 日本語入力)、入れ替える道は uninstall → install (herdr・ntn・Claude Code。
  入っていない形にしてから入れるので pin を見ない)。どちらも `*.Tests.ps1` が確かめる (upgrade には `--include-pinned` を付け、install・
  uninstall には付けない)
- 手で揃えるときも、版を名指しした upgrade に `--include-pinned` を付ける (bootstrap の ※ の行と[版のずれを手で揃える](#版のずれを手で揃える))。
  pin は付いたまま残る
- `0x8A150068` で落ちたら (pin を Blocking・Gating に替えた・入っていると winget が見ているのに install を打った)、OpenSSH と Google 日本語入力は
  pin の確かめ方と外し方を ※ で添える。`winget pin remove --id <ID> --exact` で外して打ち直すと、揃えた後に pin を足し直す

## winget の新しい版を確かめる

winget で版を固定しているもの (OpenSSH・herdr・Google 日本語入力・ntn・Claude Code と、[bootstrap](#bootstrap-新しい-windows-で最初に流す) が
入れる Git for Windows・GitHub CLI・Visual Studio Build Tools・rustup) は、新しい版が出ると `setup --update` が
短く知らせる ([固定した版より新しい版の知らせ](#固定した版より新しい版の知らせ)。上げるかは Claude Code に聞かれて決める)。
それとは別に、流さない間も気付けるよう、GitHub Actions の
`winget-versions` ([`.github/workflows/winget-versions.yml`](../.github/workflows/winget-versions.yml)) が
週 1 回 (月曜の朝) と、固定した版や見送りの一覧を変える PR で確かめ、新しい版が出て 30 日たつと落ちて知らせる
([TKT-110](https://app.notion.com/p/Windows-OpenSSH-Win32-OpenSSH-3f179149a66f81eaa691e12ef3e0b86c)、
[TKT-156](https://app.notion.com/p/herdr-Google-windows-openssh-1-3fa79149a66f81ee8d2bd07a0769cab0))。
名前ごとに別の job で、落ちた定期実行の通知は `nix.yml` の closure-scan と同じく GitHub から届く。

| 名前 | 固定した版 (`-Version` の既定値) と見送りの一覧 | 出た日 (猶予を数える起点) | 手順 |
| --- | --- | --- | --- |
| `openssh` | `openssh/Install-OpenSSH.ps1`・`openssh/skipped-versions.txt` | GitHub の release (`PowerShell/Win32-OpenSSH`) が出た日 | [OpenSSH の新しい版が出たとき](#openssh-の新しい版が出たとき) |
| `herdr` | `herdr/Install-Herdr.ps1`・`herdr/skipped-versions.txt` | GitHub の安定版の release (`herdrdev/herdr` の `vX.Y.Z`) が出た日 | [herdr の新しい版が出たとき](#herdr-の新しい版が出たとき) |
| `google-japanese-input` | `google-japanese-input/Install-GoogleJapaneseInput.ps1`・`google-japanese-input/skipped-versions.txt` | winget-pkgs に載った日 (GitHub の release が無い) | [Google 日本語入力の新しい版が出たとき](#google-日本語入力の新しい版が出たとき) |
| `ntn` | `ntn/Install-Ntn.ps1`・`ntn/skipped-versions.txt` | winget-pkgs に載った日 (GitHub の release が無い。配布物は ntn.dev) | [ntn の新しい版が出たとき](#ntn-の新しい版が出たとき) |
| `claude-code` | `claude-code/Install-ClaudeCode.ps1`・`claude-code/skipped-versions.txt` | GitHub の release (`anthropics/claude-code` の `vX.Y.Z`) が出た日 | [Claude Code の新しい版が出たとき](#claude-code-の新しい版が出たとき) |
| `git` | `bootstrap/Install-Bootstrap.ps1` の `-GitVersion`・`bootstrap/skipped-versions/git.txt` | GitHub の release (`git-for-windows/git` の `v<X.Y.Z>.windows.<N>`。winget の版は N が 1 なら `X.Y.Z`、ほかは `X.Y.Z.N`) が出た日 | [bootstrap の固定した版の新しい版が出たとき](#bootstrap-の固定した版の新しい版が出たとき) |
| `gh` | `bootstrap/Install-Bootstrap.ps1` の `-GhVersion`・`bootstrap/skipped-versions/gh.txt` | GitHub の release (`cli/cli` の `vX.Y.Z`) が出た日 | 同じ |
| `vs-buildtools` | `bootstrap/Install-Bootstrap.ps1` の `-VsBuildToolsVersion`・`bootstrap/skipped-versions/vs-buildtools.txt` | winget-pkgs に載った日 (GitHub の release が無い) | 同じ |
| `rustup` | `bootstrap/Install-Bootstrap.ps1` の `-RustupVersion`・`bootstrap/skipped-versions/rustup.txt` | winget-pkgs に載った日 (tag だけで GitHub の release を出さない) | 同じ |

- 確かめるのは `nix/scripts/check-winget-version.sh <名前>`。ps1 から固定した版とパッケージ ID (`$packageId`。bootstrap の 4 つは
  名前ごとの param (`-GitVersion` など) と ID の変数 (`$gitPackageId` など)) を読み、
  winget-pkgs (`manifests/<頭文字>/<ID の . を / に>/<版>/`) と、出た日を引く先を GitHub API で読むので、
  Windows は要らない。手元で打つなら gh のログインが要る:

  ```sh
  nix/scripts/check-winget-version.sh herdr   # 0 = 知らせることは無い、1 = 知らせることがある、2 = 確かめられなかった
  ```

- 新しい版は、出てから 30 日 (猶予) は落とさずに待つ。待つ間は、実行の画面に notice (版・出た日・あと何日で
  知らせるか) が出る。summary にも ※ の行で出る
  - 追いついていない版がいくつかあるときは、いちばん早く出た版の日から数える。遅れ始めてから 30 日で知らせ、
    新しい版が続けて出ても先送りしない
  - 見送った版は数えない。猶予の中に上げるか見送るかを決めておけば、落ちずに済む
  - 30 日は script の先頭の `grace_days` の 1 か所で決める (どの名前でも同じ)
- 猶予がたって落ちる (exit 1) のは:
  - 固定した版より新しい版が winget にある (見送りの一覧に無いもの) → 名前ごとの手順で、上げるか見送るかを決める。
    出た日が分からない (合う release や commit が無い) ときは、待たずに落ちる
  - GitHub に出た版が winget のこのパッケージに無い (OpenSSH・herdr・Claude Code・git・gh だけ。パッケージ ID が移ると、古い ID には
    新しい版が来ない) → 下の「パッケージ ID を確かめる」
- 猶予を置かずに落ちる (exit 1) のは、新しい版の知らせではなく、壊れていることの知らせ:
  - 固定した版が winget に無い (新しいマシンで入れられない) → winget にある版を選び直す
  - パッケージが winget に無い (`Microsoft.OpenSSH.Beta` は 2025-04-09 に全部の版が外された)
    → 下の「パッケージ ID を確かめる」
  - 版の形でないディレクトリがある・GitHub の最新の release から版が読めない・取った release に winget に載る側の
    ものが無い (版や名前の付け方、出し方が変わった) → script の読み方を直す
- パッケージ ID を確かめる: job が出す `winget search …` (`OpenSSH`・`herdr`・`JapaneseIME`・`ntn`・`ClaudeCode`・`Git.Git`・`GitHub.cli`・
  `BuildTools`・`Rustup`) で今のパッケージ ID を
  確かめる。移るなら `git grep <今の ID>` で出る所 (ps1 の `$packageId` と状態の表・bootstrap の見分け・テスト) と
  固定した版を直す
- 確かめられずに落ちる (exit 2) のは、GitHub API の失敗・ps1 から版か ID が読めない・見送りの一覧の書き損じ。
  出た日を引く一覧 (GitHub の release・winget-pkgs の commit) だけが取れないときも、新しい版が猶予の中かを
  決められないので exit 2 になる。summary の `!!` の行を見て、一時的な失敗なら流し直し、書き損じなら直す
- 見送るときは、その名前の `skipped-versions.txt` に「版 理由」を 1 行足して commit する。その版では落ちなくなり、
  もっと新しい版が出ると、その版が出てから 30 日でまた落ちる。固定した版以下になった行は消してよい (job が
  「消してよい」と出す)。このファイルは manifest に無いので Windows へは配らない
- 猶予がたった新しい版がある間は、別の理由で ps1 や script を直す PR も赤くなる (merge は止まらない)。
  どれか 1 つを変えた PR でも、全部の job が走る

## 固定した版より新しい版の知らせ

Windows に固定した版で入れているものに新しい版が出たら、`setup --update` の手順 `nix/scripts/bootstrap-windows-pin-updates.sh`
(order 97) が、その旨だけを短く出す。上げるかは、Claude Code に「dotfiles の Windows に固定した版を上げて」と頼んで決める。
依存の更新の skill がこの repo の拡張 (`.claude/skills/pjp-dotfiles-deps/`) を読み、猶予ごと (1 日・3 日・7 日) の上げ先の候補を
出して、上げるか (どの版か・上げないか) を聞き、選んだ版で PR を作る ([ADR 055](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/055_win_ntn_claude_code_pin_updates_20261114T185136JST/README.md)・[ADR 056](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/056_dep_update_repo_extension_20261115T100845JST/README.md))。

```text
⚠️  [bootstrap-windows-pin-updates] Windows に固定した版より新しい版があります → Claude Code に「dotfiles の Windows に固定した版を上げて」と頼み、上げるか (どの版か) を決める
    Windows の ntn: 0.23.28 → 0.23.29・0.23.30
    Windows の herdr-app: 0.1.13 → 0.1.14・0.1.15
```

| 名前 | 固定した版 | 新しい版の一覧と出た日 | 見送りの一覧 |
| --- | --- | --- | --- |
| `openssh`・`herdr`・`google-japanese-input`・`ntn`・`claude-code` | `win/<名前>/Install-*.ps1` の `-Version` の既定値 | `nix/scripts/check-winget-version.sh --json` (winget-pkgs の版。出た日は [winget の新しい版を確かめる](#winget-の新しい版を確かめる) の表と同じ) | `win/<名前>/skipped-versions.txt` (「版 理由」) |
| `herdr-app`・`herdr-core` | `nix/pkgs/herdr-core/releases.json` | `nix/scripts/check-herdr-app-version.sh --json` (GitHub の tag のうち Windows の成果物があるもの。出た日は成果物の Last-Modified) | `nix/pkgs/herdr-core/skipped-versions.txt` (「app か core・版・理由」) |
| `git`・`gh`・`vs-buildtools`・`rustup` | `win/bootstrap/Install-Bootstrap.ps1` の名前ごとの param (`-GitVersion` など) の既定値 | `nix/scripts/check-winget-version.sh --json` (出た日は [winget の新しい版を確かめる](#winget-の新しい版を確かめる) の表と同じ) | `win/bootstrap/skipped-versions/<名前>.txt` (「版 理由」) |

- 対象は Windows へ配るマシン (`dotfiles.wsl.windowsFiles.enable = true`) だけ。ntn・Claude Code・herdr (herdr-app・herdr-core も) は、
  入れるマシン (`windowsFiles.ntn.enable`・`windowsFiles.claudeCode.enable`・`windowsFiles.herdr.enable`) でだけ確かめる。bootstrap の
  4 つ (git・gh・vs-buildtools・rustup) は、Windows の ghq に dotfiles の clone がある (`<windowsHome>/ghq/github.com/pollenjp/dotfiles/.git`
  がある。bootstrap を流した) マシンでだけ確かめる。下の `--candidates` と JSON の口は、このマシンで入れるかによらず全部を出す
- 知らせるのは、固定した版より新しく、見送っていない版。新しい版の数が 4 つ以上なら、頭と末尾と個数だけを出す。無ければ「無い」の
  1 行だけ (警告のまとめには載らない)
- setup では出た日を引かない (GitHub API を名前ごとに 1〜2 回。合わせて数秒)。gh のログインが要る
- 確かめられないとき (gh が無い・ログインしていない・ネットに出られない・API の制限) は、setup を止めずに、確かめられなかった名前と
  わけを 1 行出す (警告のまとめにも載る)
- 猶予ごとの上げ先の候補は、次で出す (手で打ってよい):

  ```sh
  nix/scripts/bootstrap-windows-pin-updates.sh --candidates [--grace 1,3,7] [<名前>…]
  ```

  名前ごとに、新しい版 (出た日・何日前・URL、見送った版は理由)・猶予ごとの上げ先 (その日数以上たった、見送っていない新しい版の
  うち、いちばん新しいもの。出た日の分からない版は選ばない)・上げ方の節・見送りの一覧の場所を出す。依存の更新の skill は、同じものを
  JSON で読む (`--candidates --json`。固定した版だけなら、ネットワークを使わない `--list --json`。形は script の先頭)
- 見送ると、今出ている新しい版は次から setup も CI も知らせない (もっと新しい版が出たらまた知らせる)
- 対象の外: type-clipboard と op-reason (どちらも自作のアプリで、公開からの猶予を置かない。版は Release を出す流れで上げる。
  [後述](#type-clipboard-の新しい版を出したとき)・[後述](#op-reason-の新しい版を出したとき)) と PowerToys (版を固定しない)
- 週 1 回の CI (`winget-versions`・`herdr-app-installers`) は今までどおり、猶予 (30 日・7 日) がたつと落ちて知らせる

## PowerShell のテスト

`win/*/*.Tests.ps1` (`Install-OpenSSH.Tests.ps1`・`Install-Herdr.Tests.ps1` など) は、`*.ps1` の副作用の無い関数を確かめる。
Linux の pwsh で流すので Windows には触らない。CI の `lint` ([`.github/workflows/nix.yml`](../.github/workflows/nix.yml)) が、
flake が固定している nixpkgs の pwsh で全部を流す (`Start-PortForward.Tests.ps1` は PATH の ssh を引くので、nixpkgs の
openssh も渡す)。手元で同じことをするには、repo の root で:

```sh
nix shell --inputs-from ./nix nixpkgs#powershell nixpkgs#openssh --command bash -c '
  rc=0; for t in win/*/*.Tests.ps1; do pwsh -NoProfile -NonInteractive -File "$t" || rc=1; done; exit "$rc"'
```

## Orca の keybindings.json

Orca が自分で書く形 (`JSON.stringify(…, null, 2)` + 改行) に揃えてある。Orca が同じ内容を
書き直してもバイト列が変わらず、衝突にならない。

```sh
jq --indent 2 . win/orca/keybindings.json | cmp - win/orca/keybindings.json   # 何も出なければ揃っている
```

`null` はその操作の割り当てを外す。Ctrl+W をターミナルへ渡すため、`tab.close` と
`terminal.closePane` を外している。値の書き方は Orca の設定画面で変えたときと同じ。

## PowerShell

配るのは共有設定の `powershell/dotfiles.ps1` だけで、`$PROFILE` そのものは配らない。
`$PROFILE` はドキュメントの下にあり、ドキュメントの位置は OneDrive の設定でマシンごとに
変わる (この PC では `OneDrive\ドキュメント`) ので、manifest の `dst` に書けない。

`$PROFILE` に読み込みの 1 行を足すのは、`setup --update` の
`nix/scripts/bootstrap-windows-powershell-profile.sh` (`dotfiles.ps1` を配る手順の後に走る)。
`pwsh.exe` に `$PROFILE` の場所を聞き、次の 1 行が無ければ足す:

```powershell
if (Test-Path "$HOME\.config\powershell\dotfiles.ps1") { . "$HOME\.config\powershell\dotfiles.ps1" }
```

- `Test-Path` で囲むのは、`$PROFILE` が OneDrive で他の PC へ同期されるため。dotfiles を
  配っていない PC でも、起動のたびにエラーを出さずに済む
- dot-source (`.`) で読む。`&` で呼ぶと子の scope で定義され、呼び終わりに消える
- 直して配ったら、開いている PowerShell では `. $PROFILE` で読み直す
- `$PROFILE` は手元のファイルのまま残る。今ある starship の初期化や、そのマシンだけの設定は
  そこに置いたままでよい
- 足した 1 行を消すと、次からは足し直さない (Windows 側で外したものとして扱う)。戻すなら
  `nix/scripts/bootstrap-windows-powershell-profile.sh --force`
- `$PROFILE` の場所は WSL の interop で聞く。interop が落ちていると足せないので、そのときは
  setup が出す次のコマンドを PowerShell 7 で 1 回打つ:

  ```powershell
  Add-Content -Path $PROFILE -Value 'if (Test-Path "$HOME\.config\powershell\dotfiles.ps1") { . "$HOME\.config\powershell\dotfiles.ps1" }'
  ```

alias の名前と中身は WSL の fish の abbr (`nix/home/modules/fish.nix`) と bash の alias
(`nix/home/modules/bash.nix`) とそろえてある。
足す・直すときは 3 つを変える。

| 名前 | 中身 |
| --- | --- |
| `e` | `exit` (シェルを抜ける。`exit` はキーワードなので function にしてある) |
| `h` | `herdr` (`Set-Alias`。既定の alias の `h` = `Get-History` を上書きする) |
| `hss` | `herdr --session` |
| `hls` | `herdr session list` |
| `ha` | `herdr session attach` |
| `hkill` | `herdr session stop` |
| `hdel` | `herdr session delete` |
| `hst` | `herdr status` |
| `hreload` | `herdr server reload-config` |
| `hsvstop` | `herdr server stop` |
| `hr` | `herdr --remote` (`hr <ssh-target>`。SSH 越しに別のマシンの herdr server へ attach する) |
| `c` | `claude --dangerously-skip-permissions --effort max --model claude-opus-5-5 --remote-control=` (Claude Code。Remote Control を有効にして起動する。末尾の `=` は、後ろに続く語をセッションの名前として取らせないため) |

叩くのは Windows に入れた `herdr.exe` (WinGet の `Herdr.Herdr`) で、WSL の herdr とは
別の server (session を共有しない)。`c` も Windows に入れた `claude.exe` (WinGet の `Anthropic.ClaudeCode`。
dotfiles が固定した版で入れる。[後述](#claude-code)) を叩き、WSL の claude とは別のもの。

### dotfiles.ps1 を書くときの注意

- **BOM 付きの UTF-8 で保存する** (`.editorconfig` も `*.ps1` を `utf-8-bom` にしている)。
  Windows PowerShell 5.1 は BOM の無い UTF-8 を CP932 として読み、日本語コメントの次の行を
  黙って読み飛ばすことがある (`Set-Alias` の行が消えたのを確かめた)。PowerShell 7 はどちらでも読む

  ```sh
  head -c3 win/powershell/dotfiles.ps1 | od -An -tx1   # ef bb bf と出れば BOM 付き
  ```

- PowerShell の alias は引数を持てない。引数を足すものは function にする
- `exit` はコマンドではなくキーワードなので、`Set-Alias` で指せない (`Set-Alias e exit` だと
  `e` が「The term 'exit' is not recognized」で落ちる)。function の中に書く
- 既定の alias と同じ名前は `Set-Alias -Option AllScope -Force` で上書きする。alias は function
  より先に引かれるので、function を書いても既定の alias が当たる。5.1 の既定の alias には
  AllScope が付いていて、`-Option AllScope` が無いと上書きできない

### Windows PowerShell 5.1 でも使うなら

5.1 は実行ポリシーの既定が Restricted で、`$PROFILE` を読まない。使うなら 5.1 で次の 2 つを打つ
(5.1 の実行ポリシーと `$PROFILE` は PowerShell 7 とは別):

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
Add-Content -Path $PROFILE -Value 'if (Test-Path "$HOME\.config\powershell\dotfiles.ps1") { . "$HOME\.config\powershell\dotfiles.ps1" }'
```

## herdr

`herdr/config.toml` は Windows の herdr (WinGet の `Herdr.Herdr`) の設定で、
`%APPDATA%\herdr\config.toml` へ配る。キーバインドと `[ui]` (sidebar の幅と行・toast) は WSL の herdr
(`nix/files/herdr/config.toml`) と同じにしてあり、キーや値ごとの意図はそちらのコメントにある。

- `[keys]`・`onboarding`・`[ui]` は WSL 側と同じに保つ。CI の lint が 2 つを比べ、違えば落ちる。
  手元でも確かめられる:

  ```sh
  nix/scripts/check-herdr-keys.sh   # 「WSL と Windows で同じ (キー 13 個)」と出れば揃っている
  ```

- `[ui]` を揃えるのは、`hr` (`herdr --remote`) で WSL や Linux の herdr に attach したときも、
  sidebar や toast を描くのは Windows の herdr で、このファイルを読むため (つないだ先の設定は読まない)。
  sidebar の workspace の 2 行目の先頭に、子の workspace の親 (`$parent`。claude-skills の
  `ws-mark.sh` が置く token) を出している ([TKT-305](https://app.notion.com/p/herdr-sidebar-workspace-2-token-parent-nix-files-herdr-config-toml-ui-s-40179149a66f81d6a4f0ce9cd5a296df))。
  2 行目の親の前には親子の印・子の数・動いている子・見張り中 (claude がターンを終えて裏の shell を
  待っているだけの間)・済んだ会話の印 (`$stat`。`🌳[2]🔄👀`・`🌱🗑️` など) を出している。どちらも同じ
  `ws-mark.sh` が置く token。1 行目は herdr の既定のまま印を置かない (herdr が項目の間に「 · 」を挟み、
  設定では消せないため)。
  sidebar の幅は 40 桁で、右端の縦線をドラッグすると 80 桁まで広げられる。今見ていない tab の agent が
  終わった・入力を待っているときは、herdr の画面の中に toast を出す ([TKT-319](https://app.notion.com/p/herdr-sidebar-sidebar_width-40-sidebar_max_width-80-toast-delivery-herdr-WSL--40179149a66f81efb793f4bb6ad39c73))

- WSL 側との違いは 2 つ。`[terminal]` を書かない (WSL 側の `default_shell = "fish"` は
  Windows に無い。空のままなら、Windows の herdr は PATH の `pwsh.exe` (PowerShell 7) を使い、
  無ければ `powershell.exe` (5.1) を使う。pwsh 7 なら上の alias も pane の中で使える)。
  `[update] version_check = false` で新しい版の通知を止める ([herdr を入れる](#herdr-を入れる-winget))
- 配った後は、herdr の中で prefix + shift + r (外からなら PowerShell で `hreload`) で読み直す。
  `hr` で attach している画面は PowerShell の `hreload` (Windows の herdr server に届く) では
  読み直さないので、その画面の中で prefix + shift + r を押す。縦線のドラッグで決めた sidebar の幅は
  `%LOCALAPPDATA%\herdr\client-shell\` に残り、読み直しても変わらない。縦線をダブルクリックすると
  設定の幅 (`sidebar_width`) に戻る
- 書いたキー名が Windows の herdr で通るかは、`HERDR_CONFIG_PATH` で場所を差し替えて確かめる
  (本物の設定には触れない):

  ```sh
  HERDR_CONFIG_PATH='C:\Users\<名前>\…\config.toml' WSLENV=HERDR_CONFIG_PATH herdr.exe config check
  ```

- Orca の中で動かすと、`ctrl+up` / `ctrl+down` / `ctrl+alt+up` / `ctrl+alt+down` は Orca が
  先に取る (`orca/keybindings.json` のタブと worktree の移動)。Orca の中では prefix+n / prefix+p で
  タブを移る。Windows Terminal ならすべて herdr に届く
- 初めて配るマシンで、Windows 側に herdr が作った `config.toml` (`onboarding = false` だけ) が
  あると、記録が無いので衝突として止まる。新しいファイルもその行を持つので、差分を見たうえで
  `nix/scripts/bootstrap-windows-files.sh --force` で上書きしてよい
- herdr が `config.toml` を書き戻すのはオンボーディングのときだけ (`onboarding = false` を
  入れてあるので起きない)。設定画面 (prefix+s) で変えて書き戻されたら、次の `setup --update` が
  衝突として止まる ([衝突したら](#衝突したら))

### herdr を入れる (winget)

Windows の herdr は winget の `Herdr.Herdr` (安定版。portable の zip。管理者は要らない) で入れ、
版を `herdr/Install-Herdr.ps1` の `-Version` の既定値 (今は `0.9.5`) の 1 か所で固定する。
2026-11 までは winget に安定版のパッケージが無く、preview の `Herdr.Herdr.Preview` で入れていた
(移る手順は下の「[Herdr.Herdr.Preview から移る](#herdrherdrpreview-から移る)」)。

| 打つもの | すること |
| --- | --- |
| `Install-Herdr -Check` (PowerShell) | 差を出すだけ。揃っていれば終了コード 0、差があれば 1 (`Herdr.Herdr.Preview` が残っているときも)、入っていなければ 3 |
| `Install-Herdr` (PowerShell) | 揃える (入れる・入れ替える・pin を足す)。`Herdr.Herdr.Preview` は外さない |
| `nix/scripts/bootstrap-windows-herdr.sh` (WSL) | `setup --update` でも毎回走る。入っていなければ入れ、差があれば ⚠ で囲んで知らせる (入れ替えはしない)。`Herdr.Herdr.Preview` が残っていれば、外す手順を ⚠ で囲んで知らせる |
| `nix/scripts/bootstrap-windows-herdr.sh --apply` (WSL) | WSL から揃える |
| `nix/scripts/check-winget-version.sh herdr` (WSL・CI) | 固定した版を winget の版の一覧と比べる。GitHub Actions の `winget-versions` が週 1 回流し、新しい安定版が GitHub に出て 30 日たつと落ちて知らせる ([後述](#herdr-の新しい版が出たとき)) |

揃えるときにすること:

1. 入っている版 (winget の置き場所の `herdr.exe --version`) と固定した版を比べる。違えば、先に
   `winget download` で固定した版の取得とハッシュを確かめ (落ちたら何も変えずに止まる)、
   `winget uninstall` してから `winget install --version` で入れる。portable の置き場所は版によらず
   同じで、`%APPDATA%\herdr` の設定やセッションは消えない
2. 入れ替えの前に pin を外し、入れた後に `winget pin add` で `winget upgrade --all` から外す
3. 読み直して、版・pin・PATH で引かれる herdr を確かめる

- 入れ替えるときに herdr が動いていると (server・`herdr --remote`・conpty の OpenConsole.exe)、
  herdr.exe を置き換えられないので、何も変えずに止まる。herdr の外の PowerShell
  (Windows Terminal など) で `hsvstop` を打ち、`--remote` の窓も閉じてから打ち直す。
  スクリプトが server を止めないのは、herdr の pane の中で打つと自分ごと消えるため
- 前の `Herdr.Herdr.Preview` が残っている間も、入れ替えずに止まる (下の「[Herdr.Herdr.Preview から移る](#herdrherdrpreview-から移る)」)
- `herdr update` は打たない。herdr 自身の installer が
  `%USERPROFILE%\.herdr\packages\standalone\releases\<版>-<target>` に別に入れ、そのディレクトリを
  ユーザーの PATH の先頭に足すので、winget の herdr が引かれなくなる。新しい版の通知は
  `herdr/config.toml` の `[update] version_check = false` で止めてある。打ってしまったら
  (`-Check` の「PATH の herdr」が ⚠ になり、外すディレクトリが ※ の行に出る)、そのディレクトリを
  ユーザーの PATH から外し、`%USERPROFILE%\.herdr\packages` と `%LOCALAPPDATA%\Programs\Herdr` を消す。
  `Install-Herdr` は PATH を直さない
- 入れ替えの途中で `winget install` が落ちると、herdr が入っていない状態で止まることがある
  (取得は先に確かめてあるので稀)。そのときは `Install-Herdr` を打ち直す (`setup --update` でも入る)
- 版を変える・新しい版を見送るときは、次の「herdr の新しい版が出たとき」の手順で。新しい安定版が出たかは、
  `winget-versions` の notice か、`-Check` の ※ の行で分かる
- 新しいマシンでは `setup --update` が入れる。依存の VCRedist が無いマシンでは、winget が入れるときに
  Windows に UAC が出る
- setup が入れて揃えるのは `dotfiles.wsl.windowsFiles.herdr.enable = true` のマシン (herdr-app と herdr-core も同じ値)。既定は設定
  グループで決まり、② AI の道具の段が on のホスト (グループ `personal`・`company`) で true ([`nix/README.md` の「設定グループ」](../nix/README.md#設定グループ))。
  false のマシンでは `bootstrap-windows-herdr.sh`・`bootstrap-windows-herdr-app.sh` を飛ばし (setup の結果に `↷`)、新しい版の知らせ
  も herdr・herdr-app・herdr-core を確かめない。false に戻しても setup は消さない。設定 (`%APPDATA%\herdr\config.toml`) と PowerShell の
  関数は、この値によらず配る

#### Herdr.Herdr.Preview から移る

前に `Herdr.Herdr.Preview` で入れていた PC では、`setup --update` (`-IfMissing`) が `Herdr.Herdr` を並べて入れる。
portable の置き場所は ID ごとに分かれる (`%LOCALAPPDATA%\Microsoft\WinGet\Packages\Herdr.Herdr_…` と
`…\Herdr.Herdr.Preview_…`) ので、動いている Preview の herdr server には触らない。Preview は外さず、残っている間は
`-Check` と `setup --update` が ⚠ で知らせ、外す手順を添える (`-Check` の終了コードは 1)。

- どちらのパッケージも置き場所をユーザーの PATH に足すので、両方ある間は PATH で先の方の herdr が引かれる。
  後から入れた `Herdr.Herdr` は後ろに足されるので、Preview の herdr が引かれる (`-Check` の「PATH の herdr」が ⚠ になり、
  「Preview を外せば直る」と ※ の行に出る。2026-11-09 にこの PC で確かめた)
- `Herdr.Herdr` を並べて入れると、winget は Preview を `Herdr.Herdr` として数える (`winget list` の Preview の行の Id が
  `Herdr.Herdr` になり、`winget list --id Herdr.Herdr.Preview --exact` では見つからない。winget v1.29.380)。
  そこで Preview は、winget が Preview の「アプリ」の項目 (ARP) に書いた product code で外す
- Preview が残っている間は、`Install-Herdr` (`--apply`) は版の入れ替えをせずに止まり、先に Preview を外すよう手順を出す
  (`winget uninstall --id Herdr.Herdr` が、`Herdr.Herdr` として数えられた Preview に当たりうるため)。新しい版に上げる前に
  Preview を外す。入れる・pin を足すだけなら、Preview が残っていても進む
- `Herdr.Herdr` が入る前は、`-Check` は Preview を外せとは言わない (「入れてから外す」と出す)。入れる前に外すと herdr が無くなる
- 設定 (`%APPDATA%\herdr`) は置き場所によらないので、移った後もそのまま読まれる

外すのは、herdr の pane が消えてもよいときにする (Windows の herdr server を止めるため。スクリプトが外さないのも
そのため):

1. herdr の外の PowerShell (Windows Terminal など) で `hsvstop` を打ち、`herdr --remote` の窓も閉じる
2. `winget uninstall --product-code Herdr.Herdr.Preview_Microsoft.Winget.Source_8wekyb3d8bbwe` を打つ
   (Windows の設定の「アプリ」から herdr (Preview) をアンインストールするのと同じ)。winget は置き場所のディレクトリを
   消すが、ユーザーの PATH に足した行 (`%LOCALAPPDATA%\Microsoft\WinGet\Packages\Herdr.Herdr.Preview_…`) は残す
   (Preview の ARP に `InstallDirectoryAddedToPath` があっても消さない。この PC で 2026-11-10 に外し、2026-11-11 に
   行が残っているのを確かめた。winget v1.29.380)。残った行に害は無い (ディレクトリが無いので PATH ではその行が飛ばされ、
   後ろの `Herdr.Herdr` の herdr が引かれる)。消すなら手で、「アカウントの環境変数を編集」の画面でユーザーの `Path` から
   その行を外す (2026-11-11 にこの PC で消せた。消した後の値の型は REG_EXPAND_SZ だった)。`Install-Herdr` は PATH を直さない
3. 続けて `winget pin remove --id Herdr.Herdr.Preview --exact` で Preview の pin を外す (Preview を外す前に打つと、
   `Herdr.Herdr` として数えられた Preview の行に当たりうる)
4. 新しい PowerShell から herdr を起動し直し、`Install-Herdr -Check` が「揃っている」になること (「PATH の herdr」が
   winget のもの) と、`winget pin list` から Preview の行が消えたことを確かめる。違えばこの手順と Install-Herdr.ps1 の
   締めの行を直す (2026-11-10 にこの PC で 1〜3 を流し、4 のとおりになった)

### herdr の新しい版が出たとき

固定した版より新しい安定版が GitHub に出て 30 日たつと、GitHub Actions の `winget-versions` の
`Windows の herdr` の job が落ちて知らせる ([TKT-156](https://app.notion.com/p/herdr-Google-windows-openssh-1-3fa79149a66f81ee8d2bd07a0769cab0))。
猶予・落ちる場合・見送りの一覧は [winget の新しい版を確かめる](#winget-の新しい版を確かめる)。

- 出た日は、GitHub の安定版の release (tag が `v0.9.5` のような `vX.Y.Z` で、prerelease でないもの) から取る。
  winget の版 (`0.9.5`) と、tag の `v` の後ろで突き合わせる
- 安定版は 1〜2 週に 1 回ほど出る (2026-09〜10)。固定した版より新しい安定版が 1 つ出た日から 30 日の猶予が始まる
  (後から出た安定版では数え直さない)。見送っても、その次に出た安定版の日から数える
- GitHub と比べるのは安定版だけ。preview の build (tag が `preview-<日付>-<hash>` の prerelease) は数えない。
  winget では別のパッケージ `Herdr.Herdr.Preview` に載るもので、dotfiles は 2026-11 に安定版の `Herdr.Herdr` へ移った
  (移る手順は「[Herdr.Herdr.Preview から移る](#herdrherdrpreview-から移る)」)
- winget-pkgs の `manifests/h/Herdr/Herdr` には、版と並んで `Herdr.Herdr.Preview` のディレクトリ (`Preview`) がある。
  版ではないので、版の形でないディレクトリには数えない
- winget の最新より新しい安定版が 30 日たっても winget に無いと落ちる。winget に載らなくなったか、別の ID へ
  移ったかもしれないので、`winget search herdr` で確かめる
- GitHub の直近 100 件の release に安定版が 1 つも無いと、猶予を置かずに落ちる (出し方が変わったか、止まった)

上げるとき:

1. 落ちた実行の summary で、新しい版と release notes の URL を見る (猶予の中に上げるなら、notice に出た版)
2. release notes (Added・Changed・Fixed。hotfix の版は元の版の notes も) で、設定のキー・PATH・portable の
   置き場所・`herdr update` に触る変更が無いかを見る
3. `herdr/Install-Herdr.ps1` の `-Version` の既定値と、「herdr を入れる (winget)」の「今は」を新しい版にし、
   `Install-Herdr.Tests.ps1` を流して PR を出す (`winget-versions` が、書いた版が winget にあるかを確かめる)
4. merge したら、各マシンで `setup --update` を流す (差が ⚠ で出る)。herdr の外の PowerShell
   (Windows Terminal など) で `hsvstop` を打ち、`herdr --remote` の窓も閉じてから、`Install-Herdr` か
   `bootstrap-windows-herdr.sh --apply` で揃える。`Herdr.Herdr.Preview` が残っている PC では入れ替えずに止まるので、
   先に Preview を外す
5. 揃えた後の `-Check` が「揃っている」になり、herdr を起動して設定が読める (キーが効く) ことを確かめる

見送るとき (2 や 5 で合わないと分かったとき):

- `herdr/skipped-versions.txt` に「版 理由」を 1 行足して commit する。版は winget の版の形 (`0.9.6` のような
  `X.Y.Z`) で書く。winget にまだ無い安定版 (job が GitHub にだけあると出したもの) も同じ形で書ける
- 5 で分かったなら、`-Version` の既定値も前の版に戻し、`Install-Herdr` で揃え直す (下げるのもできる)
- `-Check` の ※ の行は見送っても出続ける (winget に新しい版があるのは事実なので)

### Install-Herdr.ps1 を書くときの注意

- `dotfiles.ps1` と同じく **BOM 付きの UTF-8** で保存する
- 副作用の無い関数 (版の読み方・並び・plan・winget の引数・PATH の解決・状態の表) は
  `herdr/Install-Herdr.Tests.ps1` で確かめる。Linux の pwsh で流すので Windows には触らない
  (このファイルは manifest に無いので配られない):

  ```sh
  nix shell nixpkgs#powershell -c pwsh -NoProfile -File win/herdr/Install-Herdr.Tests.ps1
  ```

- winget やプロセスに触る部分は、実機で `-Check` と本番を打って確かめる

## herdr-app

herdr-app は herdr の desktop app (窓の中に、herdr-core (`hc`) の terminal と agent を並べる)。winget には無く、公式の入れ方は
PowerShell の `irm https://releases.herdr.dev/app/install.ps1 | iex` だけなので、`herdr-app/Install-HerdrApp.ps1` が公式の install.ps1
(app と、それが呼ぶ core の install.ps1) と同じ置き場所に、dotfiles が固定した版を入れる (遠くの script は流さない)。herdr-core も、
無ければ同じ script で入れる。どちらも WSL の herdr・winget の herdr とは別のもの
([ADR 048](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/048_win_herdr_app_official_layout_20261109T230034JST/README.md))。

app と core は自分で新しい版に上がる。上がる先を dotfiles が決めるため、取得元 (環境変数 `HERDR_RELEASES_URL`) を、固定した版だけを
載せた手元のフィードに向ける ([後述](#更新の取得元をフィードに替える))。

### herdr-app を入れる

| 打つもの | すること |
| --- | --- |
| `Install-HerdrApp -Check` (PowerShell) | 今の状態と固定どおりかを出すだけ。揃っていれば終了コード 0、揃っていないものがあれば 1、app が入っていなければ 3、確かめられない (引数や固定した版の書き方の誤り・思わぬ例外) なら 2 |
| `Install-HerdrApp` (PowerShell) | 揃える: フィードと環境変数を固定どおりに書き、公式から受け取った更新を消し、入っていなければ入れ、固定より古いか署名が合わなければ入れ直し (下げはしない)、足りない `Herdr.lnk`・PATH の行を足す (`-IfMissing` を付けても同じ) |
| `Install-HerdrApp -Uninstall` (PowerShell) | 外す ([後述](#herdr-app-を外す)) |
| `nix/scripts/bootstrap-windows-herdr-app.sh` (WSL) | `setup --update` でも毎回走る。揃っていなければ `-IfMissing` で揃え、揃いきらなければ (固定より新しい版が入っている・入れられない) ⚠ で囲んで知らせる |
| `nix/scripts/bootstrap-windows-herdr-app.sh --apply` (WSL) | WSL から揃える |
| `nix/scripts/check-herdr-app-version.sh` (WSL・CI) | 固定した版の成果物 (core は Windows と Linux の 2 つ) が変わっていないかと、上げられる新しい版を確かめる ([後述](#固定した版を上げる)) |
| `nix/scripts/check-herdr-app-installers.sh` (WSL・CI) | 公式の install.ps1 が、写したときから変わっていないかを確かめる ([後述](#公式の-installps1-が変わったとき)) |

固定した版は `nix/pkgs/herdr-core/releases.json` (今は app 0.1.15・core 0.1.21) の 1 か所で決める。app の版と windows-x86_64 の sha256、
core の版・generation と linux-aarch64・linux-x86_64・windows-x86_64 の sha256 を持ち、Windows へは manifest が `herdr-releases.json` として
`Install-HerdrApp.ps1` の隣に配る。Linux のホストの herdr-core (home-manager) も同じ版で入る ([後述](#server-側の-herdr-core-hc))。公開から 7 日たった
版を、PR で上げる。

置くもの (app と core の置き場所は公式の install.ps1 と同じ。管理者は要らず、アプリと機能 (ARP) には載らない):

| 物 | 置き場所 |
| --- | --- |
| app | `%LOCALAPPDATA%\Programs\herdr-app` (`herdr-app.exe`・`herdr-app.svg`・`LICENSE`・`THIRD-PARTY-NOTICES`)。固定した版を公式の版つき URL (`releases.herdr.dev/app/<版>/herdr-app-windows-x86_64.tar.gz`) から落とし、dotfiles の sha256 と exe の署名を確かめて `System32\tar.exe` で展開する |
| スタートメニュー | `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Herdr.lnk` (`herdr-app.exe` を指し、作業ディレクトリは `%USERPROFILE%`) |
| ユーザーの PATH | app と core の置き場所を末尾に足す (`HKCU\Environment` の生の値に足す。値の型と、ほかの行の `%VAR%` の書き方はそのまま) |
| core | `%LOCALAPPDATA%\Programs\herdr-core` (`herdr-core.exe`・`conpty\`・`THIRD-PARTY-NOTICES\`。`hc` が無ければ `hc.exe` を hard link で作る)。公式の置き場所にも PATH にも `herdr-core.exe` が無ければ固定した版を入れ、固定より古ければ公式と同じく `herdr-core.exe update --from` で差し替える (terminal は動いたまま) |
| フィード | `%LOCALAPPDATA%\dotfiles\herdr-releases` (`app\latest.json`・`core\latest.json`・`core\<版>\manifest.json`)。固定した版だけを載せる ([後述](#更新の取得元をフィードに替える)) |
| 環境変数 | ユーザーの環境変数 `HERDR_RELEASES_URL` = フィードを指す `file:///…` の URL |

- 入れる前に、exe の Authenticode を `Get-AuthenticodeSignature` で見る。Valid で、発行先が全体で
  `CN=herdr, O=herdr, L=Wilmington, S=Delaware, C=US`、発行元が `CN=Microsoft ID Verified CS <3 字> CA <2 桁>, O=Microsoft Corporation, C=US`
  (Azure Artifact Signing の中間 CA。版によって `AOC CA 03`・`04`) でなければ入れない。証明書は版ごとに替わる (期間は 3 日) ので、指紋では
  なく発行先と発行元で照らす。`-Check` も、入っている exe の署名を見る
- 入っている exe の署名が合わなければ、版によらず固定した版を入れ直す (版は確かめていない exe が名乗るものなので)。合わない exe は動かさない
  (`--version` も打たない)。core は動いていれば止めてもらう (`server stop` も合わない exe なので打たず、タスク マネージャーなどで止める)
- 発行先が変わって入れられないと出たら (herdr の所在地が変わったなど)、herdr の告知で確かめてから `Install-HerdrApp.ps1` の
  `$HerdrAppPublisher` を書き換える PR を出す (CI は署名を見ないので、Windows で入れるときに初めて気付く)
- 入っている版が固定より新しいときは下げない (設定を古い版で読ませないため)。`-Check` が ⚠ で知らせるので、固定した版が追いつくのを
  待つか、`Install-HerdrApp -Uninstall` の後に入れ直す。取得元の変数を置く前に上がったか、変数が効いていない (公式から上がった) ときに起きる。
  署名は合うが版が読めない (`--version` の形が変わった・終わらない) ときも、新しい版かもしれないので入れ替えず ⚠ で知らせる
- `-Check` はネットワークを使わない。公式と違う置き場所 (winget など) の core は ⚠ にせず、※ で添えて触らない
- 入れられなかったら (ネットワーク・署名や sha256 が合わない・x64 でない PC)、⚠ で囲んで知らせ、そのまま次へ進む (setup は止めない)。
  core だけ入れられなかったときは、app は入れたまま終了コード 1 になる (次の `setup --update` でもう一度入れにいく)
- 落とすのは公式と同じく `curl.exe` だが、つながらない (30 秒)・転送が止まった (60 秒のあいだ 1 KB/s を下回る) ときは打ち切る
  (公式は待ち続ける。setup が止まったままにならないよう)
- 新しく開くシェルから `herdr-app` と `hc` が引ける (`Install-HerdrApp` を打った PowerShell には、script が今のプロセスの PATH にも足す)
- 設定 (`~/.config/herdr-app`。テレメトリは既定で有効で、Settings → Privacy で変える) は dotfiles では配らない

### 更新の取得元をフィードに替える

release の app は、開いて 10 秒後と 1 時間ごとに取得元の `app/latest.json` を見て、新しい版を置き場所の隣に落とし
(`herdr-app.download` で展開して `herdr-app.new` と `herdr-app.new.json` にする)、再起動か終了のときにフォルダごと差し替える
(`herdr-app` → `herdr-app.old`、`herdr-app.new` → `herdr-app`)。止める設定は無い。app を上げた後の初回の起動で `hc update --version <版>` を
流し、core も上げる (core は動いているファイルを `<名前>.old-…` へ rename して差し替え、terminal は動いたまま)。

app も core (`hc update`) も、取得元の manifest にある sha256 しか確かめない (Windows では署名を見ない)。manifest と成果物は同じ
`releases.herdr.dev` にあるので、両方を差し替えられると防げず、汚染された版が 1 時間以内に入る。そこで:

- app と core は、取得元を環境変数 `HERDR_RELEASES_URL` から読む (無いときだけ `https://releases.herdr.dev`)。manifest は Windows の
  `curl.exe` で読むので、`file:///…` の URL なら手元のファイルを読める
- `Install-HerdrApp` が、固定した版だけを載せたフィードを書き、ユーザーの環境変数をそこへ向ける。フィードの成果物の URL は公式の版つき URL、
  sha256 は dotfiles の値。app と core はフィードに載った版にだけ上がり、sha256 が合わなければ断る (実機で確かめた)
- フィードに `install.ps1` は置かない。app の「core を入れ直す」(取得元の `core/install.ps1` を流す) は失敗し、core は dotfiles が入れる
- core の manifest (`core\latest.json`・`core\<版>\manifest.json`) には、Windows のほかに Linux (x86_64・aarch64) の target も載せる。herdr-app・hc が
  SSH の先の Linux の machine に core を入れるとき、同じ版のその target の build を取得元から落とすため ([後述](#server-側の-herdr-core-hc))
- 環境変数は、置いた後に開いた app と core からしか効かない。開いている app は、閉じて開き直す (置く前に開いた app は、公式から上がりうる)
- 置く前に開いた app が公式から落とした版を待たせていると (`herdr-app.new` と受け取りの `herdr-app.new.json`)、固定した版を入れた後でも、
  閉じるか開き直すときに差し替わる (app は、受け取りの版が動いている版より新しければ、変数も署名も見ずに差し替える)。`Install-HerdrApp`
  (setup) は、固定した版で署名の合うもの、のほかの受け取りを消し、`-Check` は「受け取った更新」の行の ⚠ で知らせる。消してから app を
  閉じて開き直す (消す前に閉じると差し替わる。開いたままだと、また公式から受け取りうる)
- ユーザーが自分で `HERDR_RELEASES_URL` を置いていても、揃えるときにフィードの URL に替える (前の値は状態の表に出る。`-Uninstall` では戻らない)
- `HERDR_RELEASES_URL` は、公式の install.ps1 が「(tests)」と書くテスト用の変数で、将来読まれなくなりうる。読まれなくなると app は公式の
  最新へ上がるので、次の `setup --update` の `-Check` が「入っている版が固定より新しい」で知らせる。版を上げる前には、新しい版のソース
  (app は `src/update.rs`、core は `crates/herdr-core/src/releases.rs`) がこの変数を読むかを CI が確かめる
- 7 日の猶予の分だけ、直りが届くのも遅れる。急ぎの修正は、ユーザーが決めて猶予を外して上げる

### server 側の herdr-core (hc)

herdr-app の machine (SSH でつなぐ先) は、その machine の herdr-core が terminal を持つ。手元の core が SSH で remote の `herdr-core connect` を
起動し、remote は非対話の sh で `herdr-core` を探す (PATH にあればそれ、無ければ `~/.local/bin/herdr-core`。Windows の remote は
`.\AppData\Local\Programs\herdr-core\herdr-core.exe`)。server になりうるホストには、herdr-core を同じ版で入れておく。

| ホスト | 入れるもの |
| --- | --- |
| Linux (dotfiles の home-manager) | `home/modules/herdr-core.nix` が、既定で全部の Linux のホストに `herdr-core`・`hc` を入れ、`~/.local/bin/herdr-core`・`hc` も同じ binary へのリンクにする ([`nix/README.md`「herdr-core (hc) を Nix で入れる」](../nix/README.md#herdr-core-hc-を-nix-で入れる)) |
| Windows | `Install-HerdrApp.ps1` が公式と同じ置き場所に入れる (remote が探す場所と同じ) |
| dotfiles を当てない Linux | herdr-app・hc が machine を足すときに `~/.local/bin/herdr-core` に入れる。取得元はフィードで、同じ版の Linux の build を固定した sha256 で確かめる |
| macOS | 対象外。フィードに macOS の target を載せていないので、Windows の herdr-app・hc から Mac に core を入れようとすると断られる (Mac には自分で入れる) |

- 版はどれも `nix/pkgs/herdr-core/releases.json` の core の版。同じ版なら、machine を足す・つなぐときに写し直しを聞かれない (古いと too old to talk to
  で写し直しを聞かれる)
- dotfiles が入れたホストへは `hc machine update` (と herdr-app の machine の更新) を打たない。Linux では `~/.local/bin/herdr-core` を落とした binary に
  置き換え (次の switch が、同じ版でもリンクに戻す)、Windows では固定した版より新しい版を入れうる。版は下の手順で、Windows と Linux を同じ PR で上げる
- Linux の store の core は、`hc update` が「nix のもの」として断る (`update it in your Nix configuration`)

### 固定した版を上げる

GitHub Actions の `herdr-app-installers` ([`.github/workflows/herdr-app-installers.yml`](../.github/workflows/herdr-app-installers.yml)) の
`version` の job が、週 1 回 (月曜の朝) と、`win/herdr-app/` などを変える PR で `check-herdr-app-version.sh` を流す。固定した版より新しい版
(GitHub の tag で並べ、Windows の成果物が `releases.herdr.dev` にあるもの) のうち、公開 (成果物の Last-Modified) から 7 日たったものが
あれば落ちて知らせる。7 日の間は落ちず、版と残りの日数を notice と summary に出す。新しい版の公開日を読めない (HEAD が 404 のほかで失敗する・
Last-Modified が無い) ときは、飛ばさずに「確かめられなかった」で落ちる (404 の版は Windows の成果物が無い版として数えない)。

```sh
nix/scripts/check-herdr-app-version.sh   # 0 = 知らせることは無い、1 = 知らせることがある、2 = 確かめられなかった (gh のログインが要る)
```

上げるとき:

1. 落ちた実行の summary で、新しい版と sha256 (app なら core_min、core なら generation) と、その版のソースが `HERDR_RELEASES_URL` を読むかを見る。
   読まないと出たら上げない (取得元をフィードに替えられない)。CI は文字があるかしか見ないので、summary の差分の URL で、取得元を決めるソース
   (app は `src/update.rs`、core は `crates/herdr-core/src/releases.rs`) の差分も読む (テストのときだけ読むように移っていないか)
2. CHANGELOG (`herdrdev/herdr-app`・`herdrdev/herdr-core` の `CHANGELOG.md`) で、設定・置き場所・更新の仕組みに触る変更が無いかを見る
3. `nix/pkgs/herdr-core/releases.json` の版と sha256 (app は windows-x86_64、core は linux-aarch64・linux-x86_64・windows-x86_64 の 3 つと
   generation) と、「[herdr-app を入れる](#herdr-app-を入れる)」の「今は」を新しい版にする。Windows と Linux は、この 1 つの PR で一緒に上がる。
   core は app の core_min 以上にする。core の generation が固定と違うと出たら、app を、その generation の core と話せる版と一緒に上げる
   (`update --from` は generation を見ないので、core だけを上げると app と話せない core が入る)。`Install-HerdrApp.Tests.ps1` と
   `nix build ./nix#checks.x86_64-linux.herdr-core-test` (Linux の build と `hc --version`) を流して PR を出す (CI の `version` の job が、書いた版の
   成果物と manifest が合うかを target ごとに確かめる)
4. merge したら、各マシンで `setup --update` を流す。Windows ではフィードが新しい版に書き換わり、`-IfMissing` が app と core を上げる (署名と
   sha256 を確かめてから。動いている app は置き場所の rename で入れ替わり、再起動で新しい版になる)。開いている app も、1 時間以内にフィードの版へ
   上がる。Linux のホストでは、home-manager の switch が新しい版の herdr-core を入れる (動いている core は、次に起動したときから新しい版)。
   machine としてつなぐホストは続けて上げる (版が混ざると、つなぐときに写し直しを聞かれる)
5. `-Check` が「揃っている」になり、app が起動することを確かめる

見送るとき (1・2 で上げないと決めたとき): `nix/pkgs/herdr-core/skipped-versions.txt` に「app か core・版・理由」を 1 行足して commit する
(`app 0.1.14 core の generation 2 と組まないと話せない` など)。その版では `version` の job も setup の知らせも黙り、もっと新しい版が
出るとまた知らせる。固定した版以下になった行は消してよい (job が知らせる)。

### 固定した版の成果物が変わったとき

`version` の job が「固定した版の成果物の sha256 が、固定した値と違う」で落ちたら、公開の後で `releases.herdr.dev` の成果物が差し替え
られている (正しい直しでも、汚染でもありうる)。

- `Install-HerdrApp` は sha256 が合わない成果物を入れないので、新しいマシンにはその版を入れられなくなる。入っているマシンはそのまま
- 固定した値を今の値に書き換えない (差し替えられた中身を受け入れることになる)。herdr の repo の issue・release notes で差し替えのわけを
  確かめ、分からなければ、ほかの版 (前の版か、7 日たった次の版) に固定を移す
- core の Linux の成果物が差し替えられると、その store path をまだ持っていない Linux のホストは switch が落ちる (持っているホストは
  そのまま)。急いで setup を通すなら、そのホストで `dotfiles.herdrCore.enable = false` にする
  ([`nix/README.md`「herdr-core (hc) を Nix で入れる」](../nix/README.md#herdr-core-hc-を-nix-で入れる))

### herdr-app を外す

`Install-HerdrApp -Uninstall` で、公式の置き場所に置いたものと、dotfiles のフィード・環境変数だけを外す。setup からは打たない (人が打つときだけ)。

| 外すもの | 残すもの |
| --- | --- |
| `%LOCALAPPDATA%\Programs\herdr-app` と、自己更新の途中の `herdr-app.old`・`herdr-app.new`・`herdr-app.new.json`・`herdr-app.download` | 設定と mod (`~/.config/herdr-app`) |
| `Herdr.lnk` (app を指しているときだけ) | core の状態 (`%LOCALAPPDATA%\herdr-core`) と設定 (`%APPDATA%\herdr-core`) |
| ユーザーの PATH の app と core の行 | 別の場所を指す `Herdr.lnk`・公式と違う置き場所 (winget など) の core |
| `%LOCALAPPDATA%\Programs\herdr-core` を丸ごと (`hc.exe`・`conpty\`・`hc update` の残りも) | フィードを指していない `HERDR_RELEASES_URL` (揃えるときにフィードの URL に替えているので、残るのは後から自分で置き直したときだけ) |
| フィード (`%LOCALAPPDATA%\dotfiles\herdr-releases`) と、フィードを指す `HERDR_RELEASES_URL` | `%LOCALAPPDATA%\dotfiles` のほかのファイル |

- app か core が動いていると (置き場所の下の exe から起動したプロセス。core の conpty の `OpenConsole.exe` も数える)、何も外さずに
  PID とコマンドラインを出して終了コード 1 で止まる。app の窓を閉じ、出てくる `herdr-core.exe server stop` を打ってから打ち直す。
  core を止めると、その中の terminal と、そこで動いているもの (agent など) も終わるので、止めるのは人
- 動いているかは `Win32_Process` の実行ファイルのパスで見る。パスが読めないプロセス (管理者で動いている、など) は、名前が
  `herdr-app.exe`・`herdr-core.exe`・`hc.exe` なら動いているものに数える (公式と違う置き場所のものでも止まる。止めてから打ち直す)
- 一度でも開いた app は、窓を閉じても core が裏で動き続ける (terminal を残すため)。外す前に `server stop` が要る
- 消すときはリンク (junction・symlink) の先をたどらない (リンクだけを消す)。公式の置き場所の外は消さない
- PATH は外した行のほかは変えない。ただし入れるときに、前からあった末尾の `;` は落ちている (公式と同じ足し方)
- 外したものと残したものを出し、読み直して外しきれたかを確かめる (残っていれば終了コード 1)
- dotfiles が管理する間は、外した後の `setup --update` が入れ直す (bootstrap は app が無ければ入れる)。入れ直させたくないとき
  (winget に移るなど) は、次の「winget に載ったら」の順で進める
- `Install-HerdrApp` は隣の固定した版のファイル (`herdr-releases.json`) を読むので、それが無いと `-Uninstall` も終了コード 2 で止まる。配り直すか
  (`setup --update`)、repo の `nix/pkgs/herdr-core/releases.json` を `-ReleasesFile <Windows のパス>` で渡せば外せる

### winget に載ったら

herdr-app が winget に載ったら、dotfiles の管理を winget の形 ([herdr を入れる](#herdr-を入れる-winget) と同じ) に移せる。

1. dotfiles を winget の形に替える PR を merge する。`Install-HerdrApp.ps1` を winget の形 (`-Version`・pin・`-Check`) に書き換えて
   bootstrap も合わせ、CI の `herdr-app-installers` と `herdr-app/upstream-installers.txt` を外して `winget-versions` に足す。替えた
   script には、公式の置き場所の残りを見つけたら ⚠ で外し方を出させると、外し忘れた PC に気付ける
2. 各 PC で、dotfiles を pull する前に、app の窓を閉じて `herdr-core.exe server stop` を打ち (core の中の terminal も終わる)、今の
   `Install-HerdrApp -Uninstall` で外す (設定は残るので、winget で入れた app がそのまま読む。フィードと環境変数も外れる)
3. pull して `setup --update` を流す (winget で入る)。2 と 3 の間に、pull せずに `setup --update` を流さない (今の bootstrap が公式の
   置き場所に入れ直す)

移る前に確かめること:

- winget のパッケージが portable (zip) か installer か、置き場所はどこか
- 自分で上がる app と winget の記録のずれ。app は置き場所の隣に `.new` を作ってフォルダごと差し替えるので、winget の portable の
  置き場所でも中身が替わり、`winget list` の版と中身がずれる (`winget pin` では止まらない)。core も、`hc update` が winget の置き場所を
  断らずに上書きする。winget に移っても上がる先を決めたいなら、`HERDR_RELEASES_URL` のフィードは winget の形でも使える
- core まで winget (`Herdr.HerdrCore`) に替えるかは、上のずれを見てから決める

### 公式の install.ps1 が変わったとき

`Install-HerdrApp.ps1` は公式の install.ps1 を流さずに同じ置き場所・手順を踏むので、公式が置くもの・置き場所・手順を変えると、入れるもの・
外すものが黙ってずれる。そこで `herdr-app/upstream-installers.txt` に、写した中身の sha256 を書いておく。`herdr-app-installers` の
`installers` の job が、週 1 回 (月曜の朝) と、`win/herdr-app/` などを変える PR で公式の install.ps1 を落として比べ、変わっていれば落ちて
知らせる (落とせなかったときも落ちる)。

```sh
nix/scripts/check-herdr-app-installers.sh   # 0 = 変わっていない、1 = 変わった、2 = 確かめられなかった
```

変わったら:

1. 落ちた実行の summary で、変わった URL と差分を読む所を見る (`upstream-installers.txt` の 3 列目。app は `herdrdev/herdr-app`、core は
   `herdrdev/herdr-core` の `distribution/install.ps1` の履歴。配る中身は、その repo の default branch のファイルと同じ)
2. 置くもの・外すもの・置き場所・手順の変化を `Install-HerdrApp.ps1` に合わせ (`-Uninstall` が外すものと、この節の表も)、テストを流す。
   `HERDR_RELEASES_URL` の扱いが変わっていないかも見る
3. `upstream-installers.txt` の sha256 を今の値にする (合わせることが無くても書き換える。読んだ印)。PR で `herdr-app-installers` が通るのを見る

### Install-HerdrApp.ps1 を書くときの注意

- `dotfiles.ps1` と同じく **BOM 付きの UTF-8** で保存する。Windows PowerShell 5.1 でも動かす (sha256 は `Get-FileHash` を使わず、
  公式と同じく .NET で求める。PowerShell 7 から起こした 5.1 では `Get-AuthenticodeSignature` のモジュールを読めないので、`$PSHOME` から
  読み直す)
- 遠くの script を流さない (`irm`・`iex`・`Invoke-Expression` を使わない)
- 署名の合わない exe は動かさない (`--version`・`update --from`・`server stop` を打たない)。署名は先に見る
- 消すのは `Remove-HerdrAppTree` で (リンクの先をたどらない)。`Remove-Item -Recurse` がリンクをたどるかは PowerShell の版で違う
- 副作用の無い関数 (固定した版の書き方・フィードの中身・署名の照らし方・揃えるときの計画・PATH の足し引き・状態の表・外す計画) と、Windows に
  触る関数を偽物に替えた流れは `herdr-app/Install-HerdrApp.Tests.ps1` で確かめる。Linux の pwsh で流すので Windows には触らない
  (このファイルは manifest に無いので配られない):

  ```sh
  nix shell nixpkgs#powershell -c pwsh -NoProfile -File win/herdr-app/Install-HerdrApp.Tests.ps1
  ```

- ダウンロード・署名・レジストリ・ショートカット・プロセスに触る部分は、実機で `-Check`・本番・`-Uninstall` を打って確かめる

## OpenSSH

WSL の `ssh` は Windows の `ssh.exe` (`C:\Program Files\OpenSSH`) を呼んで 1Password の agent に
つなぐ ([ADR 004](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/004_nix_wsl_ssh_wrapper_20260811T124616JST/README.md))。その OpenSSH の版を、
winget の `Microsoft.OpenSSH.Preview` で固定する。固定する版は
`openssh/Install-OpenSSH.ps1` の `-Version` の既定値 (今は `10.4.0.0`) の 1 か所だけに書く。

| 打つもの | すること |
| --- | --- |
| `Install-OpenSSH -Check` (PowerShell) | 差を出すだけ。管理者は要らない。揃っていれば終了コード 0、入っていなければ 3、ほかの差があれば 1 |
| `Install-OpenSSH -IfMissing` (PowerShell) | 入っていなければ固定した版を入れる (UAC が 1 回出る)。ssh-agent を止めて無効にし、pin も足す。入っていれば `-Check` と同じ。入れたあとは、1Password の鍵が見えなくても成功にする (新しい PC ではまだ 1Password を入れていない) |
| `Install-OpenSSH` (PowerShell) | 揃える。直すことがあるときだけ UAC が 1 回出る |
| `nix/scripts/bootstrap-windows-openssh.sh` (WSL) | `setup --update` でも毎回走る (order 96)。`-Check` を流し、入っていなければ `-IfMissing` で入れ (UAC が出る。待つのは 600 秒まで)、差があれば ⚠ で囲んで知らせる (揃えはしない) |
| `nix/scripts/bootstrap-windows-openssh.sh --apply` (WSL) | WSL から揃える。UAC は Windows のデスクトップに出る |
| `nix/scripts/check-winget-version.sh openssh` (WSL・CI) | 固定した版を winget の版の一覧と比べる。GitHub Actions の `winget-versions` が週 1 回流し、新しい版が GitHub に出て 30 日たつと落ちて知らせる ([後述](#openssh-の新しい版が出たとき)) |

揃えるときにすること:

1. 入っている版 (`ssh.exe` の FileVersion) と固定した版を比べ、`winget upgrade` か `install` に
   `--version` を付けて揃える。upgrade には `--include-pinned` も付け、3 で足した pin を越える (付けないと、版を名指しした upgrade は
   pin に止められる。[winget の pin](#winget-の-pin))。下げるときは MSI が「新しい版が入っている」で止めるので、先に `uninstall` する。
   どれにも `--custom ADDLOCAL=Client` を付け、sshd は入れない
2. ssh-agent サービスを停止・無効に戻す。MSI の更新は ssh-agent を「自動・実行中」で作り直し、1Password と
   `\\.\pipe\openssh-ssh-agent` を取り合う ([Win32-OpenSSH#2057](https://github.com/PowerShell/Win32-OpenSSH/issues/2057))。
   ssh-agent はクライアント側の部品でもあるので、`ADDLOCAL=Client` でも入る
3. `winget pin add` で `winget upgrade --all` から外す (版を名指しした `winget upgrade --id …` も、`--include-pinned` が無ければ止める)
4. 読み直して、版・ssh-agent・pin と、`ssh-add -l` で 1Password の鍵が見えるかを確かめる

- 入れ替える (上げる・下げる) ときに `ssh.exe` などが動いていると、閉じるよう出して止まる (`-Force` で進む)。
  使用中のファイルは再起動まで置き換わらないことがある。入っていない PC に入れるときは、置き換えるファイルが無いので見ない
  (Windows の機能の OpenSSH (`System32\OpenSSH`) の `ssh.exe` が動いていても入れられる)
- 新しい PC では、`setup --new-machine` (96) が入れるところまでする。1Password の SSH agent はまだ無いので、鍵は
  1Password を入れて SSH agent を有効にしてから `Install-OpenSSH -Check` で確かめる (Windows の ssh-agent サービスは、
  入れたときに止めて無効にしてある)。流れは [`nix/README.md`「新しい WSL の PC」](../nix/README.md#新しい-wsl-の-pc)
- 終わったら WSL で `ssh.exe -V` と `ssh-add -l` を確かめる。鍵が見えなければ、1Password をトレイから
  終了して起動し直す
- 版を変える・新しい版を見送るときは、次の「OpenSSH の新しい版が出たとき」の手順で
- 手元でも、`-Check` の「winget の最新版」と ※ の行で新しい版が出たことが分かる (`setup --update` で流したときだけ)

### OpenSSH の新しい版が出たとき

固定した版より新しい版が GitHub に出て 30 日たつと、GitHub Actions の `winget-versions` の
`Windows の OpenSSH` の job が落ちて知らせる
([TKT-110](https://app.notion.com/p/Windows-OpenSSH-Win32-OpenSSH-3f179149a66f81eaa691e12ef3e0b86c))。
猶予・落ちる場合・見送りの一覧は [winget の新しい版を確かめる](#winget-の新しい版を確かめる)。

- 出た日は、GitHub の release (prerelease を除く) から取る。tag の形は揃っていない
  (`v9.8.3.0p2-Preview` / `10.0.0.0p2-Preview`) ので、winget の版とは `OpenSSH-Win64-v<版>.msi` の名前で突き合わせる。
  GitHub の release から winget に載るまでは、これまで 5 時間〜4 日だった
- GitHub に出た版が 30 日たっても winget に無いと落ちるのは、パッケージ ID の移動を捕まえるため
  (2024-10 に Preview ができてから、Beta には新しい版が来なかった)。`winget search OpenSSH` で今のパッケージ ID を
  確かめ、移るなら `git grep Microsoft.OpenSSH.Preview` で出る所 (`Install-OpenSSH.ps1` の `$packageId` と状態の表の
  見出し・`bootstrap-windows-openssh.sh` の見分け・テスト) と固定した版を直す
- GitHub の最新の release に `OpenSSH-Win64-v<版>.msi` が無いと、猶予を置かずに落ちる (名前の付け方が変わると、
  版も出た日も引けない)

上げるとき:

1. 落ちた実行の summary で、新しい版と release notes の URL を見る (猶予の中に上げるなら、notice に出た版を
   GitHub の releases で探す)
2. release notes を読む。ssh-agent・named pipe・MSI (サービスの作り直し) に触る変更が無いかを見る
3. 入れずに試す ([TKT-107](https://app.notion.com/p/Windows-ssh-exe-Win32-OpenSSH-3f079149a66f8153877df4a8e87ed0d7) で通した形)。
   release の `OpenSSH-Win64.zip` を使い捨ての場所に展開し、sha256 を release の digest
   (`gh api repos/PowerShell/Win32-OpenSSH/releases/tags/<tag>` の `assets[].digest`) と照らしてから、
   WSL でその `ssh.exe` を直に流す:
   - `ssh.exe -V` (版と LibreSSL)
   - `ssh.exe -G <host>` (Windows 側の config が Include 込みでエラー無く読める)
   - `ssh-add.exe -l` (1Password の鍵が見える)
   - GitHub へつなぐ (`ssh.exe -T git@github.com`)
4. `openssh/Install-OpenSSH.ps1` の `-Version` の既定値と、「OpenSSH」の冒頭の「今は」を新しい版にし、
   `Install-OpenSSH.Tests.ps1` を流して PR を出す (`winget-versions` が、書いた版が winget にあるかを確かめる)
5. merge したら、各マシンで `setup --update` を流す (差が ⚠ で出る)。Windows で動いている `ssh.exe`
   (herdr の remote など) を閉じてから、`Install-OpenSSH` か `bootstrap-windows-openssh.sh --apply` で揃える
   (UAC が 1 回出る)
6. WSL で `ssh.exe -V`・`ssh-add -l`・GitHub への ssh を確かめる。鍵が見えなければ、1Password を
   トレイから終了して起動し直す

見送るとき (2・3 で合わないと分かったとき):

- `openssh/skipped-versions.txt` に「版 理由」を 1 行足して commit する。その版では落ちなくなり、
  もっと新しい版が出ると、その版が GitHub に出てから 30 日でまた落ちる。固定した版以下になった行は消してよい
- `-Check` の ※ の行は見送っても出続ける (winget に新しい版があるのは事実なので)

### Install-OpenSSH.ps1 を書くときの注意

- `dotfiles.ps1` と同じく **BOM 付きの UTF-8** で保存する
- 副作用の無い関数 (版の比べ方・winget の出力の読み方・winget の引数・状態の表) は
  `openssh/Install-OpenSSH.Tests.ps1` で確かめる。Linux の pwsh で流すので Windows には触らない
  (このファイルは manifest に無いので配られない):

  ```sh
  nix shell nixpkgs#powershell -c pwsh -NoProfile -File win/openssh/Install-OpenSSH.Tests.ps1
  ```

- winget の引数 (`Get-WingetCommands`) の upgrade には `--include-pinned` を付け、install・uninstall には付けない
  ([winget の pin](#winget-の-pin)。試験が確かめる)
- `-Check` の終了コードと締めの文 (`Get-OpenSshExitCode`・`Get-OpenSshCheckMessage`) は、96 が読む。変えるときは
  `nix/scripts/bootstrap-windows-openssh.sh` とそのテストも直す
- winget やサービスに触る部分は、実機で `-Check` と本番を打って確かめる

## ssh の設定

1Password を使う WSL のマシンでは、WSL の `ssh` は Windows の `ssh.exe` を呼ぶ ([OpenSSH](#openssh))。
`ssh.exe` が読むのは Windows 側の `%USERPROFILE%\.ssh\config` なので、そこにも WSL と同じ形を置く
(経緯は [ADR 016](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/016_ssh_config_from_dotfiles_private_20261012T131912JST/README.md))。
`manifest.toml` では配らず、`nix/scripts/bootstrap-windows-ssh-config.sh` (order 91) が
`setup --update` のたびにコピーする。

| Windows 側 | 中身 | 出所 |
| --- | --- | --- |
| `%USERPROFILE%\.ssh\config` | `Include config.d/*.ssh_config` の 1 行、その後ろの `Host *` の `SetEnv PJP_SSH_CLIENT=%u@%L`、説明のコメント | script が置く |
| `%USERPROFILE%\.ssh\config.d\<名前>.ssh_config` | 接続先 | private な dotfiles-private の `ssh/` からコピー |
| `%USERPROFILE%\.ssh\config.d\` のほかのファイル | マシン固有の接続先 | my-cloud の `ssh-config.sh` などが書く。script は触らない |

- `config.d` はファイル名の順に読まれ、同じキーは先に読んだ値が効く (WSL と同じ)
- `SetEnv PJP_SSH_CLIENT=%u@%L` は、ssh 先の herdr が「同じマシンから来た接続」を見分けるのにこの PC を名乗る
  (`<Windows のユーザー名>@<PC の名前>` のような値。[ADR 025](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/025_herdr_agent_borrow_20261020T210555JST/README.md)・
  [`nix/README.md`「forward された agent を固定名で見せる」](../nix/README.md#forward-された-agent-を固定名で見せる))。
  ssh は最初に当たった `SetEnv` の行だけを使うので、`config.d` の `Host` に `SetEnv` を書いたら、そこにも
  `PJP_SSH_CLIENT=%u@%L` を足す。前の版 (`SetEnv` の無い `config`) は、記録と同じ中身なら正本の更新として上書きされる
- 置いたファイルは、中身の sha256 を WSL の `~/.local/state/dotfiles/windows-ssh-config.deployed.json` に覚える。
  正本が変われば上書きし、正本から消えれば消す
- 旧経路が置いた `Include ~/dotfiles/ssh_config` の 1 行だけの `config` は、衝突にせず置き換える
- 書いたあとに `ssh.exe -v -G nonexistent.invalid` を流し、`config` と置いたファイルが読まれること、
  旧 clone (`C:\Users\<名前>\dotfiles`) の `ssh_config` を読んでいないことを確かめる。アクセス権で弾かれる
  (`Bad owner or permissions`)・設定の誤りで読み終えられない、などがあれば ⚠ の枠で出して止まる。
  ssh.exe を呼べない・応答しないときは、手で打つコマンドを出して進む

### ssh の設定が衝突したら

Windows で `config` や dotfiles のファイルを直していたら、触らずに diff を出して止まる。置いた記録が無いのに
中身の違うファイルが先にある (初めて配るマシンで、手で書いた `config` など) ときも同じで、「置いた記録が無く」と
出る。どちらかで解く。

1. Windows 側の中身を dotfiles-private の `ssh/` へ取り込み、commit して push する。`config` に手で書いた
   `Host` は `config.d\<名前>.ssh_config` へ移す
2. 上書きする。元は `<名前>.dotfiles-bak-<日時>` に退避される (`*.ssh_config` で終わらないので読まれない)

```sh
~/ghq/github.com/pollenjp/dotfiles/nix/scripts/bootstrap-windows-ssh-config.sh --force
```

判定だけ見るなら `--dry-run` を付ける。

## port forwarding (pf)

PowerShell 7 で `pf` を打つと、ssh の Host と port の組を選んで、`ssh -NT -o ExitOnForwardFailure=yes -L … <Host>` を
いまの PowerShell の中で張る ([設計](https://github.com/pollenjp/dotfiles-private/blob/main/docs/superpowers/specs/2026-11-07-pf-port-forward-design.md))。
画面は PowerShell だけで描く (fzf も PowerShell Gallery のモジュールも入れない)。Windows PowerShell 5.1 では動かない (5.1 にも
`dotfiles.ps1` を読ませていれば、`pf` を打つと版が違うと出て止まる)。WSL・Linux の版は無い。

```text
pf  Host を選ぶ  › web
───────────────────────────────────────
> web-prod        前回: 3000 15432
  web-staging
───────────────────────────────────────
↑↓ 選ぶ  Enter 決める  Esc やめる  (文字を打つと絞り込む)
```

```text
pf  web-prod
───────────────────────────────────────
> [x] 3000  → localhost:3000  front
  [ ] 8080  → localhost:8080  api       使用中
  [x] 15432 → db:5432         postgres  この PC
  ssh の設定でも張る: 6000
───────────────────────────────────────

Space 切り替え  a 足す  e 直す  d 消す  Enter つなぐ  Esc 戻る
```

| 打つもの | すること |
| --- | --- |
| `pf` | Host を選ぶ画面から始める |
| `pf <Host>` | ssh の設定の Host と同じ名前 (大文字小文字は問わない) なら、port を選ぶ画面から始める (Esc でやめる)。違えば、その文字列で絞り込んで Host を選ぶ画面を開く (語を並べた `pf web prod` は空白でつないで絞り込む) |

- Host の一覧は `%USERPROFILE%\.ssh\config` と、そこから `Include` するファイル (`config.d\` など) の `Host` から作る。
  ワイルドカード (`*`・`?`・`!`) を含む名前は出さない。最近つないだ Host を上に出し、前回つないだ port を添える
- Host を選ぶ画面は、文字を打つと絞り込む (空白で区切った語が、どれも名前に含まれる Host だけ)。Backspace で 1 字消し、
  Ctrl+U で空にする。↑↓ (Ctrl+P・Ctrl+N) で選び、Enter で決め、Esc・Ctrl+C でやめる
- port を選ぶ画面は、前回つないだ組にチェックを付けて開く (初めての Host では全部)
  - 「使用中」は、手元でもう待ち受けている port。チェックしたまま Enter を押すと、つながずに知らせる
  - 「この PC」は、その PC で足した・直した組 (共有の組に無い・共有の組と中身が違う)
  - 「ssh の設定でも張る」は、その Host の ssh の設定にある `LocalForward`・`DynamicForward` (`ssh -G <Host>` で読む)。ssh は
    設定の転送も一緒に張るので、その port が使用中のとき・同じ port にチェックがあるときも、つながずに知らせる
  - Windows が予約した port の範囲 (Hyper-V・WSL・Docker が取る。`netsh interface ipv4 show excludedportrange protocol=tcp` で
    見る) は「使用中」と出ない。そこに入る port は、ssh が bind の誤りで落ちる
- つなぐと、打つコマンドを 1 行出してから、いまの PowerShell の中で ssh を動かす。タブの名前を `pf: <Host>` にし、Ctrl+C で
  止めたら戻す。ssh が自分で終わったとき (つながらない・切れた) は、終了コードを 1 行出す。張った転送の一覧・ほかの窓からの
  止め方・切れたときのつなぎ直しは無い

| キー (port を選ぶ画面) | すること |
| --- | --- |
| ↑ ↓ | 選ぶ |
| Space | チェックを切り替える |
| a | 組を足す (下の書き方で打って Enter。Esc でやめる。足した組にはチェックが付く) |
| e | 選んだ組を直す (今の書き方が入って開く) |
| d | 選んだ組を消す (共有の組は、その PC でだけ隠す) |
| Enter | チェックした組でつなぐ |
| Esc | Host を選ぶ画面へ戻る (`pf <Host>` で始めたならやめる) |
| Ctrl+C | やめる |

### 組の書き方

`ssh -L` と同じ形に、空白を空けてメモを続ける。pf の画面で足す・直すときも、dotfiles-private のファイルも同じ書き方。

| 書くもの | 手元 | つなぎ先 (向こうのマシンから見た名前) |
| --- | --- | --- |
| `3000` | 3000 | `localhost:3000` |
| `13000:3000` | 13000 | `localhost:3000` |
| `15432:db:5432 postgres` | 15432 | `db:5432` (メモは `postgres`) |

- port は 1〜65535。つなぎ先の IPv6 は `[::1]` のように囲む。bind_address (`127.0.0.1:3000:…`) と Unix ソケットは書けない
- 1 つの Host の中で、手元の port は重ねない (ssh は同じ手元の port を 2 つ張れない)。pf は組を手元の port で見分ける

### 組の置き場所

| ファイル | 中身 | 書くもの |
| --- | --- | --- |
| dotfiles-private の `ssh/port-forward.toml` | 共有の組の正本 (`[hosts]` の下に `<Host 名> = ["3000", …]`) | 手で書いて commit・push する |
| `%USERPROFILE%\.config\port-forward\hosts.json` | 共有の組 (正本を JSON にしたもの) | `setup --update` の `bootstrap-windows-port-forward.sh` (order 99)。pf は書かない |
| `%USERPROFILE%\.config\port-forward\local.json` | その PC で足した・直した・隠した組と、前回つないだ port・最近つないだ Host | pf |

- 共有の組を足す・直すときは、dotfiles-private の `ssh/port-forward.toml` を直して `--check` で確かめ、commit・push して、
  各 Windows の PC の WSL で `~/dotfiles/setup --update` を流す。Host 名は ssh の設定と同じ綴りで書き、`.` を含むときは
  `"…"` で囲む (囲まないと TOML の入れ子の表になり、止まる):

  ```sh
  ~/dotfiles/nix/scripts/bootstrap-windows-port-forward.sh --check   # 正本の書き方を確かめるだけ (Windows には触らない)
  ```

- pf の画面で足した組は local.json に残り、dotfiles-private へは書き戻さない (共有したくなったら正本に書く)
- 共有の組を画面で直す・消すと、その PC でだけ上書きする・隠す。共有と同じ中身に直す・隠した port を a で足し直すと、共有の組に戻る
- pf は組を変えるたびに local.json を読み直してから書く (別の窓で開いた pf の変更を消さない)。local.json が読めないときは、
  上書きせずに止まる (直すか消してから打ち直す)。hosts.json が読めないときは、注意を 1 行出して共有の組なしで開く

| 打つもの (WSL) | すること |
| --- | --- |
| `nix/scripts/bootstrap-windows-port-forward.sh` | 写す (`setup --update` でも毎回走る) |
| `nix/scripts/bootstrap-windows-port-forward.sh --dry-run` | 判定だけ見る |
| `nix/scripts/bootstrap-windows-port-forward.sh --force` | 衝突でも、元を `hosts.json.dotfiles-bak-<日時>` に退避して上書きする |
| `nix/scripts/bootstrap-windows-port-forward.sh --check` | 正本の検証だけ (Windows の側も記録も見ない) |

- 写すのは `dotfiles.wsl.windowsFiles.enable = true` のマシンだけ。dotfiles-private が無い・正本が無いマシンでは何もしない
  (置いてある hosts.json も消さない)
- 正本に書き方の誤り・手元の port の重なりがあると、何も書かずに誤りを全部並べて止まる (exit 1)
- 置いた中身の sha256 を `~/.local/state/dotfiles/windows-port-forward.deployed.json` に覚える。hosts.json を Windows で書き換えて
  いた (か、置く前からあった) ら、触らずに diff を出して止まる (衝突)。Windows 側の中身を正本へ取り込んで commit・push するか、`--force` で解く
- 止まると (exit 1)、setup はこの手順 (order 99) で止まり、後ろの [Windows Terminal](#windows-terminal) の手順・wsl-mtu-guard・
  exe-exec-trace と最後の「残りの手作業」は、直して流し直すまで走らない

### Start-PortForward.ps1 を書くときの注意

- `dotfiles.ps1` と同じく **BOM 付きの UTF-8** で保存する
- 書き方の解釈・ssh の設定の読み取り・重ね方・キーの読み分け・描いた行・ファイルの読み書きは
  `port-forward/Start-PortForward.Tests.ps1` で確かめる。Linux の pwsh で流すので Windows には触らない
  (このファイルは manifest に無いので配られない):

  ```sh
  nix shell nixpkgs#powershell -c pwsh -NoProfile -File win/port-forward/Start-PortForward.Tests.ps1
  ```

- 画面は Linux の pwsh でも動かして見られる。`-HomeDir` で `.ssh/config` と `.config/port-forward/` を探す家を、`-Ssh` で動かす
  ssh を差し替え、tmux の中で起こして `send-keys` と `capture-pane` で見る。偽の ssh は、受けた引数を出して待つ script でよい
  (`-G` を受けたら、設定の転送を `localforward 6000 [localhost]:6000` の形で出す):

  ```sh
  tmux new-session -d -s pf -x 100 -y 20 \
    "pwsh -NoProfile -File win/port-forward/Start-PortForward.ps1 -HomeDir /tmp/pf-home -Ssh /tmp/pf-home/fake-ssh"
  ```

- Windows で見るのは、Windows Terminal での崩れ (全角の幅・色・`›` や日本語が `?` にならないか)・タブの名前・Ctrl+C で止めたあとの
  戻り。画面は `[Console]::Write` で描き、その間だけ `[Console]::OutputEncoding` を UTF-8 にしている (console のコードページの
  ままだと、en-US の 437・ja-JP の 932 に無い文字が `?` になる。Linux の pwsh のテストでは見えない)

## PowerToys

`powertoys/keyboard-manager/` は PowerToys の Keyboard Manager の割り当てで、manifest で配る。
IME のキー設定の F13 ([Google 日本語入力](#google-日本語入力)) は、ここの CapsLock → F13 が前提になっている
([TKT-139](https://app.notion.com/p/Windows-Google-dotfiles-win-3f679149a66f81b1a592d85d7300a62b))。

| ファイル | 中身 |
| --- | --- |
| `default.json` | エンジンが読む割り当て。CapsLock (VK 20) → F13 (VK 124)、左 Shift + 英数 (VK 160 + 240) → CapsLock |
| `editorSettings.json` | 新しいエディタ (WinUI 3) が持つ割り当ての一覧。エンジンは読まない |

- **PowerToys が書いたバイト列のまま置く。** `default.json` は改行の無い 1 行、`editorSettings.json` は
  CRLF で、どちらも末尾に改行が無い。エディタで同じ内容を保存し直してもバイト列が変わらず、衝突に
  ならない。`.gitattributes` (改行を変えない) と `.editorconfig` (末尾に改行を足さない・CRLF) で守っている
- 配ったあと、続く `nix/scripts/bootstrap-windows-powertoys.sh` (order 91) が、PowerToys が入っていなければ先に入れ
  ([PowerToys を入れる](#powertoys-を入れる-winget))、Keyboard Manager と自動起動がオフならオンにして
  ([Keyboard Manager と自動起動をオンにする](#keyboard-manager-と自動起動をオンにする))、名前付きイベント
  `PowerToys_KeyboardManager_Event_Settings` を `powershell.exe` から送って読み直させる (エンジンは
  ファイルを見張っていない)。`default.json` の sha256 が前回読み直させたときと同じなら何もしない。
  Keyboard Manager がオンで PowerToys が動いていなければ、起動したときに読む
- エンジンが読むのは、同じディレクトリの `settings.json` が指す有効なプロファイル (`activeConfiguration`) の JSON。
  `settings.json` が無い (PowerToys の設定画面をまだ開いていない) ときと、プロファイルが `default` でないときは、
  送っても起動し直しても `default.json` は読まれない。91 は送る前にこれを確かめ、読まれないときは送らず記録もせずに
  案内して飛ばす (exit 0。入れたばかりのマシンは[PowerToys を入れる](#powertoys-を入れる-winget))
- interop が落ちていて送れないときは、PowerToys の設定 → Keyboard Manager を一度オフにしてオンに戻す
- エディタで割り当てを変えると、次の `setup --update` が衝突として止まる ([衝突したら](#衝突したら))。
  `cp` で取り込むときは 2 つとも取り込む

  ```sh
  d='/mnt/c/Users/<名前>/AppData/Local/Microsoft/PowerToys/Keyboard Manager'
  cp "${d}/default.json" "${d}/editorSettings.json" win/powertoys/keyboard-manager/
  ```

- PowerToys のエディタで同じ割り当てを手で作ってあったマシンでは、初めて配るときに 2 つとも衝突になる
  (「置いた記録が無く」と出る)。`editorSettings.json` の id (GUID) は割り当てを作るたびに振られ、
  `default.json` は `"operationType":0` (普通の割り当て) の有無が違うことがあり、同じ割り当てでも
  バイト列が揃わない。diff がこれだけ (id とその並び・`operationType`) なら、
  `nix/scripts/bootstrap-windows-files.sh --force` で上書きしてよい (取り込むより、repo もほかのマシンも
  変えずに済む)

### Keyboard Manager と自動起動をオンにする

Keyboard Manager は PowerToys の既定でオフで、オフだとエンジンが起動しないので、割り当てを配っても効かない。自動起動も、
入れたばかりのマシンではオフで、サインインしても PowerToys が動かない
([ADR 041](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/041_win_powertoys_enable_km_20261105T092803JST/README.md))。91 は全体の設定
`%LOCALAPPDATA%\Microsoft\PowerToys\settings.json` の `enabled["Keyboard Manager"]` と `startup` を毎回見る。

- 両方 `true` なら何もしない (止めない・書かない)
- どちらかが `true` でなければ、PowerToys を止める → 両方を `true` にする → 起動する → 確かめる。PowerToys の本体は、
  このファイルを起動したときに読み、動いている間に書いても効かないため。PowerToys は数秒止まり、設定画面を開いていれば閉じる
- 手で Keyboard Manager か自動起動をオフにしていても、次の `setup --update` でオンに戻す。動いていなくても起動する
- ほかのモジュールとほかの項目の値は変えない。ファイルが無ければ、2 つだけのファイルを作って起動する (PowerToys は無い項目を
  既定値で読み、設定画面が起動したときに全部書く)
- 止めるのはトレイのウィンドウ (`PToyTrayIconWindow`) への `WM_CLOSE` で、終わらなければ強制で止める。見るのは今のセッションの
  プロセスだけ。起動は `Start-Process` で、setup が終わっても残る。Keyboard Manager のエンジンが動くのを 30 秒まで待ち、設定を読み直し、自動起動のタスク
  (タスク スケジューラの `\PowerToys\Autorun for <ユーザー>`) があるかも見る

できないときは警告して (setup の最後のまとめにも残す)、後ろの手順へ進む。Keyboard Manager がオフのままなら、記録も
イベントも触らず、「読み直し済み」とも出さない。書いた後に起動や確認でつまずいたら印 (`~/.local/state/dotfiles/powertoys-enable.pending`)
を残し、次の `setup --update` は両方 `true` でも起動と確認をやり直す (動いていれば起動し直さない)。

| 起きたこと | 91 がすること |
| --- | --- |
| 設定が `run_elevated: true` | 止めない・書かない (起動すると UAC の確認が出るため) |
| 止められない (今のセッションの PowerToys が管理者で動いている) | 書かない |
| `powershell.exe` が失敗する | 書かない。止める途中で切れたかもしれないので、動いていなければ起動する |
| 設定が読めない (JSON でない・空) | 止めない・書かない |
| 書けない | 元の設定のまま起動する |
| 起動できない | 設定には書いてあるので、スタートメニューから起動するよう出す |
| エンジンが動かない・起動の後にオフへ戻っている・タスクが無い | 手で確かめる手順を出す |

手でオンにするときは、PowerToys の設定画面で「入出力」→「Keyboard Manager」と、「全般」→「起動時に実行」(Run at startup) を
オンにしてから、`setup --update` (か `nix/scripts/bootstrap-windows-powertoys.sh`) を流し直す。

### FancyZones

`powertoys/fancyzones/` は PowerToys の FancyZones の設定で、`windowsFiles` が有効なマシン全部に同じものを配る。PC ごとの切り替えは
無い ([ADR 042](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/042_win_powertoys_fancyzones_20261106T100504JST/README.md)、
カスタムレイアウトの足し方は [ADR 046](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/046_win_fancyzones_layouts_by_uuid_20261109T200910JST/README.md)、
ディスプレイへのあて方は [ADR 053](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/053_win_fancyzones_layout_by_resolution_20261110T213751JST/README.md)、
横向きの既定と、全部の仮想デスクトップへの組の作り方は [ADR 054](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/054_win_fancyzones_renumber_20261113T061644JST/README.md))。
どれも manifest では配らず、`nix/scripts/bootstrap-windows-fancyzones.sh` (order 92) が `setup --update` のたびに書く。

| ファイル | 中身 | 書き方 |
| --- | --- | --- |
| `custom-layouts.json` | エディターの「カスタム」に登録したレイアウト (今は `4k-43inch` と `1080p`)。uuid・名前・座標だけ | PC の `custom-layouts.json` へ、レイアウトを uuid ごとに足す。PC にだけあるレイアウトには触らない ([カスタムレイアウト](#カスタムレイアウト)) |
| `layout-rules.json` | ディスプレイの解像度から、あてるレイアウトを決める決まり (今は 3840x2160 に `4k-43inch`、それ以外に `1080p`)。レイアウトの名前で書く | PC の `default-layouts.json` の横向きの既定を `default` にそろえ、`applied-layouts.json` のうちテンプレートのままの組を決まりのレイアウトで埋め、組の無い仮想デスクトップに組を作る。手であてたものは残す ([ディスプレイへのあて方](#ディスプレイへのあて方)) |
| `managed.json` | `settings.json` のうち dotfiles が持つキーだけを、同じ形で書いたもの。今は「Windows スナップのオーバーライド」(`fancyzones_overrideSnapHotkeys`) を `true` | そのキーだけを `settings.json` へ書く ([持つキー](#持つキー)) |

| 打つもの | すること |
| --- | --- |
| `nix/scripts/bootstrap-windows-fancyzones.sh` | 持つキーの値が違えば書き、PC に無いレイアウトを足し、横向きの既定をそろえ、埋める組にレイアウトをあて、組の無い仮想デスクトップに組を作る (`setup --update` でも毎回走る) |
| `nix/scripts/bootstrap-windows-fancyzones.sh --dry-run` | 判定だけ見る (ディスプレイの解像度と仮想デスクトップの一覧は `powershell.exe` で聞く) |
| `nix/scripts/bootstrap-windows-fancyzones.sh --force` | PC のエディターで直した・消したレイアウトも repo の中身にし、手であてたカスタムレイアウト・blank の組も決まりのレイアウトにする (書き換える前のファイルは退避する。先に `--dry-run --force` で見られる) |
| `nix/scripts/bootstrap-windows-fancyzones.sh --import <名前>` | PC のレイアウトを名前で選び、repo の `custom-layouts.json` へ写す (繰り返せる。commit は自分で) |
| `nix/scripts/bootstrap-windows-fancyzones.sh --check` | `managed.json`・`custom-layouts.json`・`layout-rules.json` の検証だけ (CI の lint でも走る) |

持たないもの:

| ファイル | わけ |
| --- | --- |
| `applied-layouts.json` | どのモニター × 仮想デスクトップの組にどのレイアウトをあてたか。モニターのシリアルが入り、PC ごとに違う (この repo は public)。持つのは、解像度であてるレイアウトを決める決まり (`layout-rules.json`) だけ |
| `default-layouts.json` | 組の無い画面にあてる横向き・縦向きの既定。横向きの既定だけを、setup が `layout-rules.json` の `default` にそろえる ([ディスプレイへのあて方](#ディスプレイへのあて方))。縦向きは FancyZones の既定のまま |
| `layout-hotkeys.json`・`layout-templates.json` | 今は空か既定のまま |
| `settings.json` のほかのキー | 持ちたくなったら `managed.json` に足す ([キーを足す](#fancyzones-のキーを足す)) |

#### カスタムレイアウト

repo の `custom-layouts.json` のレイアウトを、PC の `custom-layouts.json` と uuid で突き合わせ、レイアウトごとに足す。前に足した中身は
`~/.local/state/dotfiles/windows-fancyzones.applied.json` に uuid ごとに覚え、PC のエディターで直したものと見分ける (Windows Terminal の
キーごとの記録と同じ見分け方。違うのは、止めずに知らせて先へ進むところ)。

| PC 側の、そのレイアウト | すること |
| --- | --- |
| 無い (足した記録も無い) | 末尾に足す |
| repo と同じ | 何もしない (記録が無ければ記録だけする) |
| repo と違うが、前に足した中身のまま | repo が更新されたので、同じ位置で書き換える |
| repo とも前に足した中身とも違う・足す前から違う中身があった | PC のエディターで直したものとして、書き換えずに ⚠ で知らせる |
| 前に足したのに無い | PC で消したものとして、足し直さずに ⚠ で知らせる |

- **PC にだけあるレイアウト (そのマシンのエディターで作ったもの) には触らない。** 足したレイアウトをどのディスプレイにあてるかは、
  [ディスプレイへのあて方](#ディスプレイへのあて方)
- 知らせたものは、setup の最後の「警告のまとめ」にも出す。手順は止めない (exit 0)。違い (diff) は、その場の出力にだけ出す。解き方:

  ```sh
  # PC の中身を残す: repo へ取り込んで commit する (名前は PC のエディターに出る名前。⚠ の文にそのまま打てる形で出る)
  nix/scripts/bootstrap-windows-fancyzones.sh --import '4k-43inch'
  git add win/powertoys/fancyzones/custom-layouts.json && git commit

  # repo の中身にする (直したものは戻し、消したものは足し直す。書き換える前のファイルは退避する)。
  # --force は、手でディスプレイにあてたカスタムレイアウト・blank の組も決まりのレイアウトで上書きするので、先に --dry-run --force で見る
  nix/scripts/bootstrap-windows-fancyzones.sh --dry-run --force
  nix/scripts/bootstrap-windows-fancyzones.sh --force
  ```

- PC で作ったレイアウトをほかの PC にも配るときも、`--import` で取り込んで commit する。repo の同じ uuid は同じ位置で置き換え、無ければ
  末尾に足す。PC に同じ名前が 2 つあるとき・repo に同じ名前の別のレイアウトがあるときは、エディターで名前を変えてから取り込む。
  `custom-layouts.json` に commit していない変更があると、何も書かずに止まる。PC のファイルと記録には書かない (次の setup が、同じ中身と見て記録する)
- 中身は JSON として読んだ値で比べる (キーの順・字下げ・改行・エスケープの違いは同じとみなす)。エディターは閉じるたびに 5 つのファイルを
  書き直すが、中身が同じなら、開いて閉じただけでは知らせない
- **エディターを開いたまま流さない。** エディターは閉じるときに、開いたときの中身で書き直すので、足したレイアウトが消える (次の回に
  「PC から消えています」と出るので、`--force` で足し直す)
- repo から消したレイアウトは、PC からは消さない (記録からだけ消す)
- PC に `custom-layouts.json` が無ければ、repo のレイアウトだけで作る (記録があっても。エディターはファイルを消さないので、無いのは
  PowerToys の設定を消したとき)
- 書く形は PowerToys の形 (字下げ 2・CRLF・末尾に改行なし)。隣に書いて `mv` した後に `touch` する。動いている FancyZones は `LastWriteTime` の
  変更しか見ていないので、`mv` だけでは気づかない。エディターは起動するたびに読む。書き換える前のファイルは
  `~/.local/state/dotfiles/windows-fancyzones/backup/<UTC の時刻>-<pid>/` に退避する (新しい方から 10 回分)
- repo の `custom-layouts.json` も PowerToys の形で置く (`--check` が見る。`--import` が書き直したときの差分を、中身の変更だけにするため)。
  uuid は大文字の `{…}` で、uuid と名前は重ねない。`.gitattributes` (改行を変えない) と `.editorconfig` (CRLF・末尾に改行を足さない) で守っている
- PC のファイルを読めない (エディターが書いている途中なら、5 回まで読む)・記録が壊れている・repo のファイルに誤りがあるときは、レイアウトを
  書かずに ⚠ で知らせる。記録が壊れたら、消して流し直す (repo と違うレイアウトは、PC で直したものとして知らせる)

#### ディスプレイへのあて方

FancyZones は、レイアウトを「モニター × 仮想デスクトップ」の組ごとにあてる (PC の `applied-layouts.json`)。組の無い画面 (新しいモニター・
開いたことの無い仮想デスクトップ・番号が振り直された画面) には、横向き・縦向きの既定 (`default-layouts.json`。FancyZones の既定は priority-grid と
rows) をあてる。エディターを開いてディスプレイの数だけあてて回らずに済むよう、`bootstrap-windows-fancyzones.sh` が次の 3 つをする
([ADR 053](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/053_win_fancyzones_layout_by_resolution_20261110T213751JST/README.md)・
[ADR 054](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/054_win_fancyzones_renumber_20261113T061644JST/README.md))。

1. 横向きの既定を、決まりの `default` のレイアウト (今は `1080p`) にそろえる
2. テンプレートのままの組 (と、横向きの既定のままで決まりが別のレイアウトの組) を、解像度の決まりのレイアウトで埋める
3. つながっている横向きのディスプレイの組を、Windows にある全部の仮想デスクトップへ作る

決まりは `layout-rules.json` に、レイアウトの名前で書く。

```json
{
  "rules": [
    { "resolution": "3840x2160", "layout": "4k-43inch" }
  ],
  "default": "1080p"
}
```

- `resolution` は今の表示の解像度 (`幅x高さ`。物理の値で、拡大率に左右されない)。ちょうど一致したら、その `layout`。どれにも当たらなければ `default`
- `layout`・`default` は `custom-layouts.json` のレイアウトの名前 (canvas のものだけ。あてる値をエディターで確かめたのが canvas だけのため)。
  `--check` が確かめる (CI の lint でも走る)
- 解像度と仮想デスクトップの一覧は `powershell.exe` で Windows に聞く (FancyZones と同じ手順で、1 回の呼び出しで両方を聞く。0.6〜0.8 秒ほど
  かかる)。`applied-layouts.json` に組があれば毎回聞く (組の無い仮想デスクトップと、ディスプレイの番号の振り直しは、Windows に聞かないと分からない)

| 組 (モニター × 仮想デスクトップ) | 既定 | `--force` |
| --- | --- | --- |
| 合うディスプレイが無い (つながっていない)・縦向き | 触らない | 触らない |
| 決まりのレイアウトがあたっている | 何もしない | 何もしない |
| テンプレートのまま (blank を除く。エディターで選んだものも) | 決まりのレイアウトにする | 同じ |
| 前に setup があてたままで、決まりか解像度が変わった | 新しい決まりのレイアウトにする | 同じ |
| 横向きの既定 (`default` のレイアウト) があたり、setup があてた記録と違う (4K の画面の新しい組が `1080p` で始まったとき) | 決まりのレイアウトにする | 同じ |
| 手であてたカスタムレイアウト (PC にだけあるものも)・blank | 残し、まとめて 1 行知らせる (警告のまとめには載せない) | 決まりのレイアウトにする |
| 組が無い (つながっている横向きのディスプレイで、その仮想デスクトップに今の番号の組が無い) | 組を作り、決まりのレイアウトにする (そのデスクトップの番号の違う古い組が手であてたものなら、そのレイアウトを写す) | 組を作り、決まりのレイアウトにする |
| 決まりのレイアウトが PC の `custom-layouts.json` に無い (PC で消した) | 飛ばして ⚠ で知らせる | `--force` が足し直してから、あてる |

- **手であてたものは、既定では残す。** blank (レイアウトなし) も、そのディスプレイではゾーンを使わないと選んだ印として残す。上書きするなら:

  ```sh
  nix/scripts/bootstrap-windows-fancyzones.sh --dry-run --force   # 何が変わるかを先に見る
  nix/scripts/bootstrap-windows-fancyzones.sh --force             # 上書きする (PC で直した・消したカスタムレイアウトも repo の中身に戻る)
  ```

- setup があてた組・作った組は `~/.local/state/dotfiles/windows-fancyzones.assigned.json` に覚える (キーはモニターの ID と仮想デスクトップで、
  シリアルは入れない)。後で決まりを足したとき・ディスプレイの解像度を変えたときに、setup があてたままの組は新しい決まりへ移り、手であてた組は残る
- シリアルは見ない・読まない・出さない (FancyZones は同じ型のモニターに同じシリアルを入れるので、見分けにも使えない)。シリアルだけが違う
  古い組も、同じレイアウトにする
- 変えた組・作った組は 1 組 1 行で出す (モニター ID・解像度・仮想デスクトップの GUID の頭 8 桁・前 → 後。作った組の前は「組なし」)。書き方
  (隣に書いて `mv` → `touch`・退避・PowerToys の形) はカスタムレイアウトと同じで、FancyZones はその場で読み直す
- `powershell.exe` が無い・失敗する・60 秒たっても終わらない・`applied-layouts.json` を読めない・記録が壊れている・`layout-rules.json` に
  誤りがあるときは、書かずに ⚠ で知らせて先へ進む (exit 0)

**番号の振り直しと横向きの既定。** Windows は、ディスプレイの番号 (`\\.\DISPLAY1` の 1) を振り直すことがある。FancyZones の本体は番号が
変わっても、同じポート (instance) の組をそのまま使う。エディターは組を番号の一致で引くので、振り直しの後に
エディターを開くと、古い組を引けない画面に横向きの既定をあて、閉じるときにその組を先頭に書く。本体は重なった組の先頭を使うので、そこでゾーンが
変わる。

- 横向きの既定を `default` (`1080p`) にそろえておくので、そのときも `1080p` で始まる (1920x1080 の画面はそのまま正しい)。4K の画面は次の
  setup まで `1080p` のままで、次の setup が `4k-43inch` にする
- 4K の画面にエディターで手で `1080p` をあてると、横向きの既定と見分けられず、次の setup で `4k-43inch` に戻る (残したいなら `layout-rules.json`
  を変える)
- 横向きの既定に書く値は、エディターがカスタムレイアウトを既定にしたときと同じ (`zone-count`・`sensitivity-radius` は 0。FancyZones はゾーンを
  計算するときに `custom-layouts.json` から引き直す)。エディターは閉じるたびに `default-layouts.json` を書き直すので、値をそろえて書き戻しを
  繰り返さない。そろっているかは `type` と `uuid` で見る。ファイルが無ければ横向きの項目だけで作る。縦向きの既定には触らない
- 決まりの `default` のレイアウトが PC に無い (PC で消した) ときは、横向きの既定を書かずに ⚠ で知らせる (`--force` で足し直すと、その回に書く)。
  横向きの既定がすでにそのレイアウトでも、PC に無ければ「揃っています」とは言わず、既定が使えないと ⚠ で知らせる

**全部の仮想デスクトップに組を作る。** 振り直しの後にエディターを開いても、今の番号の組があればエディターはそれを引く。

- つながっている横向きのディスプレイごとに、同じ画面 (モニター ID と instance が同じ) の組の device を写し、仮想デスクトップだけを替えて、
  組の無いデスクトップへ組を作る。開いたことの無いデスクトップにも作る。シリアルは中を見ずにそのまま写す (どれが今のシリアルかを読まずに
  決められないので、シリアルの違う組はシリアルごとに作る)
- 今の番号の組がどこにも無い (番号が振り直された直後) ときは、番号の違う組から写し、番号を今のものにする。そのデスクトップにある古い組が、
  手であてたカスタムレイアウト・blank なら、作る組もそのレイアウトにし、記録しない (手であてたものとして残る。`--force` なら決まりのレイアウトにする)。
  エディターは今の番号の組を引くので、決まりのレイアウトで作ると、次にエディターを開いたときに手であてたものが消えるため
- 作った組は末尾に足す。先頭に置くと、本体が同じとみなす古い組より先に使い、手であてたレイアウトを隠しうるため。本体が `applied-layouts.json` を
  書き直すと (組の無い画面に既定をあてたときなど)、同じとみなす古い組の後ろにある組は捨てられるが、次の setup がまた作る (そのたびに書き換え、
  退避が 1 つ増える。退避は新しい方から 10 回分なので、前の退避を残したいときは別に写しておく)
- 同じ画面の組がどこにも無いディスプレイ (FancyZones がまだその画面の組を書いていない) には作らず、1 行で知らせる (警告のまとめには載せない)。
  縦向き・つながっていないディスプレイには作らない
- 仮想デスクトップを足したら、次の setup (か `~/dotfiles/setup --steps bootstrap-windows-fancyzones`) でそのデスクトップの組もそろう

#### 持つキー

`bootstrap-windows-fancyzones.sh` は `managed.json` のキーを `settings.json` と比べ、値が違えばそのキーだけを書く。

- **設定画面で手で変えていても、次の `setup --update` で dotfiles の値へ戻す。** 戻したことを 1 行出し、衝突では止めない。別の値にしたいなら
  `managed.json` を直して commit する。持つキーには、Windows Terminal と違い、記録・取り込み・退避が無い (PowerToys は `settings.json` に全部のキーを
  書くので、Terminal の判定のままだと初回に既定の `false` と衝突する。`--force` はカスタムレイアウトとディスプレイへのあて方の、`--import` は
  カスタムレイアウトのもの)
- 値が同じなら書かない (`LastWriteTime` も変えない)
- ほかのキーの値・キーの順・1 行で末尾に改行なしの形は変えない
- 隣に書いて `mv` した後に `touch` する。FancyZones は `LastWriteTime` の変更しか見ていないので、`mv` だけでは気づかない。読みかけを見せないよう、
  その場には書かない。FancyZones はその場で読み直し、PowerToys は起動し直さない
- `settings.json` が無ければ、持つキーと `name`・`version` だけのファイルを作る。FancyZones は無いキーを今の値のまま読み、設定画面は既定値で読んで、
  開いたときに全部のキーを書く (持つキーの値はそのまま)。FancyZones は `name` が無いとエラーのダイアログを出す
- `managed.json` から消したキーは、`settings.json` からは消さない。最後の値が残り、以後は戻さない
- 読めない (JSON でない)・書けないときは、警告して書かずに進む (exit 0)。設定画面が書いている途中に当たっても読めるよう、5 回まで読む
- FancyZones がオフ (全体の `settings.json` の `enabled.FancyZones` が `false`) のマシンでは、設定が効かないので警告する (setup の最後のまとめにも残す)。
  自動でオンにはしない。オンにするのは PowerToys の設定画面の「ウィンドウとレイアウト」→「FancyZones」。FancyZones は既定でオンなので、キーやファイルが無ければ警告しない。読めないときは、確かめられないと警告する
- 設定画面を開いたまま流すと、設定画面が前の値を持ったままになることがある (確かめていない)。そのまま何かを変えて前の値へ戻っても、次の `setup --update` で戻す
- 効いているかは、Win + 矢印キーで窓がゾーンの間を動くかで確かめる

#### FancyZones のキーを足す

1. PowerToys の設定画面で値を決める (その場で `settings.json` に書かれる)
2. `settings.json` の `properties` の同じキーを、同じ形 (`{"value": …}`) で `managed.json` に写す。script は直さない。object を辿った先の、object でない値 1 つが
   持つキー 1 つなので、ホットキーのように値が object のキーは、持ちたい項目だけを書いてよい
3. `nix/scripts/bootstrap-windows-fancyzones.sh --check` で検証し、`--dry-run` で「揃っています」と出るのを見る
4. commit して `~/dotfiles/setup --update`

### PowerToys を入れる (winget)

PowerToys は winget の `Microsoft.PowerToys` を user スコープ (`PowerToysUserSetup-…exe`。管理者は要らない) で入れる。
版は固定せず、winget pin も足さない。PowerToys は自分で新しい版を知らせる
([ADR 017](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/017_win_apps_winget_20261012T115007JST/README.md)、[TKT-143](https://app.notion.com/p/winget-Windows-Google-PowerToys-Google-dotfiles-3f779149a66f817a8944c9e4e460383f))。

| 打つもの | すること |
| --- | --- |
| `Install-PowerToys -Check` (PowerShell) | 入っているかを出すだけ。入っていれば終了コード 0、入っていなければ 3 |
| `Install-PowerToys` (PowerShell) | 入っていなければ入れる (`-IfMissing` を付けても同じ) |
| `nix/scripts/bootstrap-windows-powertoys.sh` (WSL) | `setup --update` でも毎回走る。先に `-Check` を流し、入っていなければ `-IfMissing` で入れる |

- 入っているかは、`PowerToys.exe` が `%LOCALAPPDATA%\PowerToys\` (user スコープ) か `C:\Program Files\PowerToys\`
  (machine スコープ) にあるかで見る。この PC は user スコープ
- 入れられなかったら (ネットワーク・winget の失敗)、⚠ で囲んで知らせ、そのまま次へ進む
  (setup は止めない)。次の `setup --update` でも、もう一度入れにいく
- setup が待つ上限は、`-Check` が 60 秒、`-IfMissing` が 600 秒。時間切れになったらそう出して、そのまま次へ進む
  (どちらでも setup は止めない)
- 入れた直後に PowerToys が動いていなくても、91 が Keyboard Manager と自動起動をオンにするときに起動する
- 入れたばかりのマシンでは、PowerToys の設定画面が一度開くまで、Keyboard Manager は配った割り当てを読まない。
  エンジンが読む `settings.json` (有効なプロファイルの名前) を作るのは設定画面だけで、作っても読み直しはしないため
  ([ADR 017](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/017_win_apps_winget_20261012T115007JST/README.md) §1 の 7)。設定画面は最初の起動で開くので、
  91 は入れた直後 (止める前) と起動した直後に、`settings.json` が読めるようになるのを 30 秒まで待つ。エンジンはこのファイルが無い間に
  起動すると何も読まないので、待つときは記録を消す (`default.json` が同じでも、できた後に必ず読み直させる)。できれば読み直させ、できなければ
  記録せずに「設定画面を一度開いてから流し直す」よう案内するので、開いてから `setup --update`
  (か `nix/scripts/bootstrap-windows-powertoys.sh`) を流し直す。そのときに 91 が読み直させる

### Install-PowerToys.ps1 を書くときの注意

- `dotfiles.ps1` と同じく **BOM 付きの UTF-8** で保存する
- 副作用の無い関数 (置き場所の候補・winget の引数・状態の表・流れ) は `powertoys/Install-PowerToys.Tests.ps1` で
  確かめる。Linux の pwsh で流すので Windows には触らない (このファイルは manifest に無いので配られない):

  ```sh
  nix shell nixpkgs#powershell -c pwsh -NoProfile -File win/powertoys/Install-PowerToys.Tests.ps1
  ```

- winget やファイルに触る部分は、実機で `-Check` を打って確かめる

## Google 日本語入力

`google-japanese-input/` は Google 日本語入力の設定とキー設定のテキストで、manifest では配らない。
Windows 側の `config1.db` は protobuf のバイナリで、保存のたびに時刻が入るので、
`nix/scripts/bootstrap-windows-google-ime.sh` (order 98) がテキストから組み立てて配る
([ADR 015](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/015_win_google_ime_powertoys_20261011T234247JST/README.md)、
[TKT-139](https://app.notion.com/p/Windows-Google-dotfiles-win-3f679149a66f81b1a592d85d7300a62b))。

| ファイル | 中身 |
| --- | --- |
| `config.txtpb` | キー設定・ローマ字テーブルと、時刻・版・OS (`general_config`。Google 日本語入力が保存のたびに入れる) を除いた全項目 (句読点・サジェストなど)。protobuf のテキスト形式 |
| `keymap.tsv` | キー設定。キー設定の画面のエクスポートと同じ形 (MS-IME 風に F13 → IMEOn / IMEOff の行を足してある)。カスタムしていなければ置かない |
| `romaji.tsv` | ローマ字テーブル。カスタムしたときだけ置く (今は無い) |

ユーザー辞書は公開しないので、private な `pollenjp/dotfiles-private` の
`google-japanese-input/dictionaries/<名前>.tsv` (辞書ツールのエクスポートと同じ形) に置く。
`nix/scripts/bootstrap-dotfiles-private.sh` (order 50) が `$(ghq root)/github.com/pollenjp/dotfiles-private`
へ clone / pull する。取れないマシンでは辞書だけ飛ばす。

| 打つもの | すること |
| --- | --- |
| `nix/scripts/bootstrap-windows-google-ime.sh` | 組み立てて配る (`setup --update` でも毎回走る) |
| `nix/scripts/bootstrap-windows-google-ime.sh --dry-run` | 判定だけ見る |
| `nix/scripts/bootstrap-windows-google-ime.sh --dry-run --show-words` | 辞書の衝突でも語の diff を出す。自分の端末で打つ (Claude などのログに残る場所では流さない) |
| `nix/scripts/bootstrap-windows-google-ime.sh --import` | 画面で変えた分を、テキストへ取り込む |
| `nix/scripts/bootstrap-windows-google-ime.sh --force` | 衝突でも repo の中身で置き直す |
| `nix/scripts/bootstrap-windows-google-ime.sh --check` | テキストの検証だけ (CI の lint でも走る。`config.txtpb` が無ければ exit 1) |

- 比べるのは、時刻・版・OS (`general_config`) と辞書の id・並びを外した中身 (`pjp-google-ime digest`)。
  画面で OK を押しただけなら衝突にならない。空のコメントと空の表も「無い」と同じに扱う (単語登録
  ダイアログで足した語は、コメントが空だとコメントの項目を持たず、設定画面はカスタムしていない
  キー設定も空文字で入れるため)
- `verbose_level` が無い設定は、既定の 0 と同じに扱う (比べるときも、テキストにするときも、組み立てる
  ときも 0 で埋める)。設定画面は保存のたびに入れるが、持たない `config1.db` もあった (手で設定してあった
  マシンに初めて配ったとき、差がこれだけで衝突になった)
- 読みか単語が空の語 (辞書ツールで行を足して何も入れずに閉じると残る) は、無いものとして扱う。Mozc は
  変換に使わず、TSV にも書けないため。比べるときに外し、`--import` でも TSV に書かない (前は
  `--import` が「1 列目の読みと2 列目の単語が空」で止まっていた)
- 置いたら `taskkill.exe /F` で変換サーバー (`GoogleIMEJaConverter.exe`) を落とす。次のキー入力で
  起動し直し、置いた設定を読む。変換サーバーは設定を起動時にしか読まず、落とさないまま設定画面で
  OK を押すと、置いた設定が古い設定で上書きされるため
- 落とせなかったら exit 1 にし、落とし直しの印 (`~/.local/state/dotfiles/google-japanese-input/restart-pending`)
  を残す。次の `setup --update` は、置くものが無くても印があれば落とし直し、落とせたら印を消す。
  印がある回の衝突は、古い設定が書き戻されたものかもしれない (repo 側を残すなら `--force`)
- 直接入力モードのキー (F13 → IMEOn など) を変えたときは、アプリを起動し直すと効く
- 設定画面か辞書ツール (`GoogleIMEJaTool.exe`) が開いていると、閉じるよう出して止まる (exit 1)。
  interop が落ちていると置かない (exit 0。落とし直しの印は残る)。`--import` と `--dry-run` は一緒に
  使えない (exit 2)
- Google 日本語入力は入っているが置き先 (`%USERPROFILE%\AppData\LocalLow\Google\Google Japanese Input`) がまだ無い
  (入れただけで一度も使っていない) ときは、一度使ってから流し直すよう出して飛ばす (exit 0)。置き先は Google 日本語入力が
  初めて起動したときに作るので、先に作って置くことはしない (作るときの権限と揃わないおそれがある)。新しいマシンの流れは
  [Google 日本語入力を入れる](#google-日本語入力を入れる-winget)
- 置き換える前のファイルは `~/.local/state/dotfiles/google-japanese-input/backup/<UTC の時刻>-<pid>/` に
  退避する (新しい方から 10 回分)。退避から戻すときは:
  1. 設定画面と辞書ツールを閉じる
  2. 退避したファイルを IME のディレクトリ (`%USERPROFILE%\AppData\LocalLow\Google\Google Japanese Input`。
     WSL からは `/mnt/c/Users/<名前>/AppData/LocalLow/Google/Google Japanese Input`) へ `cp` する
  3. `taskkill.exe /F /IM GoogleIMEJaConverter.exe` で変換サーバーを落とす (次のキー入力で起き直して読む)

  戻すと repo のテキストと違うので、次の `setup --update` は衝突になる (戻した中身を残すなら `--import`)
- 画面で変えたら、次の `setup --update` がこの手順 (order 98) で衝突として止まる。98 より前の bootstrap は
  済んでいるが、後ろの [日付と時刻の形式](#日付と時刻の形式)・[port forwarding の組](#port-forwarding-pf)・[Windows Terminal](#windows-terminal) の手順 (どれも order 99) と wsl-mtu-guard・exe-exec-trace、最後の「残りの手作業」は、解いて流し直すまで走らない。衝突で
  出すのは、設定は diff、辞書は辞書ごとの行の数 (「Windows 側にだけある行 N・repo 側にだけある行 M」
  など) だけで、辞書の語は setup の出力に出さない。語の diff は、自分の端末で `--dry-run --show-words`
- `--import` で取り込み、最後の行に出た repo (テキストが変わった側。dotfiles・dotfiles-private・両方) で `git diff` を見て commit する (dotfiles-private の diff には辞書の語が出るので、自分の端末で見る)。どちらも変わらなければ「取り込みの分で commit するものはありません」と出る
  - `--import` は repo のテキストを Windows 側の中身で置き換える (diff の + の行は消える)。両方を
    残すなら、テキストを手で直してから `--force`
  - repo 側 (`win/google-japanese-input/` の `config.txtpb`・`keymap.tsv`・`romaji.tsv` と dotfiles-private の辞書) に
    commit していない変更 (未追跡のファイルも) があると、変わったファイル名を出して何も書かずに止まる (exit 1)。
    先に commit するか、戻してから流し直す。git の checkout か確かめられないときも止まる。同じディレクトリの
    `Install-GoogleJapaneseInput.ps1` の変更では止まらない (版を上げる途中でも取り込めるように)
  - Windows 側に `user_dictionary.db` が無ければ、辞書は取り込まない (TSV はそのまま)
- テキストは画面のエクスポートと同じ形なので、仕組みが動かないときも、GUI の「インポート」で手で戻せる

### Google 日本語入力を入れる (winget)

Google 日本語入力は winget の `Google.JapaneseIME` (machine スコープの MSI。入れる・上げるときは Windows のデスクトップに
UAC の確認が出る) で入れ、版を `google-japanese-input/Install-GoogleJapaneseInput.ps1` の `-Version` の既定値の
1 か所で固定する。設定 (`config.txtpb`) を読み書きできると確かめた版に留めるため
([ADR 017](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/017_win_apps_winget_20261012T115007JST/README.md)、[TKT-143](https://app.notion.com/p/winget-Windows-Google-PowerToys-Google-dotfiles-3f779149a66f817a8944c9e4e460383f))。

| 打つもの | すること |
| --- | --- |
| `Install-GoogleJapaneseInput -Check` (PowerShell) | 差を出すだけ。揃っていれば終了コード 0、差があれば 1、入っていなければ 3 |
| `Install-GoogleJapaneseInput` (PowerShell) | 揃える (入れる・上げる・pin を足す)。入れる・上げるときは UAC の確認が出る |
| `nix/scripts/bootstrap-windows-google-ime-install.sh` (WSL) | `setup --update` でも毎回走る (order 95)。入っていなければ入れ (UAC の確認が出る)、差があれば ⚠ で囲んで知らせる (上げはしない) |
| `nix/scripts/bootstrap-windows-google-ime-install.sh --apply` (WSL) | WSL から揃える。UAC の確認は Windows のデスクトップに出る |
| `nix/scripts/check-winget-version.sh google-japanese-input` (WSL・CI) | 固定した版を winget の版の一覧と比べる。GitHub Actions の `winget-versions` が週 1 回流し、新しい版が winget に載って 30 日たつと落ちて知らせる ([後述](#google-日本語入力の新しい版が出たとき)) |

- 版は `GoogleIMEJaConverter.exe` の ProductVersion で読む。`C:\Program Files\` と `C:\Program Files (x86)\` の
  `Google\Google Japanese Input\` の両方を見る (版によって、入る先が違うため)
- 上げるのは setup からはしない。日本語入力は全部のアプリに読み込まれていて、入れ替えるとアプリや Windows の
  再起動が要ることがあるため。上げる前に、日本語入力を使っているアプリをできるだけ閉じる。上げた後も `-Check` が
  古い版を出すなら、Windows を再起動してからもう一度 `-Check` で確かめる
- 入れた後と上げた後に `winget pin add` で `winget upgrade --all` から外す (上げるときは先に pin を外し、上げた後に足し直す。上げる
  upgrade には `--include-pinned` も付け、外せなかったときも pin に止められない。[winget の pin](#winget-の-pin))
- 入っている版の方が新しい (Google 日本語入力が自分で上がった) ときは下げない。`-Check` と setup が ⚠ で知らせ続けるので、
  下の「版を上げる」で repo の版を追いつかせる
- 入っていなくても、固定した版が winget に無い (`-Version` の書き間違いか、winget から消えた) ときは、setup は入れにいかず
  (UAC も出さず)、repo の版 (`-Version` の既定値) の直し方を出す
- 入っている版が読めないときと、固定した版が winget に無いときは、揃えるコマンドを打っても直らないので、
  その代わりにそれぞれの直し方 (入っている版の確かめ方・repo の版の直し方) を出す
- setup が待つ上限は、`-Check` が 120 秒、入れる `-IfMissing` が 600 秒。時間切れになったらそう出して先へ進む (setup は止めない)。
  入れるときに UAC の確認を押さないまま 600 秒たった場合は、⚠ で囲んで、手で打つコマンドも出す

新しいマシンでは、98 の置き先がまだ無ければ setup を 2 回流す (置き先は、Google 日本語入力が初めて起動したときにできる。
固定した版の MSI は入れる途中で作る見込みで、そのときは 1 回で済む。ADR 017 §1 の 8):

1. `~/dotfiles/setup --update` を流す。UAC の確認が出たら「はい」を押す
2. `bootstrap-windows-google-ime.sh` が「まだ使われていません」と出したら、Google 日本語入力で一度何か打つ
   (入力方式が別なら切り替えてから)
3. 2 で打ったら、もう一度 `~/dotfiles/setup --update` を流す。`bootstrap-windows-google-ime.sh` が設定と辞書を置く

PowerToys の割り当ては、これとは別に、91 が Keyboard Manager と自動起動をオンにして PowerToys を起動し直す
([Keyboard Manager と自動起動をオンにする](#keyboard-manager-と自動起動をオンにする))。Keyboard Manager の設定 (`settings.json`) が
まだ無いと出たら、設定画面を一度開いてから 91 を流し直すと効く ([PowerToys を入れる](#powertoys-を入れる-winget))。

新しいマシンで通しては、まだ確かめていない (ADR 017 §6)。98 が衝突を出したら (初回の起動で `config1.db` ができていると、
置いた記録が無いので衝突になる)、`--import` (Windows 側を残す。[Google 日本語入力](#google-日本語入力)) か
`--force` (repo 側で置き直す) を選ぶ

版を上げる:

1. `Install-GoogleJapaneseInput.ps1` の `-Version` の既定値を、`winget show --id Google.JapaneseIME --versions` にある新しい版にする
2. `nix/scripts/bootstrap-windows-files.sh` を流して、書き換えた `Install-GoogleJapaneseInput.ps1` を Windows へ配る
   (commit していなくても、作業ツリーのものが配られる。PowerShell の `Install-GoogleJapaneseInput` は配った方を呼ぶので、
   配るまでは古い `-Version` のまま動く)
3. この PC で `Install-GoogleJapaneseInput` を打って揃え、`nix/scripts/bootstrap-windows-google-ime.sh --dry-run` と
   `--import` で設定を読み書きできるかを見る (`--import` は `Install-GoogleJapaneseInput.ps1` の変更では止まらない)
4. `--import` が「今の .proto に無い項目がある」で止まったら、`nix/pkgs/pjp-google-ime/proto/` の写しを新しくする
   ([pjp-google-ime](#pjp-google-ime))
5. commit して `~/dotfiles/setup --update` を流し、`bootstrap-windows-google-ime-install.sh` が「揃っています」の 1 行
   (winget にもっと新しい版があれば ※ の補足も) で終わることを見る

### Google 日本語入力の新しい版が出たとき

固定した版より新しい版が winget に載って 30 日たつと、GitHub Actions の `winget-versions` の
`Google 日本語入力` の job が落ちて知らせる ([TKT-156](https://app.notion.com/p/herdr-Google-windows-openssh-1-3fa79149a66f81ee8d2bd07a0769cab0))。
猶予・落ちる場合・見送りの一覧は [winget の新しい版を確かめる](#winget-の新しい版を確かめる)。

- GitHub の release が無いので、出た日は、その版のディレクトリを winget-pkgs に足した commit の日から取る
  (manifest の `ReleaseDate` は版によって無い)。上流で出てから winget に載るまでは数日 (3.34.6260.0 は 3 日)
- 落ちた実行の summary には、新しい版の manifest (winget-pkgs のディレクトリ) の URL が出る
- 比べる相手が無いので、パッケージ ID が移って winget に新しい版が来なくなっても気付けない

上げるとき: 上の「版を上げる」の 1〜5。commit を PR にすると、`winget-versions` が、書いた版が winget にあるかを確かめる

見送るとき (3・4 で設定を読み書きできないと分かったとき):

- `google-japanese-input/skipped-versions.txt` に「版 理由」を 1 行足し、`-Version` の既定値を前の版に戻して commit する
- 3 で上げたこの PC は、`Install-GoogleJapaneseInput` が下げないので、`-Check` が「入っている版の方が新しい」と
  ⚠ を出し続ける
- `-Check` の ※ の行は見送っても出続ける (winget に新しい版があるのは事実なので)

### Install-GoogleJapaneseInput.ps1 を書くときの注意

- `dotfiles.ps1` と同じく **BOM 付きの UTF-8** で保存する
- 副作用の無い関数 (版の読み方・探す場所・plan・winget の引数・状態の表・流れ) は
  `google-japanese-input/Install-GoogleJapaneseInput.Tests.ps1` で確かめる。Linux の pwsh で流すので Windows には触らない
  (このファイルは manifest に無いので配られない):

  ```sh
  nix shell nixpkgs#powershell -c pwsh -NoProfile -File win/google-japanese-input/Install-GoogleJapaneseInput.Tests.ps1
  ```

- winget の引数 (`Get-WingetCommands`) の upgrade には `--include-pinned` を付け、install には付けない ([winget の pin](#winget-の-pin)。
  試験の偽の winget も、付けない upgrade を pin で止める)
- winget やファイルに触る部分は、実機で `-Check` と本番を打って確かめる

### pjp-google-ime

テキストとバイナリを行き来させる CLI (`nix/pkgs/pjp-google-ime/`)。`windowsFiles.enable` のマシンでは
home-manager が PATH に入れる。Windows には触らない。

```sh
pjp-google-ime check --config-dir win/google-japanese-input     # 検証だけ
pjp-google-ime decode --kind config <config1.db> --out <dir>    # バイナリをテキストに戻す
pjp-google-ime digest --kind config <config1.db>                # 比べるための sha256
```

- Mozc の `.proto` の写しは `nix/pkgs/pjp-google-ime/proto/` にある (写した commit と、新しくする手順は
  そこの README)。新しい版の Google 日本語入力が項目を足すと、`--import` が止まって知らせる
- 辞書の TSV のエラーは、ファイル・行・列の数・どの列が悪いかまでを出し、読み・単語・品詞・コメントの
  中身は出さない (列がずれると品詞の列に語が入るので、品詞の値も出さない)
- テストは `nix build ./nix#checks.x86_64-linux.pjp-google-ime-unittest`

## Windows Terminal

`windows-terminal/managed.json` は、Windows Terminal の `settings.json` のうち、dotfiles が持つキーだけを書いたもの。
`manifest.toml` では配らず、`nix/scripts/bootstrap-windows-terminal.sh` (order 99) が `setup --update` のたびに、
そのキーだけを Store 版の `settings.json`
(`%LOCALAPPDATA%\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json`) へ書き足す
(経緯は [ADR 018](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/018_win_terminal_settings_keys_20261016T105116JST/README.md)、[TKT-167](https://app.notion.com/p/Windows-Terminal-settings-json-dotfiles-bell-3fb79149a66f81e6a695c581b5ab5cef))。

`settings.json` をファイルごと配らないのは、Windows Terminal 自身も書き換えるから (新しい WSL の distro などの
profile を見つけたとき・設定画面で保存したとき)。PC ごとに違う profile の一覧も入っている (WSL の profile の
GUID は、distro を登録したときの ID から作られる)。

| キー | 値 | 何のため |
| --- | --- | --- |
| `profiles.defaults.bellSound` | `["C:\\Windows\\Media\\Windows Information Bar.wav"]` (1 要素の配列) | BEL で鳴る音を、既定のエラー音 (SystemHand。この PC では `Windows Foreground.wav` で 2.1 秒) から 0.1 秒の短い音に替える。`bellStyle` は既定の `audible` のまま |

`bellSound` を配列で持つのは、Windows Terminal が保存するときの形に揃えるため。Windows Terminal は読むときは文字列も
配列も受けるが、`settings.json` を保存するときは、音が 1 つでも配列で書く。script は値を形も含めて比べる (文字列と
1 要素の配列は別の値) ので、文字列で持つと、音が同じでも Windows Terminal の次の保存の後で衝突して止まる。

| 打つもの | すること |
| --- | --- |
| `nix/scripts/bootstrap-windows-terminal.sh` | 書き足す (`setup --update` でも毎回走る) |
| `nix/scripts/bootstrap-windows-terminal.sh --dry-run` | 判定だけ見る |
| `nix/scripts/bootstrap-windows-terminal.sh --import` | 設定画面で変えた値を `managed.json` へ取り込む ([衝突したら](#windows-terminal-の設定が衝突したら)) |
| `nix/scripts/bootstrap-windows-terminal.sh --force` | 衝突でも `managed.json` の値で書く |
| `nix/scripts/bootstrap-windows-terminal.sh --check` | `managed.json` の検証だけ (CI の lint でも走る) |

- 書くのは `managed.json` に書いたキーだけで、ほかのキーには触らない。`profiles.defaults` に書けば全 profile に効く
- `managed.json` は `settings.json` と同じ形で書く。object を辿った先の、object でない値 1 つが、持つキー 1 つ。
  配列 (`actions`・`keybindings` など) は中を見ず、丸ごと 1 つの値として持つ
- 値は Windows Terminal が保存するときの形で書く (`bellSound` の配列など)。形が違うと、次の保存の後で衝突する
- `profiles.list` (profile の一覧) は持てない (`--check` が落ちる)。PC ごとに違うため
- 形は `jq --indent 4` の出力に揃える。`--import` が書き直したときの差分を、値の変更だけにするため (`--check` が見る)
- Windows Terminal は `settings.json` を見張っていて、書いたらその場で読み直す
- 書く前の `settings.json` は `~/.local/state/dotfiles/windows-terminal/backup/<UTC の時刻>-<pid>/` に退避する
  (新しい方から 10 回分)。書くと字下げなどの形が jq のものに変わるが、Windows Terminal は気にせず読む
- 書いた値は `~/.local/state/dotfiles/windows-terminal.applied.json` に覚える。`managed.json` から消したキーは、
  `settings.json` からは消さない (記録からだけ消す)
- `settings.json` がまだ無い (Windows Terminal を一度も起動していない) ときと、JSON として読めない (手で書いた
  コメントや末尾のカンマがある) ときは、⚠ で知らせて書かずに進む
- 見るのは Store 版だけ。Preview (`Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe`) と zip 版は見ない

### 音のファイルは repo に入れない

`bellSound` には、Windows に入っている音のパス (`C:\Windows\Media\…`) を書く。wav などのファイルそのものは
commit しない。この repo は public で、Windows に付いてくる音は Microsoft の著作物なので、ファイルを置くと配布に
なる。パスを書くだけなら、各 PC の Windows に入っている音をその PC で鳴らすだけで済む。

- パスのファイルが無い PC では、その音は鳴らない
- 候補は WSL から鳴らして聞き比べられる:

  ```sh
  powershell.exe -NoProfile -Command '(New-Object Media.SoundPlayer "C:\Windows\Media\Windows Information Bar.wav").PlaySync()'
  ```

### Windows Terminal の設定が衝突したら

`managed.json` が持つキーを設定画面で変えていた (か、既定に戻していた) と、触らずに両方の値を出して止まる。
書いた記録が無いのに違う値が先にある (初めて書くマシンで、手で設定してあった) ときも同じで、「書いた記録が無く」と
出る。`setup --update` はこの手順 (order 99) で止まり、後ろの wsl-mtu-guard・exe-exec-trace と最後の「残りの手作業」は、
解いて流し直すまで走らない。衝突しないキーは書いてある。どちらかで解く。

1. Windows 側の値を残す: `--import` で `managed.json` へ取り込み、`git diff` を見て commit して push する。
   `managed.json` に commit していない変更があると、取り込みは何も書かずに止まる
2. `managed.json` の値で書く: `--force`。元の `settings.json` は退避される

```sh
~/ghq/github.com/pollenjp/dotfiles/nix/scripts/bootstrap-windows-terminal.sh --import
~/ghq/github.com/pollenjp/dotfiles/nix/scripts/bootstrap-windows-terminal.sh --force
```

中身が同じで形だけが違う (`"…"` と `["…"]` など) ときは、Windows Terminal が保存するときの形の方を残す。Windows 側が
その形なら 1、`managed.json` がその形なら 2 で解く。逆にすると、次の保存でまた衝突する。

`settings.json` の `profiles` が配列の古い形のときは、`profiles.defaults` へ書けないので ⚠ で知らせて止まる。
設定画面で何か 1 つ変えて保存すると、Windows Terminal が object の形 (`defaults` と `list`) で書き直す。

### キーを足す

1. Windows Terminal の設定画面で値を決めて保存する (その場で効く)
2. `settings.json` の同じ場所の値を、同じ形で `managed.json` に写す。`settings.json` を手で書いた値は、Windows Terminal が
   次に保存するまで手で書いた形のままなので、設定画面で保存した後の形を写す
3. `nix/scripts/bootstrap-windows-terminal.sh --check` で検証し、`--dry-run` で「揃っています」と出るのを見る
   (設定画面で入れた値と同じなので、記録だけが作られる)
4. commit して `~/dotfiles/setup --update`

## 日付と時刻の形式

`international/managed.json` は、Windows の日付と時刻の形式 (設定の「時刻と言語」→「言語と地域」の地域設定の形式) のうち、
dotfiles が持つ値だけを書いたもの。キーはユーザーごとのレジストリ `HKCU\Control Panel\International` の値の名前。
`manifest.toml` では配らず、`nix/scripts/bootstrap-windows-international.sh` (order 99) が `setup --update` のたびに、`pwsh.exe` で
SetLocaleInfoW を呼んで書き、WM_SETTINGCHANGE (`"intl"`) を送る
([設計](https://github.com/pollenjp/dotfiles-private/blob/main/docs/superpowers/specs/2026-11-07-windows-international-format-design.md))。

| 名前 | 値 | 形式 | 出る形 |
| --- | --- | --- | --- |
| `sShortDate` | `yyyy-MM-dd` | 短い日付 | `2026-11-07` (タスクバーの時計の日付・エクスプローラーの更新日時) |
| `sTimeFormat` | `HH:mm:ss` | 長い時刻 | `09:40:05`・`14:40:05` |
| `sShortTime` | `HH:mm` | 短い時刻 | `09:40`・`14:40` (タスクバーの時計・エクスプローラーの更新日時) |

- 地域 (en-US など) そのものと、持たない値 (長い日付・通貨・小数点・週の始まりなど) は変えない
- レジストリを直には書かない。Microsoft の文書のとおり SetLocaleInfoW で書き、WM_SETTINGCHANGE を送る。開いているアプリ
  (タスクバーの時計など) はその場で読み直し、サインアウトは要らない (2026-11-07 に en-US の PC で、書いた直後にタスクバーの
  時計が `10:06 PM` / `11/7/2026` から `22:06` / `2026-11-07` になった)
- 古いアプリ向けの付随の値 (`sDate`・`iDate`・`iTime`・`iTLZero`) は、SetLocaleInfoW が形式に合わせて書き直す
  (`-`・`2`・`1`・`1`。この 3 つの形式を既定に持つ sv-SE の既定と同じ)。dotfiles では持たない
- 形式の書き方は Microsoft の文書の [日付](https://learn.microsoft.com/en-us/windows/win32/intl/day--month--year--and-era-format-pictures)・
  [時刻](https://learn.microsoft.com/en-us/windows/win32/intl/hour--minute--and-second-format-pictures) の format picture。
  形は `jq --indent 4` の出力に揃える (`--import` が書き直したときの差分を値だけにするため。`--check` が見る)

| 打つもの | すること |
| --- | --- |
| `nix/scripts/bootstrap-windows-international.sh` | 書く (`setup --update` でも毎回走る) |
| `nix/scripts/bootstrap-windows-international.sh --dry-run` | 判定だけ見る (Windows の値は読む) |
| `nix/scripts/bootstrap-windows-international.sh --import` | 設定画面で変えた値を `managed.json` へ取り込む ([衝突したら](#日付と時刻の形式が衝突したら)) |
| `nix/scripts/bootstrap-windows-international.sh --force` | 衝突でも `managed.json` の値で書く |
| `nix/scripts/bootstrap-windows-international.sh --check` | `managed.json` の検証だけ (CI の lint でも走る) |

値ごとに、Windows の今の値を `managed.json`・前回書いた値 (`~/.local/state/dotfiles/windows-international.applied.json`)・
地域の既定と比べる。Windows Terminal の判定に「記録が無く、地域の既定のまま」の行を足したもので、初めて書くマシンでも
手で変えていなければ止まらない。

| Windows の今の値 | すること |
| --- | --- |
| `managed.json` と同じ | 何もしない (記録が無ければ記録だけする) |
| 前回書いた値と同じ | 書く (`managed.json` を変えた) |
| 記録が無く、地域の既定と同じ | 書く (初めて書くマシンで、手で変えていない) |
| それ以外 | 衝突。書かずに止まる ([衝突したら](#日付と時刻の形式が衝突したら)) |

- 書くときは、衝突でない値を全部、表の順 (`sShortDate`・`sTimeFormat`・`sShortTime`) に書き直してから読み戻して比べる。書けない・
  読み戻すと違う値は ⚠ で知らせて止まる (exit 1)。記録は書けた値だけ
- グループポリシーで止められている値 (Win32 のエラー 1260) は、流し直しても書けず dotfiles では直せないので、⚠ で知らせて
  飛ばす (setup は止めない。毎回同じ警告が出る)
- `managed.json` から消した値は、Windows では戻さない (記録からだけ消す)
- `pwsh.exe` が無い・WSL の interop が落ちていて読めないときは、⚠ で知らせて書かずに進む

### 日付と時刻の形式が衝突したら

`managed.json` が持つ値を設定画面で変えていた (か、地域を変えて新しい地域の既定に戻った) と、触らずに Windows 側・
`managed.json`・前回書いた値・地域の既定を出して止まる。書いた記録が無いのに、地域の既定とも違う値が先にある (初めて書く
マシンで、手で設定してあった) ときも同じで、「書いた記録が無く」と出る。`setup --update` はこの手順 (order 99) で止まり、
後ろの [port forwarding の組](#port-forwarding-pf)・[Windows Terminal](#windows-terminal) の手順・wsl-mtu-guard・exe-exec-trace と最後の
「残りの手作業」は、解いて流し直すまで走らない。衝突しない値は書いてある。どちらかで解く。

1. Windows 側の値を残す: `--import` で `managed.json` へ取り込み、`git diff` を見て commit して push する。
   `managed.json` に commit していない変更があると、取り込みは何も書かずに止まる
2. `managed.json` の値で書く: `--force`

```sh
~/ghq/github.com/pollenjp/dotfiles/nix/scripts/bootstrap-windows-international.sh --import
~/ghq/github.com/pollenjp/dotfiles/nix/scripts/bootstrap-windows-international.sh --force
```

### 形式の値を足す

持てる名前は script の表 (`table`) にあるものだけ (今は上の 3 つ)。長い日付 (`sLongDate`) などを持つときは:

1. `nix/scripts/bootstrap-windows-international.sh` の `table` に、名前と LCType (winnls.h の `LOCALE_*` の値) を 1 行足す。
   書く順も表の順
2. `managed.json` に同じ名前で値を書き、`--check` で検証して `--dry-run` で判定を見る
3. commit して `~/dotfiles/setup --update`

## type-clipboard

`type-clipboard/Install-TypeClipboard.ps1` は、自作の Windows のアプリ type-clipboard
([pollenjp/type-clipboard](https://github.com/pollenjp/type-clipboard)) を、GitHub の Release から固定した版で入れる。
type-clipboard はクリップボードの文字を、選んだ窓へキー入力として 1 文字ずつ打ち込む (Hyper-V の VMConnect や RDP の
サインイン画面など、貼り付けが効かない所にパスワードを入れるため)。単一の exe で、インストーラも署名も無く、winget にも無い。

- setup が入れるのは `dotfiles.wsl.windowsFiles.typeClipboard.enable = true` のマシンだけ (既定は false)。値は dotfiles-private に
  登録したホストのファイルか、`~/dotfiles/flake.nix` に足したホストの `wsl` に書く:

  ```nix
  wsl = {
    windowsFiles.enable = true;
    windowsFiles.typeClipboard.enable = true;
  };
  ```

- `Install-TypeClipboard.ps1` 自体は win/ を配るマシンのどれにも配る (manifest)。false のマシンでも、PowerShell で
  `Install-TypeClipboard` を打てば入る (setup が見ないだけ)
- 置き場所は `%LOCALAPPDATA%\Programs\type-clipboard\type-clipboard.exe`。スタートメニューの `type-clipboard`
  (`%APPDATA%\Microsoft\Windows\Start Menu\Programs\type-clipboard.lnk`) から起こす。設定は type-clipboard が自分で
  `%APPDATA%\type-clipboard\settings.ini` に置き、dotfiles は触らない
- 版は `Install-TypeClipboard.ps1` の `-Version` の既定値 (今は `0.2.1`) の 1 か所で、その版の exe の SHA-256 は同じファイルの
  表 (`Get-TypeClipboardReleases`) で固定する。表の値は Release に置いた `type-clipboard.exe.sha256` の中身と同じ
- 自作のアプリの Release なので、依存の公開からの猶予 (7 日) は置かない。猶予は第三者のパッケージの汚染版を、気付かれて
  取り下げられるまで掴まないためのもので、自分の CI が作る Release には当たらない。中身は SHA-256 で固定する

| 打つもの | すること |
| --- | --- |
| `Install-TypeClipboard -Check` (PowerShell) | 差を出すだけ (ネットワークも使わない)。揃っていれば終了コード 0、差があれば 1、入っていなければ 3 |
| `Install-TypeClipboard` (PowerShell) | 揃える (入れる・入れ替える・ショートカットを作る) |
| `nix/scripts/bootstrap-windows-type-clipboard.sh` (WSL) | `setup --update` でも毎回走る (order 97)。true のマシンだけ、入っていなければ入れ、差があれば ⚠ で囲んで知らせる (入れ替えはしない) |
| `nix/scripts/bootstrap-windows-type-clipboard.sh --apply` (WSL) | WSL から揃える |

揃えるときにすること:

1. 置き場所の exe の SHA-256 を表と突き合わせ、入っている版を決める (exe は版の情報を持たないので、表に無い SHA-256 は
   「不明」)。固定した版でなければ、固定した版の `type-clipboard.exe` を Release
   (`https://github.com/pollenjp/type-clipboard/releases/download/v<版>/type-clipboard.exe`) から置き場所の中に別の名前で落とす
2. 落とした物の SHA-256 が表の値と合うときだけ、置き場所の exe と入れ替える。合わない・落とせないときは、落とした物を消して
   何も変えずに止まる (入っている版はそのまま)。入れ替えは、PowerShell 7 では 1 回の rename (置き先が動いている exe なら何も
   変えずに落ちる)。Windows PowerShell 5.1 では古い exe を消してから名前を変えるので、その間で落ちると exe が消える (そう出る。
   打ち直せば入る)
3. スタートメニューのショートカットが無い・ほかを指していれば作り直す
4. 読み直して、版とショートカットを確かめる

- 入れ替えが要るときに置き場所の type-clipboard.exe が動いていると、何も変えずに止まって PID を出す (管理者として動いていて
  パスが読めないものも、置き場所のものかもしれないので数える)。スクリプトは type-clipboard を止めない (打っている途中かも
  しれない)。窓を閉じてから打ち直す
- 止められた実行 (setup の時間切れなど) が置き場所に残した途中の物 (`type-clipboard.exe.download-<PID>`) は、次に入れるときに
  10 分より古ければ消す
- Invoke-WebRequest で落とすので、置いた exe に Mark of the Web (`Zone.Identifier`) は付かず、起こしても SmartScreen の警告は
  出ない (中身は SHA-256 で確かめてある)
- PowerShell 7 でも Windows PowerShell 5.1 でも動く。SHA-256 は .NET で出す (PowerShell 7 から起こした 5.1 は PSModulePath を
  継ぎ、`Get-FileHash` が見つからないことがある)
- 入れるのをやめる (option を false に戻す) ときも、setup は消さない。消すなら type-clipboard を閉じて、
  `%LOCALAPPDATA%\Programs\type-clipboard` とスタートメニューの `type-clipboard.lnk` を消す (設定の `%APPDATA%\type-clipboard` も
  要らなければ消す)

### type-clipboard の新しい版を出したとき

dotfiles が入れる版は自動では上がらない (setup は差を知らせるだけ)。type-clipboard の repo で新しい版の Release を出したら:

1. Release の `type-clipboard.exe` を落とし、SHA-256 を自分でも出して `type-clipboard.exe.sha256` と同じかを確かめる
   (`sha256sum type-clipboard.exe`)
2. `type-clipboard/Install-TypeClipboard.ps1` の表 (`Get-TypeClipboardReleases`) に「版 = SHA-256」の行を足し (古い版の行は、
   入っている版を名前で出すために残す)、`-Version` の既定値と、上の「今は」を新しい版にする
3. `Install-TypeClipboard.Tests.ps1` を流して PR を出す
4. merge したら、入れるマシンで `setup --update` を流す (差が ⚠ で出る)。type-clipboard の窓を閉じてから、
   `Install-TypeClipboard` か `bootstrap-windows-type-clipboard.sh --apply` で揃える

### Install-TypeClipboard.ps1 を書くときの注意

- `dotfiles.ps1` と同じく **BOM 付きの UTF-8** で保存する
- 副作用の無い関数 (表・版の決め方・plan・状態の表) と、落とす・ショートカット・プロセスを偽物に差し替えた流れ (SHA-256 が
  合わないと置かない・動いていると止まる・落とした物を残さない) は、`type-clipboard/Install-TypeClipboard.Tests.ps1` で確かめる。
  Linux の pwsh で流すので Windows には触らない (このファイルは manifest に無いので配られない):

  ```sh
  nix shell nixpkgs#powershell -c pwsh -NoProfile -File win/type-clipboard/Install-TypeClipboard.Tests.ps1
  ```

- 落とす・ショートカット (WScript.Shell の COM)・動いているかを見る本物の部分は、実機で置き場所を一時ディレクトリに向けて
  確かめる (本物の置き場所とスタートメニューには触らない):

  ```powershell
  $t = Join-Path $env:TEMP 'type-clipboard-try'
  & "$HOME\.config\powershell\Install-TypeClipboard.ps1" -InstallDir "$t\Programs\type-clipboard" -ShortcutDir "$t\StartMenu" -Check
  & "$HOME\.config\powershell\Install-TypeClipboard.ps1" -InstallDir "$t\Programs\type-clipboard" -ShortcutDir "$t\StartMenu"
  Remove-Item -Recurse -Force $t
  ```

## op-reason

`op-reason/Install-OpReason.ps1` は、WSL の op (自作の OSS の op-reason ([pollenjp/op-reason](https://github.com/pollenjp/op-reason))。
1Password CLI の wrapper) の Windows の部品 `op-reason-windows.zip` を、GitHub の Release から固定した版で入れる。WSL の op
([`nix/README.md`「WSL の op を理由つきで呼ぶ (1Password CLI)」](../nix/README.md#wsl-の-op-を理由つきで呼ぶ-1password-cli)) は、
呼び出しごとに Windows の `op-reason.exe` (動かないときは隣の `launcher.ps1`) を起こして承認の窓を出す。zip の中身は
`op-reason.exe`・`launcher.ps1`・`powershell-entry\`・`SKILL.md`・README・ライセンスで、WSL の実行ファイルと同じ版にそろえる
(呼び出しの取り決め (payload の版) が変わった版どうしでは断られる。0.1.0 と 0.2.0 は同じ取り決め)。

- setup が入れて揃えるのは、WSL の op の wrapper を入れるマシン (`dotfiles.wsl.enable` と `dotfiles.onePassword.enable` が両方 true。
  home-manager が書く `~/.local/state/dotfiles/claude-op-reason.json` の `enable`) のうち、win/ を配るマシン。option は無い。
  win/ を配らないマシンでは setup がそう 1 行出すので、op-reason の README の「Windows で」の手順で手で入れる (置き場所を下の
  既定にすれば、WSL の op の既定の `OPREASON_EXE` のまま使える)
- Windows 側の runner にはまだ無い ([runner の手順](#runner-の手順)の `op-reason`)。受け持ちを runner に切り替えたホストでは setup も
  runner も揃えないので、`Install-OpReason` を手で流す
- 置き場所は `%LOCALAPPDATA%\Programs\op-reason`。WSL の op は、ここの `op-reason.exe` を `OPREASON_EXE`
  (`/mnt/c/Users/<windowsUserName>/AppData/Local/Programs/op-reason/op-reason.exe`。`home/modules/op-reason.nix` が包みに入れる既定)
  で見つけ、`launcher.ps1` はその隣から探す。Windows の PATH には足さない (WSL が Windows の PATH を読み直す `wsl --shutdown` も
  待たずに済む)
- 版は `Install-OpReason.ps1` の `-Version` の既定値 (今は `0.2.0`) の 1 か所で、その版の zip の SHA-256 (`Zip`) と、展開した
  中身の値 (`Tree`) を同じファイルの表 (`Get-OpReasonReleases`) で固定する。`Zip` は Release に置いた `op-reason-windows.zip.sha256`
  の中身と同じ。WSL の実行ファイルの版 (`nix/pkgs/op-reason/default.nix` の `version`) と同じにする (テストが突き合わせる)
- 自作のアプリの Release なので、type-clipboard と同じく依存の公開からの猶予 (7 日) は置かない。中身は SHA-256 で固定する
- WSL の実行ファイルは switch で上がるので、Windows の部品も setup のたびに揃える (type-clipboard と違い、版がずれていれば
  入れ替えまでする)。`op-reason.exe` は op の呼び出しの間しか動かない
- `op-reason.exe` には署名が無い。Smart App Control に止められると、WSL からの呼び出しはひとりでに `launcher.ps1` に回り、
  そのたびに stderr に 1 行出る (止められる間は、窓が launcher の窓になる)。毎回の試しをやめるなら、そのホストの WSL の環境に
  `OPREASON_RUNNER=launcher` を置く (nix/README.md)。`Install-OpReason.ps1` は exe を起こさないので、止められても入れて揃えられる
- Windows から直に呼ぶ (Windows の Claude Code など) ときは、op-reason の README の「Windows で」のとおり置き場所を Windows の
  PATH に足す。Smart App Control に止められるマシンでは、`<置き場所>\powershell-entry` を置き場所より前に足す。dotfiles はどちらも
  足さない

| 打つもの | すること |
| --- | --- |
| `Install-OpReason -Check` (PowerShell) | 差を出すだけ (ネットワークも使わない)。揃っていれば終了コード 0、差があれば 1、入っていなければ 3 |
| `Install-OpReason` (PowerShell) | 揃える (入れる・入れ替える) |
| `nix/scripts/bootstrap-windows-op-reason.sh` (WSL) | `setup --update` でも毎回走る (order 97)。WSL の op を入れて win/ を配るマシンだけ、入っていなければ入れ、差があれば入れ替える。揃えられなければ ⚠ で囲んで知らせる |
| `nix/scripts/bootstrap-windows-op-reason.sh --apply` (WSL) | WSL から揃える (確かめずに流す) |

揃えるときにすること:

1. 置き場所の中身の値 (`Tree`) を表と突き合わせ、入っている版を決める (中の全部のファイルの SHA-256 と相対パスから作る値。表に無い
   値は「不明」)。`op-reason.exe --version` は聞かない (署名が無く止められうる)
2. 固定した版でなければ、Release (`https://github.com/pollenjp/op-reason/releases/download/v<版>/op-reason-windows.zip`) から置き場所の
   隣 (`op-reason.download-<PID>.zip`) に落とし、SHA-256 が表の `Zip` と合うときだけ隣 (`op-reason.new-<PID>`) に展開する。展開した
   `op-reason-windows` の中身の値が表の `Tree` と合えば、前の置き場所を `op-reason.old-<PID>` によけ、展開した物を置き場所の名前に
   して、よけた物を消す。合わない・落とせない・展開できないときは、落とした物と展開した物を消して何も変えずに止まる。展開した物を
   置けなければ、よけた物を元に戻す (戻せなければ、`op-reason.old-<PID>` に残したことを出す)
3. 読み直して、版を確かめる

- 入れ替えが要るときに置き場所の `op-reason.exe` が動いている (op の呼び出しの途中) と、何も変えずに止まって PID を出す (管理者
  として動いていてパスが読めないものも数える)。呼び出しが終わってから打ち直す。スクリプトは止めない (承認を待っている途中かも
  しれない)
- 止められた実行 (setup の時間切れなど) が隣に残した途中の物 (`op-reason.download-*`・`op-reason.new-*`・`op-reason.old-*`) は、
  次に入れるときに 10 分より古ければ消す
- Invoke-WebRequest で落とすので、展開した物に Mark of the Web (`Zone.Identifier`) は付かない。`powershell-entry` の `.ps1` も
  `Unblock-File` せずに RemoteSigned で動く (中身は SHA-256 で確かめてある)
- 記録 (`%LOCALAPPDATA%\op-reason\log.jsonl`) は op-reason が置く別の場所で、触らない
- PowerShell 7 でも Windows PowerShell 5.1 でも動く。SHA-256 と展開は .NET で行う (PowerShell 7 から起こした 5.1 は PSModulePath を
  継ぎ、`Get-FileHash`・`Expand-Archive` が見つからないことがある)
- 入れるのをやめる (WSL の op を入れないマシンにする) ときも、setup は消さない。消すなら op の呼び出しが無いときに
  `%LOCALAPPDATA%\Programs\op-reason` を消す (記録の `%LOCALAPPDATA%\op-reason` も要らなければ消す)

### op-reason の新しい版を出したとき

dotfiles が入れる版は自動では上がらない (依存の更新も見ない)。op-reason の repo で新しい版の Release を出したら、WSL の実行ファイルと
同じ PR で上げる:

1. Release の `op-reason-windows.zip` を落とし、SHA-256 を自分でも出して `op-reason-windows.zip.sha256` と同じかを確かめる
   (`sha256sum op-reason-windows.zip`)
2. zip を展開し、`op-reason-windows` の中身の値を出す (`Get-OpReasonTreeHash` と同じ値):

   ```sh
   cd op-reason-windows && find . -type f | sed 's|^\./||' | LC_ALL=C sort | while IFS= read -r f; do sha256sum -- "$f"; done | sha256sum
   ```

3. `op-reason/Install-OpReason.ps1` の表 (`Get-OpReasonReleases`) に「版 = Zip と Tree」の行を足し (古い版の行は、入っている版を
   名前で出すために残す)、`-Version` の既定値と、上の「今は」を新しい版にする。`Install-OpReason.Tests.ps1` にも新しい版の値の行を足す
4. WSL の実行ファイル (`nix/pkgs/op-reason/default.nix` の `version` と 2 つの SHA-256) も同じ版にする
   ([`nix/README.md`「op-reason の新しい版を出したとき」](../nix/README.md#op-reason-の新しい版を出したとき))
5. `Install-OpReason.Tests.ps1` を流して PR を出す
6. merge したら、入れるマシンで `setup --update` を流す (WSL の実行ファイルが上がり、Windows の部品も入れ替わる)。op の呼び出しの
   途中で止まったら、終わってから `Install-OpReason` か `bootstrap-windows-op-reason.sh --apply` で揃える

### Install-OpReason.ps1 を書くときの注意

- `dotfiles.ps1` と同じく **BOM 付きの UTF-8** で保存する
- 副作用の無い関数 (表・中身の値の作り方・版の決め方・plan・状態の表) と、落とす・プロセスを偽物に差し替えた流れ (SHA-256 が合わないと
  置かない・動いていると止まる・入れ替えが落ちたら戻す・途中の物を残さない) は、`op-reason/Install-OpReason.Tests.ps1` で確かめる。
  zip の展開と置き場所の入れ替えは、一時ディレクトリの本物のファイルで流す。Linux の pwsh で流すので Windows には触らない
  (このファイルは manifest に無いので配られない):

  ```sh
  nix shell nixpkgs#powershell -c pwsh -NoProfile -File win/op-reason/Install-OpReason.Tests.ps1
  ```

- 落とす・動いているかを見る本物の部分は、実機で置き場所を一時ディレクトリに向けて確かめる (本物の置き場所には触らない):

  ```powershell
  $t = Join-Path $env:TEMP 'op-reason-try'
  & "$HOME\.config\powershell\Install-OpReason.ps1" -InstallDir "$t\Programs\op-reason" -Check
  & "$HOME\.config\powershell\Install-OpReason.ps1" -InstallDir "$t\Programs\op-reason"
  Remove-Item -Recurse -Force $t
  ```

## ntn

`ntn/Install-Ntn.ps1` は、Notion の CLI の ntn を winget の `Notion.ntn` (zip の中の portable。管理者は要らない。x64 だけ) で入れ、
版を `-Version` の既定値 (今は `0.23.30`) の 1 か所で固定する ([ADR 055](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/055_win_ntn_claude_code_pin_updates_20261114T185136JST/README.md))。公式の手順も、Windows では winget だけ
(install script は Windows に対応しない)。WSL・Linux の ntn は別に `nix/pkgs/ntn` が入れる
([`nix/README.md`「ntn (Notion CLI) を Nix で入れる」](../nix/README.md#ntn-notion-cli-を-nix-で入れる))。

- setup が入れて揃えるのは `dotfiles.wsl.windowsFiles.ntn.enable = true` のマシン。既定は設定グループで決まり、③ 個人のアカウントに
  つながるものの段が on のホスト (グループ `personal`) で true ([`nix/README.md` の「設定グループ」](../nix/README.md#設定グループ))。
  既定と違う値にするなら、dotfiles-private に登録したホストのファイルか、`~/dotfiles/flake.nix` に足したホストの `wsl` に書く:

  ```nix
  wsl = {
    windowsFiles.enable = true;
    windowsFiles.ntn.enable = false;
  };
  ```

- false に戻しても setup は消さない (見なくなるだけ)。消すなら PowerShell で `winget pin remove --id Notion.ntn --exact` の後に
  `winget uninstall --id Notion.ntn --exact` を打つ
- ntn のログイン (`ntn login`) と設定は dotfiles では扱わない
- 置き場所は `%LOCALAPPDATA%\Microsoft\WinGet\Packages\Notion.ntn_Microsoft.Winget.Source_8wekyb3d8bbwe\ntn-x86_64-pc-windows-msvc\ntn.exe`
  (zip の中のディレクトリの下)

| 打つもの | すること |
| --- | --- |
| `Install-Ntn -Check` (PowerShell) | 差を出すだけ。揃っていれば終了コード 0、差があれば 1、入っていなければ 3 |
| `Install-Ntn` (PowerShell) | 揃える (入れる・入れ替える (上げる・下げる)・pin を足す) |
| `nix/scripts/bootstrap-windows-ntn.sh` (WSL) | `setup --update` でも毎回走る (order 97)。入っていなければ入れ、版か pin がずれていれば揃える。揃わなければ ⚠ で囲んで知らせる (setup は止めない) |
| `nix/scripts/bootstrap-windows-ntn.sh --apply` (WSL) | WSL から揃える (確かめずに流す) |
| `nix/scripts/check-winget-version.sh ntn` (WSL・CI) | 固定した版を winget の版の一覧と比べる。GitHub Actions の `winget-versions` が週 1 回流し、新しい版が winget に載って 30 日たつと落ちて知らせる ([後述](#ntn-の新しい版が出たとき)) |

揃えるときにすること (herdr と同じ):

1. 入っている版 (`ntn.exe --version`) と固定した版を比べる。違えば、先に `winget download` で固定した版の取得とハッシュを確かめ
   (落ちたら何も変えずに止まる)、pin を外し、`winget uninstall` してから `winget install --version` で入れる
2. 入れた後に `winget pin add` で `winget upgrade --all` から外す
3. 読み直して、版・pin・PATH で引かれる ntn を確かめる

- herdr と違い、setup は版のずれも揃える (常駐するものも UAC も無いので)。手で `winget upgrade` した新しい版も、固定した版に下げる
- 入れ替えるときに置き場所の `ntn.exe` が動いていると、置き換えられないので何も変えずに止まり、PID とコマンドラインを出す
  (setup は ⚠ で知らせる)。終わらせてから `Install-Ntn` か `bootstrap-windows-ntn.sh --apply` を打つ
- PATH で別の ntn (npm の global の `ntn.cmd`・cargo で入れた `ntn.exe` など) が先に引かれると、`-Check` の「PATH の ntn」が ⚠ に
  なり、外すディレクトリが ※ の行に出る。揃える手順では直らない (setup は揃えずに ⚠ で知らせる)。PATH は `.exe` のほか `.cmd`・
  `.bat`・`.ps1` も、PowerShell と同じくディレクトリの順に見る
- winget が置き場所をユーザーの PATH に足すマシン (pjp-raiden) と、`%LOCALAPPDATA%\Microsoft\WinGet\Links` に symlink を置くマシン
  (開発者モードなど) がある。どちらも winget のものとして読む
- 入れ替えの途中で `winget install` が落ちると、ntn が入っていない状態で止まることがある (取得は先に確かめてあるので稀)。そのときは
  `Install-Ntn` を打ち直す (`setup --update` でも入る)

### ntn の新しい版が出たとき

固定した版より新しい版が winget に載って 30 日たつと、GitHub Actions の `winget-versions` の `Windows の ntn` の job が落ちて
知らせる。出た日は winget-pkgs に載った日 (ntn は GitHub の release を出さない)。猶予・落ちる場合・見送りの一覧は
[winget の新しい版を確かめる](#winget-の新しい版を確かめる)。

上げるとき:

1. 新しい版で `ntn --help` と使っているコマンドの振る舞いが変わっていないかを、WSL の ntn (同じ版を入れるのは `nix/pkgs/ntn`) か
   Windows で試して確かめる
2. `ntn/Install-Ntn.ps1` の `-Version` の既定値と、上の「今は」を新しい版にし、`Install-Ntn.Tests.ps1` を流して PR を出す
   (`winget-versions` が、書いた版が winget にあるかを確かめる)
3. merge したら、各マシンで `setup --update` を流す (setup が揃える)。ntn が動いていて止まったら、終わらせてから `Install-Ntn` か
   `bootstrap-windows-ntn.sh --apply`
4. `-Check` が「揃っている」になり、`ntn --version` が新しい版を出すことを確かめる

見送るとき: `ntn/skipped-versions.txt` に「版 理由」を 1 行足して commit する。版を戻すときは `-Version` を前の版にすれば、setup が下げる。

### Install-Ntn.ps1 を書くときの注意

- `dotfiles.ps1` と同じく **BOM 付きの UTF-8** で保存する
- 副作用の無い関数 (版の読み方・plan・状態の表・締めの行・PATH の解決) と、winget とプロセスを偽物に差し替えた流れ (打つ winget の
  順・動いていると止まる・取得が落ちると何も変えない) は `ntn/Install-Ntn.Tests.ps1` で確かめる。Linux の pwsh で流すので Windows には
  触らない (このファイルは manifest に無いので配られない):

  ```sh
  nix shell nixpkgs#powershell -c pwsh -NoProfile -File win/ntn/Install-Ntn.Tests.ps1
  ```

- 締めの行 (`→ Install-Ntn で入れる`・`→ Install-Ntn で揃える`・`→ ※ の手順で直す`) の文言は `bootstrap-windows-ntn.sh` が読む。
  変えるときは向こうも直す
- winget やプロセスに触る本物の部分は、実機で `-Check` と本番を打って確かめる

## Claude Code

`claude-code/Install-ClaudeCode.ps1` は、Claude Code を winget の `Anthropic.ClaudeCode` (portable の `claude.exe` 1 つ。管理者は要らない。
x64 と arm64) で入れ、版を `-Version` の既定値 (今は `2.1.318`) の 1 か所で固定する ([ADR 055](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/055_win_ntn_claude_code_pin_updates_20261114T185136JST/README.md))。PowerShell の `c` が
起動する `claude.exe` はこれ ([PowerShell](#powershell))。WSL の claude は mise の `claude@latest` (猶予 1 日) で、別のもの。

- winget で入れた Claude Code は自分では上がらない (公式。`claude update` は何もしない)。版は dotfiles が決める
- `CLAUDE_CODE_PACKAGE_MANAGER_AUTO_UPDATE` (Claude Code に `winget upgrade` を打たせる) は設定しない。ユーザー・マシンの環境変数か
  `%USERPROFILE%\.claude\settings.json` の `env` で有効になっていれば、`-Check` が ※ の行で知らせる (固定した版から外れうるので消す)
- Git for Windows は入れない。無ければ Claude Code は Bash tool の代わりに PowerShell tool で動く (公式)
- Claude Code の設定 (`%USERPROFILE%\.claude`) とログインは dotfiles では扱わない
- setup が入れて揃えるのは `dotfiles.wsl.windowsFiles.claudeCode.enable = true` のマシン。既定は設定グループで決まり、② AI の道具の
  段が on のホスト (グループ `personal`・`company`) で true ([`nix/README.md` の「設定グループ」](../nix/README.md#設定グループ))。
  既定と違う値にするなら `wsl` に `windowsFiles.claudeCode.enable = false;` (か `true`) を書く ([ntn](#ntn) と同じ)。false に戻しても
  setup は消さない。消すなら PowerShell で
  `winget pin remove --id Anthropic.ClaudeCode --exact` の後に `winget uninstall --id Anthropic.ClaudeCode --exact`
- 置き場所は `%LOCALAPPDATA%\Microsoft\WinGet\Packages\Anthropic.ClaudeCode_Microsoft.Winget.Source_8wekyb3d8bbwe\claude.exe`

| 打つもの | すること |
| --- | --- |
| `Install-ClaudeCode -Check` (PowerShell) | 差を出すだけ。揃っていれば終了コード 0、差があれば 1、入っていなければ 3 |
| `Install-ClaudeCode` (PowerShell) | 揃える (入れる・入れ替える (上げる・下げる)・pin を足す) |
| `nix/scripts/bootstrap-windows-claude-code.sh` (WSL) | `setup --update` でも毎回走る (order 97)。入っていなければ入れ、版か pin がずれていれば揃える。揃わなければ ⚠ で囲んで知らせる (setup は止めない) |
| `nix/scripts/bootstrap-windows-claude-code.sh --apply` (WSL) | WSL から揃える (確かめずに流す) |
| `nix/scripts/check-winget-version.sh claude-code` (WSL・CI) | 固定した版を winget の版の一覧と比べる。GitHub Actions の `winget-versions` が週 1 回流し、新しい版が GitHub に出て 30 日たつと落ちて知らせる ([後述](#claude-code-の新しい版が出たとき)) |

揃えるときにすることは [ntn](#ntn) と同じ (取得を確かめてから外して入れ、pin を足し、読み直す)。違うところ:

- 入れ替えるときに置き場所の `claude.exe` が動いている (Windows で Claude Code の会話を開いている) と、Windows が exe を lock するので、
  何も変えずに止まって PID とコマンドラインを出す (setup は ⚠ で知らせる)。会話を閉じてから `Install-ClaudeCode` か
  `bootstrap-windows-claude-code.sh --apply` を打つ。WSL の claude の中で `setup --update` を流すのは構わない (別のもの)。
  pin を足すだけなら、動いていても進む
- `claude.exe` は 340 MB ほどあり、入れ替えでは取得の確かめと install で 2 回落とす。setup は 1800 秒まで待つ
- PATH で別の claude (native の installer か `claude install` の `%USERPROFILE%\.local\bin\claude.exe`・npm の global の `claude.cmd`) が
  先に引かれると、`-Check` の「PATH の claude」が ⚠ になる。揃える手順では直らないので、その claude を外す: native なら
  `%USERPROFILE%\.local\bin\claude.exe` と `%USERPROFILE%\.local\share\claude` を消し、npm なら `npm uninstall -g @anthropic-ai/claude-code`
  (公式の uninstall の手順)

### Claude Code の新しい版が出たとき

固定した版より新しい winget の版が GitHub に出て 30 日たつと、GitHub Actions の `winget-versions` の `Windows の Claude Code` の job が
落ちて知らせる。出た日は GitHub の release (`anthropics/claude-code` の `vX.Y.Z`。prerelease を除く) が出た日で、winget の版と tag の
`v` の後ろで突き合わせる。winget には GitHub より数日遅れて載り、載らない版もある (GitHub にある版が 30 日たっても winget に無ければ、
それも落ちて知らせる)。猶予・落ちる場合・見送りの一覧は [winget の新しい版を確かめる](#winget-の新しい版を確かめる)。

上げるとき:

1. release notes (GitHub の release か、Claude Code の CHANGELOG) で、Windows・PowerShell tool・設定に触る変更が無いかを見る
2. `claude-code/Install-ClaudeCode.ps1` の `-Version` の既定値と、上の「今は」を新しい版にし、`Install-ClaudeCode.Tests.ps1` を流して
   PR を出す (`winget-versions` が、書いた版が winget にあるかを確かめる)
3. merge したら、各マシンで `setup --update` を流す (setup が揃える)。Windows の Claude Code が動いていて止まったら、会話を閉じてから
   `Install-ClaudeCode` か `bootstrap-windows-claude-code.sh --apply`
4. `-Check` が「揃っている」になり、`claude --version` が新しい版を出すことを確かめる

見送るとき: `claude-code/skipped-versions.txt` に「版 理由」を 1 行足して commit する。版を戻すときは `-Version` を前の版にすれば、
setup が下げる。

### Install-ClaudeCode.ps1 を書くときの注意

- `dotfiles.ps1` と同じく **BOM 付きの UTF-8** で保存する
- 副作用の無い関数と、winget とプロセスを偽物に差し替えた流れは `claude-code/Install-ClaudeCode.Tests.ps1` で確かめる (Linux の pwsh):

  ```sh
  nix shell nixpkgs#powershell -c pwsh -NoProfile -File win/claude-code/Install-ClaudeCode.Tests.ps1
  ```

- 締めの行の文言は `bootstrap-windows-claude-code.sh` が読む。変えるときは向こうも直す
- winget やプロセスに触る本物の部分は、実機で `-Check` と本番を打って確かめる
