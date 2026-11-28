# win/

Windows 側のアプリの設定を置く場所。WSL から `/mnt/c` 越しにコピーして配る
(経緯は [ADR 010](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/010_win_files_from_wsl_20260928T003933JST/README.md))。

新しい Windows で最初に流す bootstrap も置く ([後述](#bootstrap-新しい-windows-で最初に流す))。Windows の環境は Windows 側の runner
(`runner/`。Rust。[後述](#runner-windows-の側で確かめて揃える)) で作る途中で、ホストごとに受け持ちを runner へ切り替えるまでは、WSL の setup と
同じ手順 (files・`Install-*.ps1`・`$PROFILE` の 1 行など) は今までどおり WSL が配り、runner は確かめるだけ。Windows にしか無い手順 (claude-skills を Windows の
Claude Code で使う W0-2 の手順・Windows の Claude Code に dotfiles の設定を配る手順・git の設定・herdr-app の mod とキーとハブの印など) は、受け持ちによらず
runner が流す (経緯は [ADR 058](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/058_win_runner_bootstrap_20261115T225331JST/README.md) と
dotfiles-private の ADR 060 (`docs/adr/060_win_runner_core_*`)・ADR 064 (`docs/adr/064_win_w02_claude_skills_hub_*`)・ADR 065
(`docs/adr/065_win_claude_config_*`)・ADR 066 (`docs/adr/066_win_git_config_*`)・ADR 068 (`docs/adr/068_win_herdr_app_mods_*`)・ADR 070
(`docs/adr/070_win_herdr_app_keys_*`)・ADR 072 (`docs/adr/072_win_herdr_app_pjp_spaces_*`)・ADR 090 (`docs/adr/090_win_claude_t3_launch_args_*`))。

受け持ちを runner に切り替えたホスト (ホストの値 (dotfiles-private の `win/hosts/*.toml` か手元の `%USERPROFILE%\.config\dotfiles\host.toml`) で `[runner] enable = true`) では、WSL の setup は Windows に触らない。
この README で「`~/dotfiles/setup --update` で配る・入れる・揃える」と書いた Windows の手順は、そのホストでは PowerShell の
`dotfiles --self-update apply` (Windows の 3 つの clone を進めてから `dotfiles apply`。[clone を進める](#clone-を進める-dotfiles---self-update)) で揃え、
`dotfiles check` で確かめる (固定した版より新しい版の知らせもここに出る)。WSL の `bootstrap-windows-*.sh` を
手で打つ手順は、`dotfiles apply --steps <id> --force` (`--force`)・`dotfiles import <id>` (`--import`)・PowerShell の `Install-*` (`--apply`) に
読み替える ([受け持ちを runner に切り替える](#受け持ちを-runner-に切り替える))。

| ファイル | 置き先 (Windows) | 中身 |
| --- | --- | --- |
| `bootstrap/Install-Bootstrap.ps1` | (配らない。新しい Windows で URL から落として流し、clone した後は clone の中のものを流す) | 新しい Windows で最初に流す setup。Git for Windows・PowerShell 7 を固定した版で入れ、public な dotfiles を Windows の ghq に clone し、ホストの値の雛形を写す。`-Rust` は runner を手元で build する Visual Studio Build Tools・rustup (MSVC の host) も入れる。`-Private` は GitHub CLI とそのログイン・Build Tools・rustup も入れ、dotfiles・dotfiles-private・claude-skills を clone する ([後述](#bootstrap-新しい-windows-で最初に流す)) |
| `templates/host.minimum.toml` | (配らない。引数なしの bootstrap が `%USERPROFILE%\.config\dotfiles\host.toml` に写す) | runner のホストの値の雛形 (設定グループ minimum だけの値・受け持ちは runner)。gh にログインできない PC (pollenjp の private な repo を取れない PC) のホストの値になる ([ホストの値](#ホストの値)) |
| `runner/` | (配らない。CI が key ごとの GitHub の Release に置いた exe を、`dotfiles` 関数が clone に合うものを落として起こす。合う exe が無ければ clone の中で `cargo run` で build する。[runner の exe (Release)](#runner-の-exe-release)) | Windows 側の runner (Rust の `dotfiles-win`)。WSL の setup の Windows の手順を写したもので、`dotfiles check` で確かめ、受け持ちを切り替えたホストでは `dotfiles apply` で揃える ([後述](#runner-windows-の側で確かめて揃える)) |
| `orca/keybindings.json` | `%USERPROFILE%\.orca\keybindings.json` | Orca のキーバインド ([TKT-25](https://app.notion.com/p/Orca-worktree-Ctrl-Alt-Ctrl-Ctrl-W-3e779149a66f8177809ac8632bf68b2c)) |
| `powershell/dotfiles.ps1` | `%USERPROFILE%\.config\powershell\dotfiles.ps1` | PowerShell の共有設定 (herdr と Claude Code の alias、`e` = `exit`、それらの略語を入力行の中で広げる PSReadLine の割り当て、入力行の Vi モード (挿入モードの bash に似たキー (Alt+f・Alt+b・Ctrl+w・Alt+d・Ctrl+a・Ctrl+e・Ctrl+k・Ctrl+u) と、モードを示すカーソルの形)、ghq の repo を fzf で選んで移る `cdrepo`、runner を流す `dotfiles` (`dotfiles --self-update` は 3 つの clone を進めてから))。`$PROFILE` から読む ([後述](#powershell)、[TKT-77](https://app.notion.com/p/PowerShell-profile-dotfiles-win-herdr-alias-h-hss-hls-Windows-3ef79149a66f817abc28dd3fa5241903)) |
| (`nix/files/starship.toml`) | `%USERPROFILE%\.config\starship.toml` | starship のプロンプトの設定。Linux の home-manager も同じファイルを `~/.config/starship.toml` に置くので `nix/` に置き、manifest の `base = "nix"` で配る。sh で判定する custom module は Windows では出さない。starship 本体は下の `starship/Install-Starship.ps1` (runner の `starship`) が、`$PROFILE` の init の 1 行は runner の `starship-init` が入れる ([後述](#starship)) |
| `powershell/Invoke-DotfilesSelfUpdate.ps1` | (配らない。`dotfiles --self-update` が clone の中のものを呼ぶ) | `dotfiles --self-update` の中身。dotfiles・dotfiles-private・claude-skills の clone を gh の資格情報 (gh が無ければ資格情報なし) で fetch して fast-forward し、後ろの引数があればその後に runner に渡す。private な repo の clone が無いのは「このホストでは使わない」 ([後述](#clone-を進める-dotfiles---self-update)) |
| `herdr/config.toml` | `%APPDATA%\herdr\config.toml` | Windows の herdr の設定。キーバインドと sidebar の行は WSL と同じ ([後述](#herdr)、[TKT-92](https://app.notion.com/p/herdr-Windows-win-herdr-config-toml-3f079149a66f819fb49ef2d13e6a76f5)) |
| `openssh/Install-OpenSSH.ps1` | `%USERPROFILE%\.config\powershell\Install-OpenSSH.ps1` | Windows の OpenSSH を winget で固定した版に揃える。PowerShell の `Install-OpenSSH` から呼ぶ ([後述](#openssh)、[TKT-109](https://app.notion.com/p/winget-Windows-OpenSSH-win-3f179149a66f812fba25c6b2d6ce5d31)) |
| `herdr/Install-Herdr.ps1` | `%USERPROFILE%\.config\powershell\Install-Herdr.ps1` | Windows の herdr を winget で固定した版に揃える。PowerShell の `Install-Herdr` から呼ぶ。setup が入れて揃えるのは `dotfiles.wsl.windowsFiles.herdr.enable = true` (既定は設定グループで決まる) のマシン ([後述](#herdr-を入れる-winget)、[TKT-112](https://app.notion.com/p/winget-Windows-herdr-Herdr-Herdr-Preview-dotfiles-3f179149a66f81858e0cf4555c9c598f)) |
| `herdr-app/claude-skill-head.md` | (配らない。runner の `herdr-app-skill` の手順が、`herdr-app --skill` の頭に足して `%USERPROFILE%\.claude\skills\herdr-app\SKILL.md` を作る) | herdr-app の Claude Code の skill の frontmatter と、作った版を書くコメント。hc の skill の頭は Linux と同じ `nix/pkgs/herdr-core/claude-skill-head.md` ([後述](#claude-skills-と-windows-のハブ-w0-2)) |
| `herdr-app/mods/pjp-hub-panel/` | `%USERPROFILE%\.config\herdr-app\mods\pjp-hub-panel\` (herdr-app の home の `mods\`。manifest では配らず、runner の `herdr-app-mods` の手順が配る) | 自作の herdr-app の mod。ハブの Claude がユーザーに見せる panel (質問・チケットと進み具合と PR の木・問いへの答え (Q&A)・状況の説明・進み具合・一覧・図) ([後述](#herdr-app-の-mod)) |
| `herdr-app/mods/pjp-prefix/` | `%USERPROFILE%\.config\herdr-app\mods\pjp-prefix\` (`herdr-app-mods` の手順が配る) | 自作の herdr-app の mod。旧 herdr の prefix (`Ctrl+K`) の小窓で、次の 1 キーで分割・タブ・worktree などの命令を流す ([後述](#herdr-app-のキー)) |
| `herdr-app/mods/pjp-worktree-remove/` | `%USERPROFILE%\.config\herdr-app\mods\pjp-worktree-remove\` (`herdr-app-mods` の手順が配る) | 自作の herdr-app の mod。prefix の後の `d` と `Ctrl+Q` が開く小窓で、今の space の端末を全部止め、終わるのを待ってから space を閉じて worktree を消す ([後述](#herdr-app-のキー)) |
| `herdr-app/mods/pjp-sidebar-tabs/` | `%USERPROFILE%\.config\herdr-app\mods\pjp-sidebar-tabs\` (`herdr-app-mods` の手順が配る) | 自作の herdr-app の mod。左のサイドパネルの上端に、Spaces と Agents を切り替えるアイコンのタブを描く (layout pjp-main の stack `sidebar-lists` の header。[後述](#サイドパネルのタブ-pjp-sidebar-tabs)) |
| `herdr-app/keys.json` | `%USERPROFILE%\.config\herdr-app\keys.json` の一部のキー (herdr-app の home。manifest では配らず、runner の `herdr-app-keys` の手順が書き足す) | herdr-app のキーのうち、dotfiles が持つキーだけ (space とタブの移動・prefix の `Ctrl+K`・worktree を消す確かめの小窓の `Ctrl+Q`・サイドパネルのタブを切り替える `Ctrl+Alt+←→`) ([後述](#herdr-app-のキー)) |
| `herdr-app/keys.defaults.json` | (配らない。runner の `herdr-app-keys` の手順が読む) | herdr-app の既定の値のうち、dotfiles が上書きしてよいもの (`Ctrl+PageUp`・`Ctrl+PageDown` のタブの移動) ([後述](#herdr-app-のキー)) |
| (claude-skills の `skills/pjp-hc-hub/herdr-app/mods/pjp-spaces/`) | `%USERPROFILE%\.config\herdr-app\mods\pjp-spaces\` と、同梱の `layouts\main.json` を写した `layouts\pjp-main.json` (manifest では配らず、runner の `herdr-app-pjp-spaces` の手順が置く) | claude-skills の herdr-app の mod。sidebar の space の行の 2 行目にハブと子の印を出す。pjp-main は sidebar の spaces を pjp-spaces に替え、Spaces と Agents を上端のタブ (`pjp-sidebar-tabs`) で切り替える layout で、初めて置くときに表示する layout にする ([後述](#herdr-app-の印-pjp-spaces)) |
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
| (dotfiles-private の `ssh/*.ssh_config`) | `%USERPROFILE%\.ssh\config` と `config.d\` | ssh の接続先。manifest では配らず、`bootstrap-windows-ssh-config.sh` (受け持ちを runner に切り替えたホストは runner の `ssh-config`) がコピーする ([後述](#ssh-の設定)、[TKT-145](https://app.notion.com/p/Windows-OS-Windows-ssh-3f779149a66f81c4a2cff0233027c26e)) |
| `port-forward/Start-PortForward.ps1` | `%USERPROFILE%\.config\powershell\Start-PortForward.ps1` | ssh の Host と port の組を選んで port forwarding を張る。PowerShell 7 の `pf` から呼ぶ ([後述](#port-forwarding-pf)) |
| (dotfiles-private の `ssh/port-forward.toml`) | `%USERPROFILE%\.config\port-forward\hosts.json` | `pf` が出す port の組 (共有の組)。manifest では配らず、`bootstrap-windows-port-forward.sh` (受け持ちを runner に切り替えたホストは runner の `port-forward`) が JSON にして置く ([後述](#port-forwarding-pf)) |
| `windows-terminal/managed.json` | Store 版の `settings.json` (`%LOCALAPPDATA%\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\`) の一部のキー | Windows Terminal の設定のうち、dotfiles が持つキーだけ (今は bell の音)。manifest では配らず、`bootstrap-windows-terminal.sh` がキーごとに書き足す ([後述](#windows-terminal)、[TKT-167](https://app.notion.com/p/Windows-Terminal-settings-json-dotfiles-bell-3fb79149a66f81e6a695c581b5ab5cef)) |
| `international/managed.json` | ユーザーのレジストリ `HKCU\Control Panel\International` の一部の値 | Windows の日付と時刻の形式のうち、dotfiles が持つ値だけ (短い日付・長い時刻・短い時刻)。manifest では配らず、`bootstrap-windows-international.sh` (受け持ちを runner に切り替えたホストは runner の `international`) が SetLocaleInfoW で書く ([後述](#日付と時刻の形式)) |
| `type-clipboard/Install-TypeClipboard.ps1` | `%USERPROFILE%\.config\powershell\Install-TypeClipboard.ps1` | 自作の type-clipboard を、GitHub の Release から固定した版 (SHA-256 も固定) で入れる。PowerShell の `Install-TypeClipboard` から呼ぶ。setup が入れるのは `dotfiles.wsl.windowsFiles.typeClipboard.enable = true` のマシンだけ ([後述](#type-clipboard)) |
| `op-reason/Install-OpReason.ps1` | `%USERPROFILE%\.config\powershell\Install-OpReason.ps1` | WSL の op (自作の OSS の op-reason。1Password CLI の wrapper) の Windows の部品 `op-reason-windows.zip` を、GitHub の Release から固定した版 (SHA-256 も固定) で `%LOCALAPPDATA%\Programs\op-reason` に入れる。PowerShell の `Install-OpReason` から呼ぶ。setup が入れて揃えるのは、WSL の op の wrapper を入れるマシン (`dotfiles.wsl.enable` と `dotfiles.onePassword.enable` が両方 true) だけ ([後述](#op-reason)) |
| `ntn/Install-Ntn.ps1` | `%USERPROFILE%\.config\powershell\Install-Ntn.ps1` | Notion の CLI の ntn を winget の `Notion.ntn` で固定した版に揃える。PowerShell の `Install-Ntn` から呼ぶ。setup が入れて揃えるのは `dotfiles.wsl.windowsFiles.ntn.enable = true` (既定は設定グループで決まる) のマシン ([後述](#ntn)) |
| `claude-code/Install-ClaudeCode.ps1` | `%USERPROFILE%\.config\powershell\Install-ClaudeCode.ps1` | Claude Code を winget の `Anthropic.ClaudeCode` で固定した版に揃える。PowerShell の `Install-ClaudeCode` から呼ぶ。setup が入れて揃えるのは `dotfiles.wsl.windowsFiles.claudeCode.enable = true` (既定は設定グループで決まる) のマシン ([後述](#claude-code)) |
| `ghq/Install-Ghq.ps1` | `%USERPROFILE%\.config\powershell\Install-Ghq.ps1` | ghq を winget の `x-motemen.ghq` で固定した版に揃える。PowerShell の `Install-Ghq` から呼ぶ。入れて揃えるのは runner の `ghq` (いつも。WSL の setup は入れない)。`cdrepo` が使う ([後述](#ghqfzf)) |
| `fzf/Install-Fzf.ps1` | `%USERPROFILE%\.config\powershell\Install-Fzf.ps1` | fzf を winget の `junegunn.fzf` の portable で固定した版に揃える (MSI の fzf が入っていれば、何も入れずに外し方を出す)。PowerShell の `Install-Fzf` から呼ぶ。入れて揃えるのは runner の `fzf` (いつも。WSL の setup は入れない)。`cdrepo` が使う ([後述](#ghqfzf)) |
| `starship/Install-Starship.ps1` | `%USERPROFILE%\.config\powershell\Install-Starship.ps1` | starship (プロンプト) を winget の `Starship.Starship` の portable で、Linux と同じ固定した版に揃える (MSI の starship が入っていれば、何も入れずに外し方を出す)。PowerShell の `Install-Starship` から呼ぶ。入れて揃えるのは runner の `starship` (いつも。WSL の setup は入れない)。`$PROFILE` の init の 1 行は runner の `starship-init` が足す ([後述](#starship)) |
| `openssh/Install-Sshd.ps1` | `%USERPROFILE%\.config\powershell\Install-Sshd.ps1` | dotfiles が winget で固定した OpenSSH の MSI に sshd (Server の機能) を足し、Tailscale (tailnet) と localhost からだけ、鍵でだけ SSH で入れる形 (sshd_config・Windows Firewall の拒否の規則・`administrators_authorized_keys`・自動の起動) に揃える。PowerShell の `Install-Sshd` から呼ぶ。setup が入れるのは `dotfiles.wsl.windowsFiles.sshd.enable = true` (minimum では既定で false) のマシンだけ (runner はホストの値の `windowsSshd`。[後述](#sshd)) |
| `tailscale/Install-Tailscale.ps1` | `%USERPROFILE%\.config\powershell\Install-Tailscale.ps1` | Tailscale を winget の `Tailscale.Tailscale` (machine スコープの MSI) で、固定した版で入れる (入っていないときだけ。入れた後は Tailscale の自動更新に任せる)。PowerShell の `Install-Tailscale` から呼ぶ。setup が入れるのは `dotfiles.wsl.windowsFiles.tailscale.enable = true` (minimum では既定で false) のマシンだけ ([後述](#tailscale)) |
| `t3-code/Install-T3Code.ps1` | `%USERPROFILE%\.config\powershell\Install-T3Code.ps1` | T3 Code を winget の `T3Tools.T3Code` (user スコープ) で、固定した版で入れる (入っていないときだけ。入れた後は T3 Code の自動更新に任せる)。PowerShell の `Install-T3Code` から呼ぶ。入れるのは runner の `t3-code` で、ホストの値の `[tools] windowsT3Code = true` (minimum では既定で false) のマシンだけ ([後述](#t3-code)) |
| `claude-desktop/Install-ClaudeDesktop.ps1` | `%USERPROFILE%\.config\powershell\Install-ClaudeDesktop.ps1` | Claude Desktop (Claude のデスクトップ版) を winget の `Anthropic.Claude` の MSIX (`--installer-type msix`) で、固定した版で入れる (入っていないときだけ。管理者の権限で入れるので UAC の確認が 1 回出る。入れた後は Claude Desktop の自動更新に任せる)。PowerShell の `Install-ClaudeDesktop` から呼ぶ。入れるのは runner の `claude-desktop` で、ホストの値の `[tools] windowsClaudeDesktop` が on (既定はグループ all だけ) のマシンだけ ([後述](#claude-desktop)) |
| `winget/Install-WinGet.ps1` | `%USERPROFILE%\.config\powershell\Install-WinGet.ps1` | winget 自身 (アプリ インストーラー) を、GitHub の `microsoft/winget-cli` の Release から固定した版 (msixbundle と依存の zip の SHA-256 も固定) で、固定した版より古ければ上げる (下げない。UAC を出さない)。PowerShell の `Install-WinGet` から呼ぶ。入れて揃えるのは runner の `winget` (いつも。winget を使うほかの手順より先に流す) ([後述](#winget)) |
| `codex/Install-Codex.ps1` | `%USERPROFILE%\.config\powershell\Install-Codex.ps1` | OpenAI の Codex CLI を winget の `OpenAI.Codex` の portable で固定した版に揃え、`codex` と打てる形 (`WinGet\Links` の symlink か、置き場所の `codex.exe` の hardlink) を winget に作らせる (winget は昇格せずに打つ。UAC を出さない)。PowerShell の `Install-Codex` から呼ぶ。入れて揃えるのは runner の `codex` で、ホストの値の `[tools] windowsCodex` が on (既定はグループ all だけ) のマシンだけ ([後述](#codex-cli)) |
| `claude-code/CLAUDE.windows.md` | (配らない。runner の `claude-files` の手順が、`nix/files/claude/CLAUDE.md` の冒頭をこれに差し替えて `%USERPROFILE%\.claude\CLAUDE.md` を作る) | Windows の Claude Code の CLAUDE.md の冒頭 (runner が配ること・直し方) ([後述](#claude-code-の設定)) |
| `claude-code/skip-skills.txt` | (配らない。runner の `claude-files` の手順が読む) | Windows の Claude Code に張らない dotfiles の skill (Nix・そのマシンの `~/dotfiles` を前提にするもの) ([後述](#claude-code-の設定)) |
| `claude-code/t3/settings.json` | `%USERPROFILE%\.claude\t3\settings.json` (manifest では配らず、runner の `claude-t3` の手順が置く) | T3 Code の会話だけの Claude の設定。T3 の Launch arguments の `--settings` が読む (herdr と hc のハブ・子の skill を off・`pjp-t3-hub` を on にする `skillOverrides`) ([後述](#claude-code-の設定)) |
| `claude-code/t3/CLAUDE.t3.md` | `%USERPROFILE%\.claude\t3\CLAUDE.t3.md` (`claude-t3` の手順が置く) | T3 Code の会話だけの指示。T3 の Launch arguments の `--append-system-prompt-file` が system prompt の後ろに足す (herdr-app を前提にした指示の読み替え) ([後述](#claude-code-の設定)) |
| (`nix/home/modules/git.toml`) | `%USERPROFILE%\.config\git\config`・`ignore`・`config.<owner>` | git の設定のうち、どの OS でも同じにする値 (名前とメール・pollenjp-sub の名前とメール・alias・core など・ignore) の正本。WSL の home-manager (`nix/home/modules/git.nix`) と runner の `git-config` の手順が同じファイルを読む ([後述](#git-の設定)) |

## bootstrap (新しい Windows で最初に流す)

新しい Windows で最初に流す PowerShell の script (`bootstrap/Install-Bootstrap.ps1`)。Rust の runner を動かせるところまで (Git for Windows・
PowerShell 7 と dotfiles の clone。runner の exe は `dotfiles` 関数が GitHub の Release から落とす。[runner の exe (Release)](#runner-の-exe-release))
を揃える。WSL は要らない。Windows の環境を Windows 側の runner で作る最初の段で、
その後は runner (`runner/`。[後述](#runner-windows-の側で確かめて揃える)) が受け持つ。ホストごとに受け持ちを runner に切り替えるまで、Windows の
アプリと設定を配るのは今までどおり WSL の setup ([配る](#配る))。経緯は
[ADR 058](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/058_win_runner_bootstrap_20261115T225331JST/README.md)
(ADR 010 の前提「WSL のある Windows だけ」を改めた) と、gh にログインできない PC でも流せる形にした dotfiles-private の ADR 111
(`docs/adr/111_win_runner_without_gh_*`)、runner を build 済みの exe で配り、既定の形から Build Tools と rustup を外した dotfiles-private の
ADR 117 (`docs/adr/117_win_runner_exe_release_*`)。

形は 3 つ。どの Windows でも流せる:

| 形 | 使う PC | gh | Build Tools と rustup | clone | ホストの値 |
| --- | --- | --- | --- | --- | --- |
| 既定 (引数なし) | gh にログインできない PC (客先の PC など。pollenjp の private な repo を取れない) と、private な repo を使わない PC | 入れない・ログインしない | 入れない・確かめない (runner は配った exe で動く) | public な dotfiles だけを、資格情報なしの HTTPS で (origin は `https://github.com/pollenjp/dotfiles.git`) | 雛形 `templates/host.minimum.toml` を `%USERPROFILE%\.config\dotfiles\host.toml` に写す (あれば上書きしない。dotfiles-private の clone がある PC でも写さない) |
| `-Rust` | 既定の形の PC のうち、runner を手元で build する (win/runner を直して試す)・claude-selector (cs) を作る PC | 既定と同じ | 入れる | 既定と同じ | 既定と同じ |
| `-Private` | private な repo (dotfiles-private・claude-skills) を使う PC (ホストの値の `privateRepos` が on のもの。[ホストの値](#ホストの値)) | 入れて、個人の gh のアカウントで github.com にログインする | 入れる (`-Rust` を含む。claude-skills の道具を cargo で作るため) | dotfiles・dotfiles-private・claude-skills を gh の資格情報で (origin は WSL と同じ ssh の URL) | dotfiles-private の `win/hosts/` から引く (雛形は写さない) |

- bootstrap はホストの値を読まない (clone する前に流すので)。どの形で流すかは、人がこの表で決める。runner の手順 `bootstrap` (`-Check` で確かめる
  だけ) はいつも on で、`privateRepos` のホストでは `-Check -Private` を流す (`-Rust` は付けないので、`-Rust` で揃えた PC でも Build Tools と rustup の
  行は出ない。[runner の手順](#runner-の手順))
- 既定の形で揃えた PC で、後から runner を手元で build したくなったら `-Rust` で流し直す (Build Tools と rustup を足す)
- 既定の形で流した PC で後から private な repo を使うなら、`-Private` で流し直す (gh を入れてログインし、無い clone を足す)。手元の `host.toml` が
  残っていて dotfiles-private にもホストの値を書くと、runner の apply は止まる (どちらを使うか決まらない。手元の方を退ける)
- 普通の (管理者でない) PowerShell で流す。管理者の PowerShell だと何も変えずに止まる (clone と rustup が管理者の持ち物になり、普通の
  権限の git が `dubious ownership` で止まるため)。UAC は道具ごとに出る (普段のアカウントが管理者の PC の PowerShell 7 (MSIX) と rustup は
  ユーザー単位に入るので出ない。管理者でない PC の PowerShell 7 は MSI なので出る)。入れたての Windows 11 で Git だけは、昇格した winget で
  入れ直すことがある (下の「bootstrap がすること」の表)
- 対象の CPU は x64 だけ (ARM64 の Windows は今は対象外)

### bootstrap を流す

新しい Windows (git が無い) では、Windows PowerShell でファイルに落としてから流す (`irm … | iex` にしない。読んでから流せるように):

```powershell
$f = Join-Path $env:TEMP 'Install-Bootstrap.ps1'
Invoke-WebRequest -UseBasicParsing -OutFile $f https://raw.githubusercontent.com/pollenjp/dotfiles/main/win/bootstrap/Install-Bootstrap.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File $f -Check            # 何も変えずに状態を出す
powershell -NoProfile -ExecutionPolicy Bypass -File $f                   # 揃える (既定の形。gh も Build Tools も使わない)
powershell -NoProfile -ExecutionPolicy Bypass -File $f -Rust             # runner を手元で build する PC (Build Tools と rustup も入れる)
powershell -NoProfile -ExecutionPolicy Bypass -File $f -Private          # private な repo も使う PC (gh でログインする。Build Tools と rustup も)
```

clone した後は、clone の中のものを流す (冪等。揃っていれば何もしない。`-Private` で揃えた PC は `-Private` も付ける):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File $HOME\ghq\github.com\pollenjp\dotfiles\win\bootstrap\Install-Bootstrap.ps1 -Check
```

### bootstrap の後に打つ

揃え終えると (終了コード 0)、bootstrap が次に打つコマンドを出す。PowerShell 7 の新しい窓 (スタートメニューの PowerShell 7 か、Windows Terminal の
PowerShell。bootstrap を流した窓は PATH が古い) で、clone の `dotfiles.ps1` を読み込んで runner を流す:

```powershell
. "$HOME\ghq\github.com\pollenjp\dotfiles\win\powershell\dotfiles.ps1"
dotfiles apply
```

- **前に bootstrap を流した PC は、先に clone を進める。** bootstrap は既にある clone を進めないので、前に流したときの古い clone が残る。launcher の無い
  古い clone の `dotfiles` 関数は直せず (古いまま動き、runner を cargo run で build する)、Build Tools の無い PC では落ちる。bootstrap は古い clone を
  見つけると次に打つコマンドの頭に進める 1 行を出すので、それを先に打つ。手で進めるなら、`dotfiles.ps1` を読み込む前に:

  ```powershell
  git -C "$HOME\ghq\github.com\pollenjp\dotfiles" pull --ff-only
  ```

  (`-Private` で揃えた PC は origin が ssh の URL なので、`& "$HOME\ghq\github.com\pollenjp\dotfiles\win\powershell\Invoke-DotfilesSelfUpdate.ps1"`
  で gh の資格情報で進める。[clone を進める](#clone-を進める-dotfiles---self-update))。進めた後は PowerShell 7 の新しい窓で読み込み直す
- 初めての `dotfiles apply` は、clone に合う runner の exe を GitHub の Release から落とす (github.com と release-assets.githubusercontent.com に
  届くこと。[runner の exe (Release)](#runner-の-exe-release))。プロキシの内側の PC は、Windows のプロキシの設定 (PowerShell の `Invoke-WebRequest` が
  使う) を先に入れる
- `dotfiles apply` の手順 `powershell-profile` が `$PROFILE` に `dotfiles.ps1` を読む 1 行を足すので、2 回目からは新しい PowerShell で `dotfiles` を
  打てる。先に見るなら `dotfiles check` か `dotfiles apply --dry-run`
- ホストの値は、既定の形なら手元の `host.toml` (minimum の雛形)、`-Private` なら dotfiles-private の `win/hosts/<ユーザー>@<PC>.toml`。無ければ
  `dotfiles check` が ⚠ を出し、`apply` は止まる ([ホストの値](#ホストの値))
- runner は PowerShell 7 に `$PROFILE` の場所を聞き、手順 `international` も PowerShell 7 で流す。Windows PowerShell 5.1 だけの PC では
  2 つが手作業 (manual) で残り、`dotfiles.ps1` も読まれないので、bootstrap が PowerShell 7 を入れる

| 終了コード | 意味 |
| --- | --- |
| 0 | 直すことが無い (古い clone の ⚠ は知らせるだけで、0 のまま) |
| 3 | 入っていない・無いものだけ (引数なしで流せば揃う。締めの行は「入っていない・無いものがある → 引数なしで流すと揃える」) |
| 1 | ほかに直すことがある (表の ⚠ の行を見る)。足りない・ずれているもの (pin・Build Tools の部品・rustup の設定と既定の host・gh のログイン) は引数なしで流せば直り (締めの行は「足りないもの・ずれているものがある → 引数なしで流すと直す」)、bootstrap では直らない差は ※ の手順で直す。Ctrl+C で止めた・揃えきれなかったときも |
| 2 | winget が無い (Microsoft Store の「アプリ インストーラー」を入れる)・思わぬ例外 |

- 道具を入れるときの UAC で「はい」を押さない・installer の窓を閉じると、その道具は入らず「インストーラーが取り消された」と出て、
  締めの表の ⚠ とともに終了コード 1 で終わる。流し直すと、もう一度入れる

### bootstrap がすること

1. 最初に Smart App Control (SAC) を確かめる (`-Check` でも)。オフでなければ (オン・評価モード) 警告を出して続ける (止めない)。
   オンだと runner の exe (配った exe も、cargo が作った exe と build script も) は止められて動かないので、runner を流す前にオフにする
   (Windows セキュリティ → アプリとブラウザーの制御 → スマート アプリ コントロールの設定。Windows によっては戻すのに再インストールが要る)。
   SAC は、出どころによらず評判も署名も無い exe を止める (配った exe は署名していない)。組織の管理下の PC では SAC は無効になる。script は
   SAC を変えない
2. 道具を固定した版で入れ、winget の pin を足す (この順。rustup-init が MSVC を見るので、Build Tools を rustup より先に入れる。GitHub CLI は
   `-Private` のときだけ、Build Tools と rustup は `-Rust`・`-Private` のときだけ。PowerShell 7 は入れ方を問わず認め、入っていないときだけ入れる。普段のアカウントが管理者でない PC は、MSIX しか無ければ
   MSI を足す。[PowerShell 7 (入れ方を問わず認める)](#powershell-7-入れ方を問わず認める)):

   | 道具 | winget の ID | 固定した版 (param) | 入れ方 |
   | --- | --- | --- | --- |
   | Git for Windows | `Git.Git` | `2.56.1` (`-GitVersion`) | machine の scope (`C:\Program Files\Git`)。インストーラーの選択肢は既定のまま。入れたての Windows 11 の winget (v1.11.510) は、昇格していないと machine の scope の source を開けず、`Failed to open the predefined source` (`0x80070005`) で落ちる。そのときだけ、同じ引数を昇格した winget で打ち直す (System32 の Windows PowerShell を UAC で昇格させて打つ。UAC の確認は Git の installer の代わりにそこで 1 回出る。普段のアカウントが管理者でない PC で、昇格した側のアカウントに winget が無ければ、そのアカウントと登録の手を出す) |
   | GitHub CLI (`-Private` だけ) | `GitHub.cli` | `2.105.0` (`-GhVersion`) | MSI (`C:\Program Files\GitHub CLI`)。`--silent` を付けないので、UAC と進み具合の小さな窓が出る (per-machine の MSI は、quiet だと管理者でない PowerShell から UAC を出せずに落ちる) |
   | PowerShell 7 | `Microsoft.PowerShell` | `7.6.10.0` (`-PwshVersion`) | 入っていないときだけ入れる。普段のアカウントが管理者の PC は MSIX (`--installer-type msix`。ユーザー単位に入るので UAC は出ない。`--silent`)、管理者でない PC は MSI (`--installer-type wix --custom "USE_MU=0 ENABLE_MU=0"`。`C:\Program Files\PowerShell\7`。`--silent` を付けないので、UAC で管理者の資格情報を入れる。Microsoft Update の更新には入れない)。管理者でない PC で MSIX しか無ければ MSI を `--force` で足す (入っている MSIX があると、winget は install を upgrade に替えて止まるため)。入れた直後に、7.6 の線に留める pin (`--version 7.6.*`) を足す。7.6 (LTS) の MSIX は package `Microsoft.PowerShell-LTS` で、7.7 からの MSIX (別の package `Microsoft.PowerShell`) へは上がらない。7.7 からは MSI も無い |
   | Visual Studio Build Tools 2022 (`-Rust`・`-Private` だけ) | `Microsoft.VisualStudio.2022.BuildTools` | `17.14.45` (`-VsBuildToolsVersion`) | C++ のワークロード (`Workload.VCTools`。必須の部品だけ)・x64 の MSVC (`VC.Tools.x86.x64`)・Windows SDK (`Windows11SDK.26100`)・英語の言語パック。MSVC と SDK は rustup が自分で入れるときと同じ部品。`--silent` を付けないので、UAC と進み具合の窓が出る。数 GB を落とすので 10 分以上かかることがある |
   | rustup (`-Rust`・`-Private` だけ) | `Rustlang.Rustup` | `1.29.3` (`-RustupVersion`) | 既定の host を MSVC (`--default-host x86_64-pc-windows-msvc`) にし、toolchain は入れない (`--default-toolchain none`。版は runner の `rust-toolchain.toml` が決める)。自己更新を止める (`rustup set auto-self-update disable`) |

   Rust は MSVC の host (`x86_64-pc-windows-msvc`) を使う。GNU の host (`x86_64-pc-windows-gnu`) にしないのは、`windows-sys` 0.61 が使う
   `windows-link` の `raw-dylib` の build に MinGW の `dlltool` と `as` が要り、GNU の toolchain に同梱の `dlltool` だけでは import library を
   作れないため (`windows-latest` の GitHub Actions は MinGW が入っているので通る)。
   - 入っている Build Tools に足りないもの (ワークロード・MSVC・SDK) があれば、Visual Studio Installer で足す (UAC と進み具合の窓)。Windows SDK は
     10 か 11 のどれかがあれば足りたことにする
   - 入っている rustup の既定の host (`rustup show` の `Default host`) が MSVC でなければ (GNU にしていた Windows など)、
     `rustup set default-host x86_64-pc-windows-msvc` で直す。入っている toolchain には触らない (GNU の toolchain が残っていて要らなければ
     `rustup toolchain list` で見て `rustup toolchain uninstall <名前>` で外す)
3. (`-Private` だけ) gh が github.com にログインしていなければ `gh auth login --hostname github.com --web --clipboard --git-protocol ssh --skip-ssh-key` を流す
   (一回限りのコードは gh がクリップボードに入れるので、Enter で開いたブラウザーに貼り付けて認める)。`--git-protocol ssh` にするのは、gh に
   `~/.gitconfig` の credential helper を書かせないため
   - コードを写そうとして Ctrl+C を押すと gh が止まる。そのときも bootstrap は止まらずに読み直しと締めの表まで出し、clone はせずに終了コード
     1 で終える (流し直すと、ログインからやり直す)。ログインのほかの所で Ctrl+C を押したときは、止めたことを 1 行出して終了コード 1 で終える
4. 無い repo を `%USERPROFILE%\ghq\github.com\pollenjp\` に clone する (ghq の既定の root。既定の形は dotfiles だけ、`-Private` は dotfiles・
   dotfiles-private・claude-skills)
   - 既定の形は、github.com の credential helper を空にして (Git Credential Manager を呼ばない)、資格情報なしの HTTPS (`https://github.com/pollenjp/dotfiles.git`)
     で clone する。origin もその URL。プロキシの内側の PC は、git の `http.proxy` を自分で設定してから流す
   - `-Private` は、gh の資格情報で HTTPS を通す組 (`nix/pkgs/git-gh` と同じ) を、clone のときだけ `-c` で渡す。origin は WSL と同じ ssh の URL
     (`git@github.com:pollenjp/<repo>.git`) のまま。`~/.gitconfig` は書かない
   - `core.autocrlf=false` をその repo に書く。Git for Windows の既定 (`true`) のままだと LF が CRLF で取り出され、WSL が配ったものと
     バイト列がずれる
   - あるディレクトリと clone には触らない (取得もしない)。git の repo でない・origin が別の repo・`core.autocrlf` が `true` なら ⚠ で
     知らせる (退けて流し直すと clone し直す)。origin は ssh と https のどちらの URL でもよい (既定の形で clone した後に `-Private` で流してもよい)
   - dotfiles の clone が古ければ ⚠ で知らせる (知らせるだけで、終了コードと締めの行には数えない)。古いのは、runner の launcher
     (`win\powershell\Invoke-DotfilesRunner.ps1`) が無い clone (その clone の `dotfiles` 関数は runner を cargo run で build して起こし、Build Tools の
     無い PC では `link.exe` が無くて落ちる) と、origin の既定の branch の先頭の commit を HEAD が含まない clone。先頭は `git ls-remote` で読むだけで、
     clone の ref も作業ツリーも変えない (dotfiles は public なので、どの形でも資格情報なしの HTTPS で読む。つながらなければ見ない)。揃ったときに出す
     次に打つコマンドの頭に、進める 1 行 (clone にある `Invoke-DotfilesSelfUpdate.ps1`。無ければ `git -C <clone> pull --ff-only`) を足す
     ([bootstrap の後に打つ](#bootstrap-の後に打つ))
5. (既定の形だけ) 手元のホストの値 `%USERPROFILE%\.config\dotfiles\host.toml` も dotfiles-private の clone も無ければ、clone の雛形
   `win/templates/host.minimum.toml` を写す (あれば上書きしない。dotfiles-private の clone がある PC は、ホストの値をそこから引くので写さない)
6. 揃え終えたら (終了コード 0。初めから揃っていたときも)、次に打つコマンドを出す ([bootstrap の後に打つ](#bootstrap-の後に打つ))。`-Check` では
   出さない (runner の手順 bootstrap が毎回 `-Check` を流すので)

- 入っている道具の版が固定した版と違っても揃えない (⚠ と、手で揃える手順の ※ を出す。下の「版のずれを手で揃える」)
- 見るのは固定した版の置き場所だけ。別の形で入っているもの (user の scope の Git・zip の gh・Visual Studio の Community や 2026) があっても、
  固定した版を並べて入れる。どちらが使われるかは PATH の順や rustc の探し方で決まるので、気になれば別の形のものを外す。PowerShell 7 だけは
  入れ方を問わず認め、版も比べない (下の「PowerShell 7 (入れ方を問わず認める)」)
- Git for Windows を入れると、Windows の Claude Code が Git Bash を見つけて使えるようになる
- 前の bootstrap (ADR 117 より前は、どの形でも Build Tools と rustup を入れていた) で入れた Build Tools と rustup は、既定の形で流し直しても消さない
  (`-Check` の表に出なくなるだけ)。runner は配った exe で動くので、minimum の PC で要らなければ手で外す: `winget pin remove --id Rustlang.Rustup`・
  `winget uninstall --id Rustlang.Rustup` (`%USERPROFILE%\.cargo` と `%USERPROFILE%\.rustup` も消してよい)、Build Tools は `winget pin remove --id
  Microsoft.VisualStudio.2022.BuildTools` の後に「アプリ」の一覧か Visual Studio Installer から外す。後で build したくなったら `-Rust` で入れ直す

### PowerShell 7 (入れ方を問わず認める)

bootstrap は PowerShell 7 を、入れ方を問わず (MSI・MSIX (Microsoft Store・winget)・PATH のほかの pwsh)、`7.6.0` より古くなければ入っている
とみなす。版を固定した版と比べず、pin も見ない (Microsoft Store の MSIX は Store が上げるので、版も pin も揃えられない)。ただし普段のアカウントが
管理者でない PC は、MSIX でない PowerShell 7 も要る (下の「管理者でない PC」)。

- 見る順: 新しい窓の PATH (レジストリのマシン → ユーザーの `Path`) のディレクトリごとの `pwsh.exe` → MSI の既定の置き場所
  (`C:\Program Files\PowerShell\7\pwsh.exe`) → MSIX の実行エイリアス (`%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe`)。最初に見つかった
  ものの `pwsh --version` を読み、表に版と入れ方 (MSIX・MSI。ほかの形はパス) を出す。runner と herdr は PATH の `pwsh` を起こすので、
  PATH の外 (後ろの 2 つ) でだけ見つかったときは ⚠ で、そのディレクトリをユーザーの `Path` に足すよう ※ で出す
- `7.6.0` より古い (7.4 (LTS) と 7.5 は 2026-11-10 でサポートが終わった。dotfiles の PowerShell のテストも 7.6 で流す)・版が読めない
  ときは ⚠ (※ の手順で、入れた形のまま上げるか、外してから流し直す)
- 入っていなければ、固定した版 (`-PwshVersion`) を winget で入れる。普段のアカウントが管理者の PC は MSIX (ユーザー単位に入るので UAC は
  出ない)、管理者でない PC は MSI (下の「管理者でない PC」)。入れた直後に `winget pin add --id Microsoft.PowerShell --exact --version 7.6.*` を
  足す (7.6 の線に留める gating の pin。`winget upgrade --all` は 7.6 の中でだけ上げる)。ほかの形で入っていた PowerShell 7 には pin を足さない
- 7.6 の MSIX は package `Microsoft.PowerShell-LTS` で、Microsoft Store の「PowerShell-LTS」と同じ。Store の自動更新が 7.6 の新しい版へ
  上げうる (winget の pin は Store の更新を止めない)。7.7 からの MSIX は別の package `Microsoft.PowerShell` (Store の「PowerShell」と同じ)
  なので、7.6 の MSIX がそちらへ上がることは無い。2 つが並んで入ると実行エイリアス `pwsh.exe` を取り合う (設定 → アプリ → アプリの
  詳細設定 → アプリ実行エイリアス で、どちらを使うかを選ぶ)

管理者でない PC (普段のアカウントが管理者でなく、UAC の確認で別の管理者のアカウントの資格情報を入れる PC):

- 普段のアカウントが管理者かは、今のトークンのグループの SID (`WindowsIdentity` の Claims の `groupsid` と `denyonlysid`) に
  BUILTIN\Administrators (`S-1-5-32-544`) があるかで決める。UAC で権限を落とした管理者のトークンにも deny-only のグループとして入るので、
  管理者とみなす。読めなければ管理者でないとみなす (MSI はどちらの PC でも動く)
- 管理者でない PC では、UAC で昇格した側が別の管理者のアカウントになり、その側では MSIX の pwsh を起こせない ([PowerShell 7 の MSIX の限り](#powershell-7-の-msix-の限り))。
  そのため PowerShell 7 は MSI (マシン単位。どのアカウントからも起こせる) で入れる。per-machine の MSI なので `--silent` を付けず、UAC で
  管理者の資格情報を入れる。MSI には `USE_MU=0 ENABLE_MU=0` を渡し、Microsoft Update の更新に入れない (どちらも既定は 1。版の線は winget の
  pin で留め、Windows Update の設定にも触らない)
- PowerShell 7 が MSIX でしか見つからない (PATH のディレクトリと MSI の置き場所に MSIX でない pwsh が無い) ときは、表の行を ⚠ (入っていない
  もの。`-Check` の終了コード 3) にし、見つかった版と入れ方・MSI も入れること・そのわけを出す。引数なしで流すと MSI を足す (MSIX が古い・PATH の
  外でも、MSI の置き場所はマシンの PATH に入り、新しい窓ではユーザーの PATH の実行エイリアスより先に当たる)。このときだけ `--force` を付けて直に
  入れる: winget の install は、入っている package (MSIX も `Microsoft.PowerShell` に結ばれる) が見つかると upgrade に替わり、`--version` が入って
  いる版より新しくなければ止まり、新しくても入れ方 (MSIX → MSI) を替えない (`winget install --help` の文: 既定では入っているかを見て upgrade を
  試み、`--force` で直に入れる)。入っていない PC には付けない (`--force` は、安全に関わらない問題も越えて続ける意味も持つ)
- MSIX と MSI が並んで入っていても、入れた直後の `winget pin add --id Microsoft.PowerShell --exact --version 7.6.*` は落ちない (`--id` を渡した
  pin add は入っているものを探さず、available の package に付ける。winget-cli の PinCommand.cpp)。7.7 には MSI が無いので、MSI が 7.7 へ上がることも無い
- 普段のアカウントが管理者の PC は、今までどおり入れ方を問わず認める (MSIX だけでも揃っている。昇格しても同じアカウントなので、MSIX の pwsh を起こせる)

#### PowerShell 7 の MSIX の限り

MSIX は使う人ごとに登録され、実体は `C:\Program Files\WindowsApps\<package>\` の下にある (版が変わると置き場所も変わり、決まった入口は
実行エイリアスだけ)。

- 登録の無いアカウント (SYSTEM・サービス・別のユーザー) からは見えない。実行エイリアスはその人の `%LOCALAPPDATA%` にあり、WindowsApps の
  下の実体も、package の登録の無いアカウントでは起こせない見込み (package の置き場所は、その package として動くプロセスにだけ実行を許す)
- `Install-OpenSSH`・`Install-Sshd` は、自分を UAC で昇格し直す。同じアカウントのまま昇格すれば MSIX の pwsh でも動くが、UAC の確認で別の
  管理者のアカウントの資格情報を入れる PC (普段のアカウントが管理者でない) では、昇格した側で MSIX の pwsh を起こせない。そのため、昇格し直す
  host を次のように選ぶ:

  | 今の pwsh | MSI の pwsh (`C:\Program Files\PowerShell\7\pwsh.exe`) | 普段のアカウント | 昇格し直す host |
  | --- | --- | --- | --- |
  | MSIX (WindowsApps の下) | ある | 問わない | MSI の pwsh |
  | MSIX | 無い | 管理者 | 今の pwsh (MSIX) |
  | MSIX | 無い | 管理者でない | 起こさない (UAC を出さずに止め、bootstrap を流し直すよう ※ で出す) |
  | MSI・Windows PowerShell 5.1・ほかの pwsh | 問わない | 問わない | 今の pwsh |

  管理者でない PC には bootstrap が MSI を入れる ([PowerShell 7 (入れ方を問わず認める)](#powershell-7-入れ方を問わず認める))。bootstrap を
  流さない PC (WSL の setup で揃える PC など) は、MSI を手で足し、新しい窓で流し直す。MSI の置き場所はマシンの PATH に入り、新しい窓では
  ユーザーの PATH の実行エイリアスより先に当たる:

  ```powershell
  winget install --id Microsoft.PowerShell --exact --source winget --version 7.6.10.0 --installer-type wix --custom "USE_MU=0 ENABLE_MU=0" --force   # UAC が出る
  ```

  `--force` を付けるのは、入っている MSIX があると、winget が install を upgrade に替えて止まるため (MSIX から MSI へは替えない。`winget install --help`
  の文: 既定では入っているかを見て upgrade を試み、`--force` で直に入れる)

- 昇格した側 (UAC で資格情報を入れた別の管理者のアカウント) には、winget (App Installer) が登録されていないことがある。winget は Windows に
  サインインしたときに使う人ごとに登録されるので、その PC に一度もサインインしていないアカウントには無い。`Install-OpenSSH` (winget の
  install・upgrade) と `Install-Sshd` (winget download) は、昇格した側で winget が見つからなければ、そのアカウントと手をログに ※ で書いて
  止まる (登録はしない。別のアカウントの状態を変えるため)。手は、そのアカウントでその PC に一度サインインするか、そのアカウントの管理者の
  PowerShell (Windows PowerShell を「管理者として実行」で開き、UAC でそのアカウントの資格情報を入れる) で次を打つ (Microsoft の winget の文書の手):

  ```powershell
  Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe
  ```

- MSIX の pwsh からは DISM の cmdlet (`Add-WindowsCapability`・`Remove-WindowsCapability`・`Enable-WindowsOptionalFeature` など) が
  `Class not registered` で落ちる。dotfiles の script はこれらを打たない。※ で「管理者の PowerShell で打つ」と案内するものは、管理者の
  Windows PowerShell (5.1) で打つ
- `$PSHOME` (WindowsApps の下) には書けない。dotfiles が使う `$PROFILE` (CurrentUserCurrentHost) はドキュメントの下なので影響しない

### 版のずれを手で揃える

固定した版を上げた PR が merge された後、入っている Windows では `-Check` が版のずれを ⚠ で出す (runner の `dotfiles check` も、bootstrap の
手順の行で同じずれを出す)。揃えるのは Rust の runner の受け持ちだが、今の runner は見せるだけで揃える手順はまだ無いので、それまでは手で
揃える。bootstrap が足した pin があるので、版を名指しした upgrade には `--include-pinned` を付ける (付けないと pin に止められ、終了コード
`0x8A150068` で落ちる。[winget の pin](#winget-の-pin)):

```powershell
winget upgrade --id Git.Git --exact --version <版> --include-pinned
winget upgrade --id GitHub.cli --exact --version <版> --include-pinned                       # -Private で入れた PC だけ
winget upgrade --id Microsoft.VisualStudio.2022.BuildTools --exact --version <版> --include-pinned   # UAC が出る
winget upgrade --id Rustlang.Rustup --exact --version <版> --include-pinned --custom "--default-host x86_64-pc-windows-msvc --default-toolchain none"
```

- pin は付いたまま残る (上げた後に足し直さなくてよい)。bootstrap の `-Check` の ※ の行も、同じコマンドを出す
- 下げるときは `winget uninstall --id <ID>` の後に bootstrap を流し直す (固定した版で入れ直す)
- Git・gh は、使っているプロセス (Git Bash・Windows の Claude Code の会話など) を閉じてから
- PowerShell 7 は版を揃えない (`7.6.0` より古くなければよい。[PowerShell 7 (入れ方を問わず認める)](#powershell-7-入れ方を問わず認める))。
  `7.6.0` より古いときは、bootstrap の ※ の行のとおり、入れた形のまま上げるか、外してから流し直す

### bootstrap の固定した版の新しい版が出たとき

5 つの版も、ほかの Windows のアプリと同じく新しい版の知らせに乗る ([winget の新しい版を確かめる](#winget-の新しい版を確かめる)・
[固定した版より新しい版の知らせ](#固定した版より新しい版の知らせ))。setup の手順 97 の知らせは、Windows の ghq に dotfiles の clone がある
(bootstrap を流した) マシンでだけ出る。

- 出た日は、`git` が GitHub (`git-for-windows/git`) の release (tag `v<X.Y.Z>.windows.<N>` を winget の版 `X.Y.Z` (N が 1) か `X.Y.Z.N` に
  突き合わせる)、`gh` が GitHub (`cli/cli`) の release、`pwsh`・`vs-buildtools`・`rustup` が winget-pkgs に載った日
- `pwsh` (PowerShell 7) は 7.6 の線 (`7.6.` で始まる版) だけを読む (`nix/scripts/check-winget-version.sh` の `series_re`)。7.7 からの版は MSI が
  無く、MSIX は別の package (`Microsoft.PowerShell`) なので、bootstrap が入れる 7.6 (管理者の PC は MSIX の `Microsoft.PowerShell-LTS`、管理者で
  ない PC は MSI) の上げ先にならず、見送りの一覧に書かなくても知らせない。上げた版は、PowerShell 7 の入っていない Windows に bootstrap が入れる
  版になる (入っている Windows の PowerShell 7 は揃えない)。次の LTS などに移すときは、その版の MSIX の package の名前 (winget-pkgs の manifest の
  `PackageFamilyName`) と MSI があるか (管理者でない PC に入れる) を確かめ、`series_re`・
  runner の `WingetSpec` の `series`・固定した版を一緒に上げる (入れた直後に足す pin の線は、固定した版から決まる)
- 上げるとき: release notes を読み、`bootstrap/Install-Bootstrap.ps1` の名前ごとの param の既定値と、上の道具の表の版 (PowerShell 7 は
  「PowerShell 7 の MSIX の限り」の MSI のコマンドの版も) を新しい版にし、
  `Install-Bootstrap.Tests.ps1` を流して PR を出す (`winget-versions` が、書いた版が winget にあるかを確かめる)。Build Tools はワークロードと
  部品の ID (`Workload.VCTools`・`VC.Tools.x86.x64`・`Windows11SDK.26100`) が残っているか、rustup は `--default-host`・
  `--default-toolchain none` と自己更新の止めが効くかも見る
- 見送るとき: `bootstrap/skipped-versions/<名前>.txt` に「版 理由」を 1 行足して commit する

### Install-Bootstrap.ps1 を書くときの注意

- BOM 付きの UTF-8 で保存する。新しい Windows には Windows PowerShell 5.1 しか無いので、PowerShell 7 にしか無い書き方 (`??`・`?.`・
  三項演算子・`&&`・`||`・`-AsHashtable`・3 引数の `Join-Path`) を使わない (`Install-Bootstrap.Tests.ps1` が見る)
- winget の出力は UTF-8 で読む (`Invoke-Winget` が `Invoke-Native -Utf8` を通す)。bootstrap を流す Windows PowerShell 5.1 の窓は、日本語の Windows では
  コンソールの文字コードが CP932 で、そのまま読むと進み具合の帯 (█▒) が「笆遺毎」に化けて除けず、日本語のメッセージ (取り消しの「…: 1602」も) が化ける
- `Start-Process` に `-Wait` を付けない (5.1 の `-Wait` は子孫のプロセスまで待つ)。`-PassThru` で handle を掴んで `WaitForExit()` で待つ (試験が見る)
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

- 受け持ちはホストごとに一度に切り替える ([後述](#受け持ちを-runner-に切り替える))。切り替えるまでは、WSL の setup と同じ手順 (files・
  `Install-*.ps1`・`$PROFILE` の 1 行など) は今までどおり WSL の setup が配り ([配る](#配る))、runner は `dotfiles check` で確かめるだけ (同じ commit の clone なら、WSL と
  同じ判定を出すかを突き合わせられる)。Windows にしか無い手順 (claude-skills を Windows の Claude Code で使う W0-2 の手順など。[後述](#claude-skills-と-windows-のハブ-w0-2))
  は、WSL の setup が Windows に配らないので、受け持ちによらず runner の `dotfiles apply` が流す (dotfiles-private の ADR 064 (`docs/adr/064_win_w02_claude_skills_hub_*`))
- 流すのは、bootstrap が clone した dotfiles (`%USERPROFILE%\ghq\github.com\pollenjp\dotfiles`) の HEAD の runner に合う exe。PowerShell の
  `dotfiles` 関数 (`powershell/dotfiles.ps1`) が clone の launcher (`powershell/Invoke-DotfilesRunner.ps1`) を呼び、launcher が CI の作った exe を
  GitHub の Release から落として起こす (合う exe が無ければ、cargo があれば `win\runner` で `cargo run --quiet --release --locked` で build する。
  [後述](#runner-の-exe-release))。clone を pull すれば、次の呼び出しから新しい clone に合う exe で動く。runner は clone を取得しない。3 つの clone を
  進めるのは `dotfiles --self-update` ([後述](#clone-を進める-dotfiles---self-update))

### runner を流す

```powershell
dotfiles --self-update apply           # 3 つの clone を進めてから揃える (後ろの引数は runner に渡す。下の「clone を進める」)
dotfiles list                          # 手順と、このホストでの on/off・runner に移したか
dotfiles check                         # 手順を順に確かめる (何も書かない)
dotfiles check --steps files,ntn       # 手順を id で絞る (PowerShell が配列にした files,ntn は dotfiles 関数が , でつなぎ直す)
dotfiles apply --dry-run               # apply がすることを出す (何も書かない。受け持ちによらず流せる)
dotfiles apply                         # 揃える (受け持ちが WSL のホストでは Windows にしか無い手順だけ。ホストの値が無い・2 つあれば止まって 1)
dotfiles apply --steps files --force   # files の衝突 (Windows 側で変わっていた) も上書きする
dotfiles import terminal               # Windows Terminal の衝突したキーの値を managed.json へ取り込む (受け持ちが runner のホストだけ)
dotfiles import fancyzones '4k-43inch' # PC の FancyZones のレイアウトを名前で選び、repo へ写す (同上。名前は繰り返せる)
dotfiles import international          # 日付と時刻の形式の衝突した値を managed.json へ取り込む (同上)
dotfiles import google-ime             # Google 日本語入力の設定と辞書をテキストへ取り込む (同上)
dotfiles check --steps google-ime --show-words  # Google 日本語入力の辞書の衝突で語の diff も出す (自分の端末で打つ)
dotfiles manifest                      # manifest.toml を検証する (--json は置き先を解いた計画)
```

- 最後に手順ごとの表 (⚠ = 直すことがある・✔ = 揃っている・↷ = このホストでは off・· = 知らせるだけ (runner にまだ無い・受け持ちは WSL の setup・前提がまだ無いので流さない・固定した版より新しい版がある (`pin-updates`))) と、種類ごとの締めの行を出す
- 出す先が端末なら色を付ける (nix の setup.sh と同じ割り当て: ⚠ の行と ⚠️ の締めの行は太い黄 (落ちた・止めたものは赤)・runner が動けないときと
  `dotfiles manifest` の誤りの stderr の `!!` の行は赤・✔ は緑・↷ と · は薄く・見出しは太字・手順の途中の `!!` の行は黄。※ の行と pwsh の手順の出力には
  付けない)。パイプやファイルに流すときと、環境変数 `NO_COLOR` が空でないときは付けない (色の字が `←[1;33m` のように化ける端末では `$env:NO_COLOR = '1'`)
- 終了コードは bootstrap と同じ: 0 = 直すことが無い・3 = 入っていない・無いものだけ (apply で揃う)・1 = ほかに直すことがある (足りない・
  ずれている・runner では直らない差・落ちた手順・apply を止めた)・2 = runner が動けない (引数・ホストの値・`groups.json` の誤り、Windows の
  環境変数が無い)
- 1 つの手順が落ちても、残りの手順も流す (ps1 は clone の中のものを呼ぶので、files に頼らない。WSL の setup は files の衝突で後ろを止める)
- 受け持ちが WSL のホストの apply は、Windows にしか無い手順 (`dotfiles list` の「(Windows だけ)」) だけを流し、WSL の setup と同じ手順は流さずに
  `·` の行 (受け持ちは WSL の setup) を出す。選んだ手順 (`--steps`) に Windows にしか無い手順が無ければ止まる (1)。WSL の setup と同じ手順に直すことが
  あれば、締めの行の下に WSL の `~/dotfiles/setup --update` で揃える道を添える (files・ssh-config・port-forward・terminal・fancyzones・international・google-ime の衝突の解き方と、powershell-profile の消した 1 行の足し直しも、WSL の `bootstrap-windows-*.sh --force` (取り込みは `--import`) を出す)
- `dotfiles import <id>` は、WSL の script の `--import` を写したもの (`terminal`・`fancyzones`・`international`・`google-ime`)。Windows 側の値を repo のファイルへ写し、PC の設定の
  ファイル (settings.json など) やレジストリには書かない (terminal・international・google-ime は runner の記録を取り込んだ値にする。WSL の `--import` も記録は書く)。repo のファイルに commit して
  いない変更があると止まる。`-` で始まるレイアウトの名前は `--` の後ろに書く。受け持ちが WSL のホストでは止まり (1)、WSL の script の `--import` を出す
- `--show-words` (check と apply) は、google-ime の辞書の衝突で語の diff も出す (付けなければ辞書ごとの行の数だけ)。辞書の語が出るので、自分の端末で打つ
  (Claude などのログに残る場所では流さない)

### clone を進める (`dotfiles --self-update`)

runner は clone を取得しない。dotfiles・dotfiles-private・claude-skills の 3 つの clone を進めるのは、PowerShell の `dotfiles --self-update`
(Linux の `~/dotfiles/setup --self-update` に当たる。経緯は dotfiles-private の ADR 104 (`docs/adr/104_win_dotfiles_self_update_*`)・
gh にログインできない PC の扱いは ADR 111 (`docs/adr/111_win_runner_without_gh_*`))。

```powershell
dotfiles --self-update                          # 3 つの clone を fetch して fast-forward する
dotfiles --self-update apply                    # 進めてから dotfiles apply (後ろの引数は、そのまま runner に渡す)
dotfiles --self-update check --steps files,ntn  # 進めてから dotfiles check --steps files,ntn
dotfiles --self-update --dry-run                # fetch して、進める commit を出すだけ (fast-forward も runner もしない)
dotfiles --self-update apply --dry-run          # 進めてから dotfiles apply --dry-run (後ろの --dry-run は runner のもの)
```

- 進めるのは `%USERPROFILE%\ghq\github.com\pollenjp\` の 3 つの clone (bootstrap が clone する所)。今の branch を upstream から fetch して fast-forward し、
  clone ごとに進めた commit を出す (新しい順に 15 まで)。GitHub の remote は gh の資格情報 (HTTPS) で通し (bootstrap の clone と同じ組。SSH の鍵は使わず、
  origin の URL も git の設定も書き換えない)、git にも Git Credential Manager にも対話のプロンプトを出させない (資格情報が無ければ、待たずに ⚠ になる)
- gh が無い PC (既定の形の bootstrap で揃えた PC) は、GitHub の remote を資格情報なしの HTTPS で取る (見出しにそう出る)。public な dotfiles は取れる。
  gh があってログインしていなくても、public な repo は資格情報を求められないので匿名で取れる
- private な repo (dotfiles-private・claude-skills) の clone が無いのは、「このホストでは使わない」の `·` にし、終了コードを変えない (締めの ⚠️ の行にも
  出さない)。使う PC は `-Private` の bootstrap で clone する。dotfiles の clone が無いのは ⚠
- 未 commit の変更がある (未追跡のファイルは数えない)・detached HEAD・upstream が無い・fetch が落ちた・fast-forward できない (ローカルにだけ commit が
  ある・進めると上書きされる未追跡のファイルがある)・clone が無い (dotfiles)・git の repo でない clone は、⚠ で直し方を出して進めず、ほかの clone と runner は続ける
  (Linux の setup と同じ扱い)。runner を流したら、⚠ は runner の出力の後にもう一度出す
- `--self-update` は最初の引数に書く。`--dry-run` (と `-h`・`--help`) は `--self-update` の直後に書き、runner のコマンド (`apply` など) から後ろはそのまま
  runner に渡す (runner の option を runner のコマンドより前に書くと、何もせずに止まる)。`--self-update --dry-run` も fetch はする (remote-tracking の ref
  だけが進み、branch と作業ツリーは動かない)
- 終了コード: runner の終了コード (runner の引数が無ければ 0)。進めなかった clone があれば、0 と 3 を 1 にする。引数の誤り・runner が無いときは 2
- `dotfiles.ps1` が変わったら、締めに新しい PowerShell を開くよう出す (開いている PowerShell の関数・略語・キーの割り当ては、開いたときに読んだ古いまま)。
  配った写し (`%USERPROFILE%\.config\powershell\dotfiles.ps1`) がまだ古ければ、先に配るよう添える (受け持ちが runner のホストは `dotfiles apply`、WSL の
  ホストは WSL の `~/dotfiles/setup --self-update --update`。WSL は WSL の clone から配る)
- 中身は clone の中の `powershell/Invoke-DotfilesSelfUpdate.ps1` (配らない)。`dotfiles` 関数は配った写しでなく clone の中のものを呼ぶので、更新の処理を直した
  pull は、開いている PowerShell の関数が古いままでも、次の `dotfiles --self-update` から効く (その回は、pull する前に読み込んだ script のまま流れる)。runner は
  進めた後の clone の launcher で起こすので、進めた後の clone に合う exe で動く (合う exe がまだ無ければ cargo で build する。[runner の exe (Release)](#runner-の-exe-release))

`--self-update` を知らない古い `dotfiles` 関数 (この節を足す前に開いた PowerShell・配った写しがまだ古い PC) では、runner が「`--self-update` は PowerShell の
dotfiles 関数が受け持つが、…古いもの」(runner も古ければ「知らないコマンドです: --self-update」) で止まる。そのときは一度だけ手で進めて配る:

```powershell
foreach ($r in 'dotfiles', 'dotfiles-private', 'claude-skills') {
    git -c url.https://github.com/.insteadOf=git@github.com: -c credential.helper= -c 'credential.helper=!gh auth git-credential' `
        -C "$HOME\ghq\github.com\pollenjp\$r" pull --ff-only
}
dotfiles apply                     # dotfiles.ps1 を配る (受け持ちが WSL のホストは、WSL で ~/dotfiles/setup --self-update --update)
# 新しい PowerShell を開いて
dotfiles --self-update --dry-run   # 3 つの clone が最新と出る
```

### runner の exe (Release)

runner の exe は CI ([`.github/workflows/win-runner-release.yml`](../.github/workflows/win-runner-release.yml)) が作り、public な dotfiles の GitHub の
Release に置く。PowerShell の `dotfiles` 関数は、clone の launcher (`powershell/Invoke-DotfilesRunner.ps1`。配らない。clone のものを呼ぶ) で、clone の
HEAD の runner に合う exe を落として起こす。minimum の PC に Visual Studio Build Tools と rustup が要らない (経緯は dotfiles-private の ADR 117
(`docs/adr/117_win_runner_exe_release_*`))。

- **key**: clone の HEAD の `win/runner` の git の tree の hash (`git rev-parse HEAD:win/runner`)。exe の中身は `win/runner` の中身だけで決まる
  (runner は `win/runner` の外のファイルを exe に埋めない。外のファイルは動くときに clone から読む。`runner/tests/embeds.rs` が見る)
- **Release**: tag `win-runner-<key の頭 12 字>` (prerelease)。asset は `dotfiles-win.exe` (C ランタイムを静的にリンク。key と作った commit を埋める) と
  `dotfiles-win.exe.sha256` (`<64 字の 16 進>  dotfiles-win.exe`)。URL は `https://github.com/pollenjp/dotfiles/releases/download/<tag>/<asset>` で、
  launcher は REST API を呼ばない
- **置き場**: `%LOCALAPPDATA%\dotfiles\runner\<key>\` に exe と `.sha256` を置き、exe が `dotfiles-win.exe version` で名乗る key を確かめたら印
  `verified` (頭は確かめた exe の sha256。exe を替えたら確かめ直す) を置く。新しい方から 3 つの key のディレクトリを残し、ほかは消す。片方だけが
  残っている置き場 (exe だけを手で置いた・消しかけて止まった) は、落とした物で両方を置き換える
- **確かめ方**: 落とした exe の sha256 を `.sha256` と比べ、合うときだけ置く。置いた後に 1 回だけ `version` を打って key を比べる (起こせなければ、
  ここで Smart App Control などに止められたと分かる)。key を埋めた exe は、clone の HEAD の `win/runner` が自分の key と違えば流さない (終了コード 2)
- **来歴**: CI は exe に build の attestation を作る。gh のある PC で `gh attestation verify dotfiles-win.exe -R pollenjp/dotfiles` を打てば、どの
  workflow がどの commit から作ったかを確かめられる (launcher は確かめない。gh か cosign が要るため)
- launcher は runner の引数の 1 つ目 (コマンド) の直後に `--repo <clone>` を差し込む。Release の exe の既定の clone も
  `%USERPROFILE%\ghq\github.com\pollenjp\dotfiles` (手元の build の既定は build した clone)
- `Invoke-WebRequest -OutFile` で落とすので Mark of the Web は付かず、SmartScreen も出ない。手で置いた物 (ブラウザーで落とした物) のために、sha256 を
  確かめた後に `Unblock-File` を打つ。exe は署名していないので、Smart App Control がオンの PC では止められる (cargo の産物と同じ。オフにする)

選び方 (環境変数 `DOTFILES_RUNNER`。空なら自動):

| 場面 | 自動 (空) | `exe` | `cargo` |
| --- | --- | --- | --- |
| HEAD の key の exe が置き場にある | 起こす | 起こす | `win\runner` で `cargo run` |
| 置き場に無い | 落として確かめてから起こす | 同じ | 同じ |
| `win/runner` に commit していない変更がある (手元で直している) | cargo があれば build する (1 行知らせる)。無ければ ⚠ を出して HEAD の exe で流す (変更は効かない) | ⚠ を出して HEAD の exe | 同じ |
| 落とせない (Release が無い (404)・つながらない) | cargo があれば build する (1 行知らせる)。無ければ直し方を出して止まる (終了コード 2) | 止まる | 同じ |
| exe を起こせない・`version` が 0 でなく終わった (Smart App Control・App Control・AppLocker に止められた・DLL が無い) | cargo があれば build する (1 行知らせる。`%LOCALAPPDATA%` の exe を止める決まりでも、clone の中で作った exe は通ることがある)。無ければわけを出して止まる | 止まる | 同じ |
| sha256・key が合わない・置き場の中身が `.sha256` と合わない | cargo があっても build に戻らずに止まる (終了コード 2。置き場を消して打ち直すと落とし直す) | 同じ | 同じ |

- Release が無いのは、merge の直後で CI がまだ作り終えていない (数分待つ)・clone が古く、その key の Release が消えた (`dotfiles --self-update` で
  進める)・`win/runner` を変えた commit が手元にある (push して merge するか、`Install-Bootstrap.ps1 -Rust` で build できるようにする) のどれか
- 配った exe を使えずに cargo へ回り、cargo が終了コード 101 で終わったら (Build Tools が無く build できないなど)、上の直し方を出す。rustup だけが
  入っていて Build Tools の無い PC (前の bootstrap が Build Tools で落ちた PC) は、rustup を外すと、cargo へ回らずに直し方がすぐ出る
- github.com に届かない PC は、別の PC で落とした 2 つのファイル (`dotfiles-win.exe` と `dotfiles-win.exe.sha256`) を、置き場の key のディレクトリに
  置けば使う (sha256 と key は確かめる)。PR の exe を試すときも同じ手 (gh のある PC で PR の CI の artifact `dotfiles-win-<key>` を
  `gh run download` で落とし、試す PC の clone を PR の branch にして、artifact の名前の key のディレクトリに置く。PR の CI は PR の head を build
  するので、artifact の key は PR の branch の `git rev-parse HEAD:win/runner` と同じ)

公開 (CI):

- build の job (書けない token) が作って確かめ (Visual C++ の runtime の DLL を読まない・`version` の key・雛形のホストの値の `list`・launcher の通しの
  試験 (`.github/scripts/win-runner-e2e.ps1`))、artifact に上げる。公開の job (書ける token) が artifact を落とし、attestation を作って Release を
  作る (`.github/scripts/win-runner-publish.sh`)。PR では公開せず、公開の script を `--dry-run` で流す
- 公開の job が動くのは、repo の変数 `WIN_RUNNER_PUBLISH` が `true` の main の push か、main での手動の実行 (Actions の画面の「Run workflow」で
  `publish` に印) のときだけ。最初の Release は手動の実行で作り、PC で確かめてから変数を入れる
  (`gh variable set WIN_RUNNER_PUBLISH --body true -R pollenjp/dotfiles`)
- 同じ key の Release があれば作らない (launcher・workflow だけを変えた push・revert で同じ中身に戻った push)。公開してある exe と `.sha256` が合うかだけを
  見る (今回の build とはバイトで比べない。exe に作った commit を埋め、link の時刻・image の C ランタイムでも変わるので、同じ key でも build は再現しない)
- tag は、main の commit を親にした Release 用の commit に付ける (main の外なので、clone の `git fetch` は tag を拾わない)
- 30 日より古い `win-runner-` の Release は、新しい方から 20 本を残して消す (tag も)
- repo の設定の immutable releases を入れると、公開した exe・`.sha256`・tag を差し替えられなくなる。そのとき、消した Release の tag の名前は二度と使えない
  ので、30 日より後に同じ中身へ戻ると、その key の Release は作れない (公開の job が落ちる)。cargo の無い PC は、`win/runner` を 1 行変えて別の key に
  するまで、その commit では止まる (めったに起きない)

### ホストの値

runner は、ホストの値を次の順に引く (経緯は dotfiles-private の ADR 111 (`docs/adr/111_win_runner_without_gh_*`)):

1. `--host-file <path>` (渡したとき。ほかは見ない)
2. 手元の `%USERPROFILE%\.config\dotfiles\host.toml`。gh にログインできない PC (pollenjp の private な repo を取れない PC) のホストの値で、引数なしの
   bootstrap が雛形 `templates/host.minimum.toml` (設定グループ minimum だけの値・受け持ちは runner) を写す。その PC にだけあり、repo には戻さない
3. dotfiles-private の `win/hosts/<Windows のユーザー名>@<PC の名前>.toml` (`<PC の名前>` は `hostname` を小文字にしたもの。example-host なら
   `alice@example-host.toml`)。登録したホスト (`-Private` で揃えた PC) のホストの値

- 2 と 3 の両方があれば、`check` は 2 の値で確かめて ⚠ (ホストの値が 2 つある) を出し、`apply` は止まる (どちらを使うか決まらないので)。使わない方を
  退ける (`--host-file` でどちらかを渡せば、その 1 つだけを読む)
- どちらも無ければ、`check` は ⚠ を出してグループ minimum の既定で確かめ、`apply` は止まる (行に 2 つの置き場を出す)

ホストの値は WSL の Nix のホスト (`nix/hosts/<user>@<hostname>.nix`) に当たる。

```toml
group = "minimum"             # minimum (既定)・all (nix/README.md の「設定グループ」)

[tools]                       # 道具の switch。書かなければグループの既定 (runner/groups.json。minimum では false)
windowsClaudeCode = true
windowsTypeClipboard = true
privateRepos = true           # pollenjp の private な repo と gh のログインを使う PC (-Private で bootstrap を流した PC) だけ

[runner]
enable = false                # 受け持ちの印。true で WSL の setup と同じ手順も apply で書く

[opReason]                    # op-reason の SSH の中継のモード (効くのは [tools] opReasonSshRelay = true のとき)
sshRelayMode = "per-call"     # per-call (既定)・show-only

[sshd]                        # sshd の値 (使うのは受け持ちが runner で [tools] windowsSshd = true のホストだけ)
authorizedKeys = [            # 入れる公開鍵。authorized_keys の 1 行を 1 つの文字列で。書かなければ null (鍵を置かない)・[] は 0 本
  'from="100.64.0.1,fd7a:115c:a1e0::1" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... herdr@phone',
]
allowUsers = ["alice"]        # AllowUsers に書くユーザー。書かなければ null (Install-Sshd を流したユーザー)・[] は誰も入れない
allowFrom = ["100.64.0.0/10", "fd7a:115c:a1e0::/48", "127.0.0.1", "::1"]   # 入ってよい送り元。書かなければ null (tailnet と localhost)・[] はどこからも入れない

[t3Code]                      # T3 Code の Claude の手当て (効くのは [tools] windowsT3Code = true のとき)
clearClaudeEntrypoint = true  # CLAUDE_CODE_ENTRYPOINT="" を渡す (既定 false。クレジットを使う間だけ)

[claude.notion]               # Notion へ書く skill の宛先 (Nix の dotfiles.claude.notion と同じ名前と形)
profile = "personal"          # このマシンの既定のプロファイル (書かなければ null)
routes = { "pollenjp/some-repo" = "work" }   # このマシンだけの宛先の規則 (書かなければ空)

[claude.notion.override.personal]            # プロファイルの値を、このマシンだけ差し替える (書かなければ空)
scanData = "https://app.notion.com/p/…"

[claude.notion.tokens.personal]              # このマシンで Notion の API キーを使うプロファイルと種類 (Nix の dotfiles.claude.notion.tokens と同じ名前と形。書かなければ空)
kind = "personal"                            # integration (integration の API キー)・personal (個人用アクセストークン)
item = "op://<vault の ID>/<項目の ID>/<欄の ID>"   # 元の値の 1Password の参照 (欄まで。値ではない)。書かなければ null

[claude.tokens.alt]                          # この PC のアカウント alt に置いた claude setup-token の token (Nix の dotfiles.claude.tokens と同じ名前と形。書かなければ空)
label = "alt"                                # token の呼び名 (同じ token を置いたホスト・アカウントで同じにする)。書かなければアカウントの名前
item = "op://<vault の ID>/<項目の ID>/<欄の ID>"   # 元の token の 1Password の参照 (欄まで。値ではない)。書かなければ null
```

- 書けるのは `group`・`[tools]`・`[runner] enable`・`[opReason] sshRelayMode`・`[sshd]` (`authorizedKeys`・`allowUsers`・`allowFrom`)・`[t3Code] clearClaudeEntrypoint`・`[claude.notion]` (`profile`・`routes`・`override`・`tokens`)・`[claude.tokens]` (`label`・`item`) だけ。道具の名前は `group.json` の `tools` と同じ
  (runner が使うのは `windowsClaudeCode`・`windowsClaudeAccounts`・`windowsClaudeDesktop`・`windowsHerdr`・`windowsNtn`・`windowsCodex`・`windowsTypeClipboard`・`windowsOpenssh`・`windowsTailscale`・`windowsSshd`・`windowsT3Code`・`claudePrivateSkills`・`herdrHub`・`devTracker`・`gitIdentity` と、
  `op-reason` の on/off の `onePassword`、SSH の中継の `opReasonSshRelay`、runner だけが読む `privateRepos`)。知らないキー・名前・`sshRelayMode` の知らない値・`authorizedKeys` の読めない値・
  `allowUsers`・`allowFrom` の書けない値は runner が止める (終了コード 2)
- 道具の既定は設定グループで決まる (dotfiles-private の ADR 109)。グループは道具の集合で、`minimum` (既定) では runner が使う道具は全部 false、
  `all` では全部 true。ほとんどのホストは `group = "minimum"` にして、使う道具を `[tools]` に 1 つずつ `true` で書く (何に頼っているかが TOML で分かる)。
  前のグループ (`personal`・`company`・`client`) は、書き直すよう案内して runner が止める (終了コード 2)。前と同じにする行は、`personal` なら
  `windowsClaudeCode`・`windowsHerdr`・`windowsNtn`・`windowsClaudeAccounts`・`windowsClaudeDesktop`・`claudePrivateSkills`・`herdrHub`・`gitIdentity`、
  `company` なら `windowsClaudeCode`・`windowsHerdr` と、足していた道具 ([`nix/README.md` の「前のグループから移す」](../nix/README.md#前のグループから移す))
- 受け持ちが WSL のホストは、WSL の Nix の値で on にした道具と同じ値を `[tools]` に書く (Nix の `wsl.windowsFiles.claudeCode.enable` なら
  `windowsClaudeCode`、`claude.privateSkills.enable` なら `claudePrivateSkills`、`claude.devTracker.enable` なら `devTracker`、`onePassword.enable` なら
  `onePassword`、`git.identity.enable` なら `gitIdentity`、`wsl.windowsFiles.openssh.enable` なら `windowsOpenssh`、`wsl.windowsFiles.tailscale.enable` なら `windowsTailscale` など)
- `windowsClaudeAccounts` (claude-personal・claude-work) は初回の apply で UAC の確認が出る手順 ([後述](#claude-personalclaude-work))。
  `windowsClaudeDesktop` (Claude Desktop) も入れるときに UAC の確認が出る (WSL の setup には Claude Desktop の手順が無いので、受け持ちによらず
  TOML にだけ書く。[後述](#claude-desktop))
- `privateRepos` (pollenjp の private な repo (dotfiles-private・claude-skills) と gh のログインを使う PC か) は、Nix の option を持たない runner だけの道具
  (`nix/lib/groups.nix` の `runnerOnlyTools`)。minimum に入らず、all に入る。on の PC は bootstrap を `-Private` で流す (runner の手順 `bootstrap` も
  `-Check -Private` を流す)。off の PC では、private な repo か gh のログインを読む手順 (`ssh-config`・`port-forward`・`pin-updates`) を流さず (↷)、`google-ime` は
  辞書を扱わない (設定だけを置く)。off にしても、前に置いたファイル (`.ssh\config.d` の写し・`hosts.json`) は消さない
- `claudePrivateSkills`・`herdrHub`・`opReasonSshRelay` は `privateRepos` が要る (claude-skills の clone を読む・claude-skills の pjp でハブを作り mod を置く・
  中継のファイルを置く手順 `ssh-config` が dotfiles-private の `ssh/` を読む)。`privateRepos` が off なのにどれかが on なら、runner がどれがなぜ要るかを
  出して止める (終了コード 2)。グループ all で `privateRepos = false` を書くなら、3 つの `false` も書く
- `claudePrivateSkills` (claude-skills の clone を Windows の Claude Code で使うか) を書くと、手順 `claude-skills`・`local-env`・`pjp` が on になる
- `devTracker` を書くと、Windows の `CLAUDE.md` に「タスク管理」の節が入り、skillOverrides の `pjp-dev-tracker` が on になる ([後述](#claude-code-の設定))
- `onePassword` を書かなければ `op-reason` の行は off になり、runner は Windows の op-reason を確かめも入れもしない ([後述](#op-reason))
- `opReasonSshRelay` (op-reason の SSH の中継) を使うホスト (受け持ちを runner に切り替えたホストだけ) は、`[tools]` に `opReasonSshRelay = true` を
  書き (1Password の `onePassword = true` も要る)、WSL の Nix の値にも `dotfiles.opReason.sshRelay.enable = true` を書く。モードは
  `[opReason] sshRelayMode` (書かなければ per-call。WSL の `dotfiles.opReason.sshRelay.mode` と同じ値にする)。書かなければ、runner は中継の task と
  `IdentityAgent` のファイルを置かない (前に置いたものは消す。[後述](#ssh-の中継))
- `windowsOpenssh`・`windowsTailscale`・`windowsSshd`・`windowsTypeClipboard` を書かなければ、`openssh`・`tailscale`・`sshd`・`type-clipboard` の行は off
  ([OpenSSH](#openssh)・[Tailscale](#tailscale)・[sshd](#sshd)・[type-clipboard](#type-clipboard))。`openssh` が off なら Windows に初めからある OpenSSH の
  まま使う (固定した版に入れ替えない)
- `[sshd] authorizedKeys` は sshd に入れる公開鍵 (Nix の `wsl.windowsFiles.sshd.authorizedKeys` と同じ意味。[鍵の置き方](#鍵の置き方))。使うのは受け持ちが
  runner のホストだけで、runner の手順 `sshd` が Windows の `%LOCALAPPDATA%\dotfiles\sshd\authorized_keys` に写しを置く。書かなければ null で、写しを
  置かない (前の写しは消す)。`[]` は鍵 0 本 (誰も入れない)。1 つの文字列が authorized_keys の 1 行 (前に `from="…"` を付けてよい) で、改行を含む値・
  authorized_keys の行として読めない値 (鍵の種類と base64 が無い・`#` で始まる) は runner が止める。受け持ちが WSL のホストは WSL の setup が
  Nix の値から写しを置くので、TOML に書いても使わない (`sshd` の手順がそう 1 行出す)。実機の鍵と `from=` の IP は dotfiles-private にだけ書く
- `[sshd] allowUsers`・`allowFrom` は、sshd_config の `AllowUsers` に書くユーザーと、入ってよい送り元 (`Match Address` で絞る相手のアドレス)
  ([ユーザーと送り元](#ユーザーと送り元))。使うのは受け持ちが runner のホストだけで、runner の手順 `sshd` が Windows の
  `%LOCALAPPDATA%\dotfiles\sshd\allow.json` に写しを置き、`Install-Sshd` がそれを読む。書かなければ null で既定 (`Install-Sshd` を流したユーザー・
  tailnet と localhost)、`[]` は誰も・どこからも入れない。どちらも書かなければ写しを置かない (前の写しは消す)。`allowUsers` は英小文字・数字・`. _ -` の
  名前、`allowFrom` は IPv4・IPv6 のアドレスか CIDR (範囲の頭のアドレスで書く) だけで、ほかは runner が止める。受け持ちが WSL のホストは既定のまま
  (TOML に書いても使わない。Nix の値には無い)。実機のユーザー名と端末の IP は dotfiles-private にだけ書く
- `windowsCodex` は、Codex CLI を入れるホストが `[tools]` に `windowsCodex = true` を書く (WSL の setup には Codex CLI の手順が無いので、受け持ちに
  よらず TOML にだけ書く。書かなければ `codex` の行は off。UAC の確認は出ない。[後述](#codex-cli))
- `windowsT3Code` は、T3 Code を入れるホストが `[tools]` に `windowsT3Code = true` を書く (WSL の setup には T3 Code の
  手順が無いので、受け持ちによらず TOML にだけ書く。書かなければ `t3-code`・`t3-code-settings` の行は off。[後述](#t3-code))。Claude に
  `CLAUDE_CODE_ENTRYPOINT=""` を渡すかは `[t3Code] clearClaudeEntrypoint` (書かなければ false で、`t3-code-settings` が settings.json からその要素を外す)
- 上の「WSL の Nix の値と同じ値を書く」は、受け持ちが WSL のホストのこと。受け持ちを runner に切り替えたホストでは、Windows の道具の値
  (`windowsTypeClipboard`・`windowsTailscale`・`windowsSshd` など) は TOML にだけ書き、WSL の Nix の値の `wsl.windowsFiles.*` は外す
  ([受け持ちを runner に切り替える](#受け持ちを-runner-に切り替える))
- `[claude.notion]` は `claude-notion` の手順が `%USERPROFILE%\.local\state\dotfiles\claude-notion.json` に書く (Linux の home-manager が書くのと同じ中身)。
  runner が確かめるのは Nix の option と同じ型だけ (`profile` は `[a-z0-9][a-z0-9_-]*`・`routes` は文字列の表・`override` は表。日時は書けない)。
  プロファイルの名前やキーの綴りは、claude-skills の pjp-notion-profile が使うときに確かめる。TOML に null は無いので、`override` で値を消す形
  (Nix の `null`) は書けない
- `[claude.notion.tokens.<名前>]` (Notion の API キーの宣言) は `notion-tokens` の手順が `%USERPROFILE%\.local\state\dotfiles\notion-tokens.json` に
  書き、`~/.config/pjp/env` の行と ACL を確かめる。宣言の形は Nix の option と同じに runner が確かめ、`kind` と `item` に書いた字は止める文に出さない
  ([後述](#notion-の-api-キーの宣言-claudenotiontokens))
- `[claude.tokens.<名前>]` (claude の setup-token の token の置き場の宣言) は `claude-tokens` の手順が
  `%USERPROFILE%\.local\state\dotfiles\claude-tokens.json` に書く (`claude-account audit` が読む)。宣言の形は Nix の option と同じに runner が確かめ、
  名前・`label`・`item` に書いた字は止める文に出さない。素の claude の `default` は書けない ([後述](#claude-の-token-の置き場の宣言-claudetokens))
- dotfiles-private は、runner を build した dotfiles の clone の隣を探し、無ければ bootstrap の置き場 (`%USERPROFILE%\ghq\github.com\pollenjp\dotfiles-private`)
  を探す (一時の場所の clone から流しても見つかる)。どこを読んだかは出力の頭の「ホストの値:」に出る
- ホストの値が無い・2 つあるときの振る舞いは、この節の頭の「引く順」のとおり。別のファイルを使うなら `--host-file <path>`
- ホストの値から作った図のページ (グループ・道具の on/off と、その値がホストの値とグループの既定のどちらで決まったか。グループの入れ子の領域と
  ホストの囲みの線の HTML 版) は dotfiles-private の `docs/hosts/win/<ユーザー>@<PC>.md` にある (Notion にも写る)。ホストの値を足す・直すときは、
  同じ PR で WSL の `nix/scripts/private-host.sh summaries --private <dotfiles-private の作業ツリー>` を流して出し直す
  ([`nix/README.md`「ホストの要約」](../nix/README.md#ホストの要約)・skill `pjp-dotfiles-register-host`)。図に出す道具は、上の runner が使う道具
  (`nix/lib/groups.nix` の `runnerTools`。runner に道具を足したら、そこにも足す)
- `runner/groups.json` は生成物 (version 2。グループごとの道具の既定で、Nix が `nix/lib/groups.nix` の表から作る。`all` は全部 true)。表を
  変えたら、dotfiles の root で `nix eval --raw ./nix#lib.windowsGroupsJson > win/runner/groups.json` で出し直す (古ければ
  CI の `lint` が落ちる)

### 受け持ちを runner に切り替える

ホストごとに、dotfiles-private の同じ PR で 2 つを変える (同じものを WSL と Windows の両方が配らないように):

1. そのホストの Nix の値 (`nix/hosts/<user>@<hostname>.nix`) を `wsl.windowsFiles.enable = false` にする (WSL が Windows に触らない)。同じファイルの
   Windows の道具の switch (`wsl.windowsFiles.typeClipboard.enable`・`tailscale.enable`・`sshd.enable` など) は外し、値は 2 のファイルの `[tools]` にだけ
   書く。`typeClipboard.enable = true` を残すと、`windowsFiles.enable = false` では評価が止まる (assertion)。ほかは残しても効かない
2. Windows のホストの値を `[runner] enable = true` にする (runner の apply を許す)

- WSL の setup の Windows の手順は、後から足した `op-reason` まで全部 runner に移した (下の表に「まだ」の行は無い)。WSL の側に手順を足して runner に
  まだ無い間は「まだ」の行になり、切り替えたホストでは誰も流さないので ⚠ (runner では直らない差) になる。切り替えるのは、そのホストで on の手順を
  全部移してから (ADR 060)。切り替える前に `dotfiles check` を流し、WSL の setup と同じ判定になっていることを確かめる
- Windows にしか無い手順 (下の表の「有る (Windows だけ)」) は、切り替える前から apply で流れる (ホストの値は要る。`runner.enable = false` のままでよい)
- 初めて apply するときは記録が無いので、中身が repo と同じファイルは「同じ」(記録だけ作る) になる。WSL と Windows の clone を同じ commit に
  しておく。違う中身は「置いた記録が無く」の衝突になる ([衝突したら](#衝突したら)と同じ解き方。PowerShell では `Copy-Item` か `--force`)
- `powershell-profile` も、初めての apply は記録が無いので、WSL の setup が `$PROFILE` に足した読み込みの行を見て記録だけ作る (行は足さない。
  runner は WSL の記録 `~/.local/state/dotfiles/windows-powershell-profile.json` を読まず、自分の記録を `%LOCALAPPDATA%\dotfiles\state\` に作る)。
  WSL の setup が「以前 `$PROFILE` に足した 1 行が見当たりません」と出していたホスト (Windows 側で行を消した) は、runner に足した記録が無いので、
  切り替えた後の apply が足し直す (受け持ちが WSL の間の check も、行が無ければそう添える)。消したままにするなら、切り替える前に、頭に `#` を
  付けた同じ行を `$PROFILE` に置く (`.config\powershell\dotfiles.ps1` を含む行があれば、WSL も runner も足さない)
- `ssh-config`・`port-forward` も、初めての apply は記録が無いので、WSL の setup が置いた `.ssh\config`・`.ssh\config.d\<名前>.ssh_config`・
  `.config\port-forward\hosts.json` を「同じ」と見て記録だけ作る (runner は WSL の記録 `~/.local/state/dotfiles/windows-{ssh-config,port-forward}.deployed.json`
  を読まず、同じ名前・形・鍵 (`.ssh` からの相対パス・`hosts.json`) の記録を `%LOCALAPPDATA%\dotfiles\state\` に作る)。正本は dotfiles-private なので、
  WSL と Windows の dotfiles-private の clone も同じ commit にしておく (違う中身は「置いた記録が無く」の衝突になる)。WSL の記録だけが知っている
  「前に置いた」は引き継げないので、WSL の setup が最後に流れた後で dotfiles-private の `ssh/` から消したファイルは、切り替えた後の runner が消さない
  (`config.d` に残ると ssh が読み続ける)。切り替える直前に WSL の `~/dotfiles/setup --update` を流しておく
- `terminal`・`fancyzones`・`powertoys` も、初めての apply は記録が無い (WSL の記録 `~/.local/state/dotfiles/windows-terminal.applied.json`・
  `windows-fancyzones.{applied,assigned}.json`・`powertoys-keyboard-manager.reloaded` は読まず、同じ名前と形の記録を `%LOCALAPPDATA%\dotfiles\state\` に作る)。
  WSL の setup が書いた値・足したレイアウト・あてた組は「同じ」と見て記録だけ作り、Keyboard Manager には一度だけ読み直させる (PowerToys は止めない)。
  WSL の記録だけが知っている「前に書いた」は引き継げないので、切り替える直前に WSL の `~/dotfiles/setup --update` を流し、次の ⚠ が出ていないことを
  確かめる (出ていれば、切り替える前に WSL の `--import` か `--force` で解く):
  - Windows Terminal の衝突 (特に「Windows 側で消えています」: runner は記録が無いので、消したキーを書き足し直す。`managed.json` の更新が WSL に
    届く前に切り替えると、更新も「書いた記録が無く」の衝突になる)
  - FancyZones の「PC から消えています」(runner はレイアウトを足し直す)・「PC のエディターで直されています」(runner は「足す前からあった」として
    知らせる)。WSL が決まりであてた組は、runner の初めての apply が「同じ」と見て記録するので、その前に解像度や決まりを変えると、記録の無い
    runner には見分けられず「手であてた組」として残る (`--force` で決まりのレイアウトにする)
  - PowerToys の「前の回は PowerToys の起動を確かめられなかった」(WSL の印 `~/.local/state/dotfiles/powertoys-enable.pending`)・「自動起動のタスクが
    ありません」・「Keyboard Manager の設定 (settings.json) がまだ無い」。runner は WSL の印を読まないので、全体の設定が両方オンなら起動と確認を
    やり直さず、そのまま読み直させて記録する
- `international` も、初めての apply は記録が無い (WSL の記録 `~/.local/state/dotfiles/windows-international.applied.json` は読まず、同じ名前と形の
  記録を `%LOCALAPPDATA%\dotfiles\state\` に作る)。WSL の setup が書いた日付と時刻の形式は「同じ」と見て記録だけ作る (書き直さない)。WSL の記録だけが
  知っている「前に書いた」は引き継げないので、切り替える直前に WSL の `~/dotfiles/setup --update` を流し、日付と時刻の形式の ⚠ (衝突) が出ていない
  ことを確かめる (出ていれば、切り替える前に WSL の `bootstrap-windows-international.sh --import` か `--force` で解く)。特に:
  - 「前回書いた値から地域の既定に戻っています」(設定画面で既定に戻した・地域を変えた): runner は記録が無いので、初めて書く値と見て `managed.json` の
    値で書き直す
  - `managed.json` の更新が WSL に届く前に切り替えると、更新も「書いた記録が無く」の衝突になる (`dotfiles apply --steps international --force` で書く)
  - WSL が書いた後に設定画面で変えた値は、runner でも衝突になる (WSL の「Windows 側で変わっています」の代わりに「書いた記録が無く」と出る)
- `google-ime` も、初めての apply は記録が無い (WSL の記録 `~/.local/state/dotfiles/google-japanese-input/deployed.json` と落とし直しの印 `restart-pending` は
  読まず、同じ名前と形の記録と印を `%LOCALAPPDATA%\dotfiles\state\google-japanese-input\` に作る)。WSL の setup が置いた `config1.db`・`user_dictionary.db` は、
  中身 (時刻などを外した digest) が repo のテキストから組み立てたものと同じなら「同じ」と見て記録だけ作る (置き直さない・変換サーバーも落とさない)。WSL と
  Windows の dotfiles と dotfiles-private の clone を同じ commit にしておく。WSL の記録だけが知っている「前に置いた」は引き継げないので、切り替える直前に
  WSL の `~/dotfiles/setup --update` を流し、Google 日本語入力の ⚠ が出ていないことを確かめる (出ていれば、切り替える前に WSL の
  `bootstrap-windows-google-ime.sh --import` か `--force` で解く)。特に:
  - テキストの更新が WSL に届く前に切り替えると、更新も「前回置いた記録が無い」の衝突になる (`dotfiles apply --steps google-ime --force` で置く)
  - WSL が置いた後に設定画面で変えた (単語を登録した) ものは、runner でも衝突になる (`dotfiles import google-ime` で取り込む)
  - WSL が「変換サーバーを落とせませんでした」と出したまま切り替えると、runner は WSL の印を読まないので落とし直さない。WSL の setup を流し直して落とせた
    ことを確かめるか、タスクマネージャーで `GoogleIMEJaConverter.exe` を終了してから切り替える
- `pin-updates` は記録を持たない (GitHub を読んで知らせるだけ) ので、引き継ぐものは無い (切り替える直前に WSL の setup を流す要も無い)。切り替えた後は、
  WSL の `setup --update` の警告のまとめの代わりに、`dotfiles check`・`dotfiles apply` の締めの表の `pin-updates` の行 (`·` と ※) に出る。Windows の gh が
  ログインしている要がある (bootstrap がログインする)。依存の更新の skill が読む JSON の口 (`nix/scripts/bootstrap-windows-pin-updates.sh --list --json`・
  `--candidates --json`) と `--candidates` は WSL の script のまま (Linux の repo で打つ。WSL の記録を見ないので、切り替えた後も動く)
- `op-reason` も記録を持たない (入っている版は、置き場所 `%LOCALAPPDATA%\Programs\op-reason` の中身の値で `Install-OpReason.ps1` が決める) ので、
  引き継ぐものは無い (切り替える直前に WSL の setup を流す要も無い)。切り替えた後は、WSL の `setup --update` が WSL の op の実行ファイルを上げても
  Windows の部品は揃わない (WSL の `bootstrap-windows-op-reason.sh` は Windows に配らないマシンとして飛ばす) ので、Windows でも同じ commit の clone で
  `dotfiles apply` を流す。WSL の側が新しい版の窓に頼る版では、switch の前に流す ([op-reason の新しい版を出したとき](#op-reason-の新しい版を出したとき))
- 切り替える日の順。WSL が最後に配る中身と、runner が初めて apply する中身を、同じ commit にそろえるのが要 (runner は記録が無いので、repo と違う
  中身を「置いた記録が無く」の衝突と見る。WSL が古い commit のまま配った後に切り替えると、その後に repo で変わったファイルが衝突になる):
  1. merge の前に、WSL の `~/dotfiles/setup --self-update --update` で最後に配る (`--self-update` が dotfiles を、`--update` の手順 private-fetch が
     dotfiles-private を main へ進める)。上の項の ⚠ (衝突) が出ていないことを確かめ、2 つの clone の commit を控える
  2. Windows の 3 つの clone を `dotfiles --self-update` で進め、dotfiles・dotfiles-private の commit が 1 と同じかを見て、`dotfiles check` が 0 になること
  3. PR を merge し、両方の clone を進める。1 の commit から入った merge が切り替えの PR だけか (`git log --first-parent`) と、配るもの (dotfiles の
     `win/` の配るファイル・runner のコード・`nix/pkgs/herdr-core/releases.json`、dotfiles-private の `ssh/`・`google-japanese-input/`) が変わっていないか
     (`git diff --stat`) を見る。配るファイルが変わっていれば、そのファイルは 5 で「置いた記録が無く」の衝突になる (中身が repo のものなら
     `dotfiles apply --steps <id> --force` で置く)。1 より先に merge しない (WSL の `setup --update` は dotfiles-private を自分で進めるので、merge の後に流した
     回から Windows の手順を飛ばす)
  4. WSL の `~/dotfiles/setup --update`。Windows の手順は「このマシンは Windows 側へ配りません (dotfiles.wsl.windowsFiles.enable = false)。」と出して ✔ に
     なり、1 で外した道具の switch を `# tool:` に持つ手順 (`tailscale`・`sshd` など) は ↷ (このホストでは off) になる。Windows の exe は呼ばない
  5. Windows の `dotfiles apply --dry-run`。WSL と同じ手順は ✔ (「同じです」「揃っています」、記録がまだ無い手順は「記録だけ作ります」を添える) になり、
     直すことの行は `powertoys` の「Keyboard Manager に default.json を読み直させる」1 つだけ (記録が無いので一度読み直させる。終了コードは 1)。ps1 の
     手順は、入っていて固定した版なら何もしない (版がずれていれば揃える・知らせる。入っていない道具は入れ、Google 日本語入力・OpenSSH (`windowsOpenssh`
     のホスト)・Tailscale を入れるときは UAC の確認が出る)。見てから `dotfiles apply`
  6. `dotfiles check` が 0 (直すことはありません) になること。記録は `%LOCALAPPDATA%\dotfiles\state\` に、WSL と同じ名前と形でできる
- 戻すとき: 切り替えた PR のうち、ホストの値の commit (と、それに合わせて出し直した生成物の commit) だけを revert する PR を merge する (PR 全体を戻すと、
  同じ PR に入れた文書や古さの直しまで戻る)。両方の clone を同じ commit に進め、Windows で runner が作った記録 (`%LOCALAPPDATA%\dotfiles\state\` の WSL と
  同じ手順の分) を別のディレクトリへ退けてから (残すと、受け持ちが WSL の間の `dotfiles check` が古い記録と比べて直すことを出し続ける)、WSL の
  `~/dotfiles/setup --update` (WSL がまた配る。中身がその commit の repo と同じなら「同じ」) → Windows の `dotfiles check` (受け持ちが WSL の setup に戻る)
- 切り替えた後は、Windows の手順を揃えるのは Windows の `dotfiles apply` だけ (`dotfiles --self-update apply` で、clone を進めてから流す)。WSL の setup は Windows の手順をどれも飛ばす。
  全部を流す `dotfiles apply` は、WSL の `setup --update` と同じく、道具の入れ替え・設定とレジストリの書き込み・入っていない道具を入れるときの UAC を
  含む。先に `dotfiles apply --dry-run` で、WSL と同じ手順に直すことがあるかを見る (Windows にしか無い手順だけを当てるなら `--steps` で絞る)。
  版の知らせは上の `pin-updates` の項、op-reason の版を上げた後は上の `op-reason` の項、依存の更新の PR を merge した後も Windows で `dotfiles apply`
- WSL の無い Windows は、はじめから 2 だけを書く

### runner の手順

| order | id | すること | on/off | runner |
| --- | --- | --- | --- | --- |
| 5 | `bootstrap` | `bootstrap/Install-Bootstrap.ps1 -Check` (確かめるだけ。揃えるのは人が bootstrap を流す。`privateRepos` のホストは `-Check -Private` で、gh とそのログイン・3 つの clone も確かめる。ほかは gh を使わない既定の形 (dotfiles の clone と手元のホストの値) を確かめる。dotfiles の clone が origin の既定の branch より古ければ、終了コード 0 でも `dotfiles --self-update` で進めるよう · で知らせる。[bootstrap](#bootstrap-新しい-windows-で最初に流す)) | いつも | 有る (Windows だけ) |
| 6 | `winget` | `Install-WinGet.ps1`: winget (アプリ インストーラー) が固定した版より古い・入っていなければ、GitHub の Release の msixbundle と依存を SHA-256 で確かめてから `Add-AppxPackage` でこのユーザーに入れる (UAC は出ない。下げない)。winget を使うほかの手順より先に流す。CPU (x64・arm64 だけ)・`curl.exe` が無いなど入れられなければ知らせるだけ ([winget](#winget)) | いつも | 有る (Windows だけ) |
| 50 | `claude-env` | Claude Code の `%USERPROFILE%\.claude\settings.json` の `env` に、Claude の git を無署名・GitHub は gh の資格情報 (HTTPS) で通す設定を足す ([後述](#claude-skills-と-windows-のハブ-w0-2)) | `windowsClaudeCode` | 有る (Windows だけ) |
| 50 | `claude-files` | dotfiles の `CLAUDE.md` (冒頭を Windows のものに)・skill・agent・command を `%USERPROFILE%\.claude\` へ置き (ディレクトリは junction、ファイルはコピー)、hook の口 (runner の exe の写し `hooks\dotfiles-claude.exe`) を写す ([後述](#claude-code-の設定)) | `windowsClaudeCode` | 有る (Windows だけ) |
| 50 | `claude-footer-links` | `settings.json` の `footerLinksRegexes` を `nix/files/claude/footer-links.json` にする | `windowsClaudeCode` | 有る (Windows だけ) |
| 50 | `claude-hook` | `settings.json` の `hooks` に、hook の口を exec form で登録する | `windowsClaudeCode` | 有る (Windows だけ) |
| 50 | `claude-notion` | ホストの値の `[claude.notion]` から `%USERPROFILE%\.local\state\dotfiles\claude-notion.json` を書く | `windowsClaudeCode` | 有る (Windows だけ) |
| 50 | `claude-skills` | claude-skills の clone の `skills/`・`agents/`・`commands/`・`rules/` の中身を `%USERPROFILE%\.claude\` へ (ディレクトリは junction、ファイルはコピー)。clone の場所を `%USERPROFILE%\.local\state\dotfiles\claude-skills-dir` に書く | `claudePrivateSkills` | 有る (Windows だけ) |
| 50 | `claude-statusline` | `settings.json` の `statusLine` を hook の口の status line へ向ける | `windowsClaudeCode` | 有る (Windows だけ) |
| 50 | `claude-t3` | T3 Code の会話だけの Claude の設定 (`claude-code/t3/` の `settings.json`・`CLAUDE.t3.md`) を `%USERPROFILE%\.claude\t3\` へ記録つきのコピーで置き (改行は LF にし、JSON は object かを確かめてから置く。置き先で変えたファイルは衝突として知らせ、`--force` で上書き。置くファイルから外したものは、置いたままなら消す。`t3` がリンクなら触らない)、T3 の Launch arguments の文を出す (この手順は T3 の設定を書かない。`windowsT3Code` のホストでは `t3-code-settings` が書く。[後述](#claude-code-の設定))。記録は `%LOCALAPPDATA%\dotfiles\state\claude-t3.deployed.json` | `windowsClaudeCode` | 有る (Windows だけ) |
| 50 | `git-config` | git の設定 (`%USERPROFILE%\.config\git\config`・`ignore`) を、WSL の home-manager と同じ `nix/home/modules/git.toml` から置く (署名と delta は除く。Windows だけ `core.sshCommand` に Windows の OpenSSH の `ssh.exe` を足す。apply では `openssh` (96) の後に、その `ssh.exe` が変わっていればもう一度流す。[後述](#git-の設定)) | いつも (名前とメールは `gitIdentity`) | 有る (Windows だけ) |
| 50 | `local-env` | マシンローカルの環境変数のファイル `%USERPROFILE%\.config\pjp\env` を、無ければ作り、頭の「dotfiles が書く欄」を、つないだ skill の `pjp-env.txt` から書き直す (Linux の `bootstrap-local-env` と同じ印と書き直し方。欄の外の行と値には触れない。dotfiles の節は入れない。[後述](#マシンローカルの環境変数-configpjpenv)) | `claudePrivateSkills` | 有る (Windows だけ) |
| 55 | `notion-tokens` | ホストの値の `[claude.notion.tokens]` から `%USERPROFILE%\.local\state\dotfiles\notion-tokens.json` を書き、宣言したプロファイルごとに `~/.config/pjp/env` の変数の行と、env の ACL を値を出さずに確かめて知らせる (Linux の home-manager と `bootstrap-notion-tokens` を 1 つにしたもの。env と ACL は書き換えない。[後述](#notion-の-api-キーの宣言-claudenotiontokens)) | `windowsClaudeCode` | 有る (Windows だけ) |
| 55 | `pjp` | shim の `pjp` を (要れば) `cargo install` し、`pjp --build` で道具を作る | `claudePrivateSkills` | 有る (Windows だけ) |
| 60 | `claude-skill-overrides` | `settings.json` の `skillOverrides` (pjp-dev-tracker の on/off・pjp-t3-hub の off・pack の skill を名前だけ・同期された skill を隠す) を書く | `windowsClaudeCode` | 有る (Windows だけ) |
| 60 | `hc-hub` | ハブ `%USERPROFILE%\h` を `pjp hub init` で作る (作り済みなら雛形との差だけ直す) | `herdrHub` | 有る (Windows だけ) |
| 90 | `files` | `manifest.toml` のファイルを配る ([配る](#配る)と同じ判定。記録は `%LOCALAPPDATA%\dotfiles\state\windows-files.deployed.json`)。runner の clone の `core.autocrlf` が true なら ⚠ (テキストが CRLF で取り出され、WSL が配った LF と合わずに衝突になる。bootstrap の clone は false) | いつも | 有る |
| 90 | `op-reason` | `Install-OpReason.ps1 -SshRelay <モード\|off>`: WSL の op の Windows の部品 (op-reason の zip) を、入っていなければ入れ、版がずれていれば入れ替える (ps1 は `-IfMissing` を持たない)。`-SshRelay` は `-Check` にも揃える流れにも渡し、ホストの値の `opReasonSshRelay` が on なら `[opReason] sshRelayMode` のモード (op-reason の CLI で op-reason 自身の task と中継を揃える。0.6.0 までの task `\pjp\op-reason-ssh-relay` は 1 回だけ消して移す)、off なら `off` (残った task を止めて消す。どちらの task も無ければ `op-reason.exe` を起こさない)。動いている `op-reason.exe` が中継だけなら、中継を止めて入れ替えて起こし直す (ほかの `op-reason.exe` が動いている・中継が窓を開いていれば、ps1 が何も変えずに止まる) ([op-reason](#op-reason)・[SSH の中継](#ssh-の中継)) | `onePassword` | 有る |
| 91 | `powertoys` | PowerToys を入れ (`Install-PowerToys.ps1 -IfMissing`)、Keyboard Manager と自動起動がオフならオンにして PowerToys を起動し直し、Keyboard Manager に `default.json` を読み直させる ([PowerToys](#powertoys) と同じ順と判定。check と dry-run は止めない・起こさない・イベントを送らない)。記録は `%LOCALAPPDATA%\dotfiles\state\powertoys-keyboard-manager.reloaded` | いつも | 有る |
| 91 | `ssh-config` | dotfiles-private の `ssh/*.ssh_config` を `%USERPROFILE%\.ssh\config.d\` へ写し、`config` (Include の 1 行と SetEnv) を置く ([ssh の設定](#ssh-の設定)と同じ判定。正本から消えたファイルは消す。`--force` は元を `<名前>.dotfiles-bak-<日時>` に退避して上書き・削除)。apply は書いた後に `ssh -v -G` で読むファイルも確かめる (check は、apply で書く・消すものが無いときだけ)。dotfiles-private の clone の `core.autocrlf` が true なら ⚠ (files と同じ)。記録は `%LOCALAPPDATA%\dotfiles\state\windows-ssh-config.deployed.json`。SSH の中継の switch (`opReasonSshRelay`) が on なら、中継が答えるのを見てから `config.d\00-op-reason-ssh-relay.ssh_config` (中継を指す `IdentityAgent`) も置く ([SSH の中継](#ssh-の中継)) | `privateRepos` | 有る |
| 92 | `fancyzones` | FancyZones の持つキー・カスタムレイアウト (uuid ごとに足す)・横向きの既定・ディスプレイへのあて方 (解像度の決まり・組の無い仮想デスクトップに組を作る) を書く ([FancyZones](#fancyzones) と同じ判定・PowerToys の形のバイト列。`--force` は直した・消したレイアウトと手であてた組も上書き。取り込みは `dotfiles import fancyzones <名前>…`)。記録は `%LOCALAPPDATA%\dotfiles\state\windows-fancyzones.{applied,assigned}.json`、退避は `…\state\windows-fancyzones\backup\` (10 回分) | いつも | 有る |
| 94 | `starship-init` | `$PROFILE` (pwsh に聞く `CurrentUserCurrentHost`) に、starship を起こす 1 行 (`Get-Command starship` で囲む) を、`dotfiles.ps1` を読む行より前に足す (無ければ末尾に。新しい PC では、続く `powershell-profile` がその後ろに足す)。starship の init の行 (手で書いた行も) があれば何もせず、`dotfiles.ps1` を読む行より後ろにあれば前へ移すよう知らせる。足した後で消した 1 行は足し直さない (`--force` で足す)。差し込むときは前の中身を `%LOCALAPPDATA%\dotfiles\state\starship-init\backup\` へ写す。記録は `%LOCALAPPDATA%\dotfiles\state\starship-init.added.json` ([starship](#starship)) | いつも | 有る (Windows だけ) |
| 95 | `google-ime-install` | `Install-GoogleJapaneseInput.ps1`: 入っていなければ入れる (UAC)。ずれは知らせるだけ | いつも | 有る |
| 95 | `powershell-profile` | `$PROFILE` (pwsh に聞く `CurrentUserCurrentHost`) に `dotfiles.ps1` を読む 1 行を足す。読む行があれば何もせず、足した後で消した 1 行は足し直さない (`--force` で足す)。記録は `%LOCALAPPDATA%\dotfiles\state\windows-powershell-profile.json` ([PowerShell](#powershell)) | いつも | 有る |
| 96 | `openssh` | `Install-OpenSSH.ps1`: 入っていなければ入れる (UAC)。ずれは知らせるだけ。`onePassword` が off のホストは `-NoOnePassword` を付けて流し、1Password の SSH agent の案内を出さない ([OpenSSH](#openssh)) | `windowsOpenssh` | 有る |
| 96 | `sshd` | `Install-Sshd.ps1`: 入っていなければ OpenSSH の MSI に Server を足して揃える (UAC)。ずれは知らせるだけ。受け持ちが runner のホストでは、先にホストの値の `[sshd] authorizedKeys` から鍵の写しを、`allowUsers`・`allowFrom` からユーザーと送り元の写しを置く (受け持ちが WSL のホストは、鍵の写しは WSL の setup が置き、ユーザーと送り元は既定) | `windowsSshd` | 有る |
| 96 | `tailscale` | `Install-Tailscale.ps1`: 入っていなければ入れる (UAC)。古いときは知らせるだけ (入っている版の方が新しければ揃っている扱い) | `windowsTailscale` | 有る |
| 97 | `claude-code` | `Install-ClaudeCode.ps1`: 入れる・揃える (PATH のずれは知らせるだけ) | `windowsClaudeCode` | 有る |
| 97 | `claude-desktop` | `Install-ClaudeDesktop.ps1`: 入っていなければ MSIX を入れる (昇格した Windows PowerShell の winget で。UAC の確認が 1 回出る)。古いときは知らせるだけ (入っている版の方が新しければ揃っている扱い)。旧来の exe の Claude が残っていれば、入れずに外し方を知らせ (UAC も出さない)、仮想マシン プラットフォームが off なら Cowork が使えないことを `·` で知らせる ([Claude Desktop](#claude-desktop)) | `windowsClaudeDesktop` | 有る (Windows だけ) |
| 97 | `codex` | `Install-Codex.ps1`: 入れる・揃える (winget の portable を昇格せずに入れる。`codex` と打てる形 (`WinGet\Links` の symlink か、置き場所の `codex.exe` の hardlink) が無い形は入れ直し、hardlink の形では同梱の rg の置き場所をユーザーの PATH に足す。昇格した会話で winget が 1.30 以降か、開発者モードが off で winget が 1.29 以前なら入れずに知らせる。PATH のずれは知らせるだけ。[Codex CLI](#codex-cli)) | `windowsCodex` | 有る (Windows だけ) |
| 97 | `fzf` | `Install-Fzf.ps1`: 入れる・揃える (winget の portable。PATH のずれは知らせるだけ。MSI の fzf が入っていれば入れずに、外し方を知らせる。[ghq・fzf](#ghqfzf)) | いつも | 有る (Windows だけ) |
| 97 | `ghq` | `Install-Ghq.ps1`: 入れる・揃える (PATH のずれは知らせるだけ。[ghq・fzf](#ghqfzf)) | いつも | 有る (Windows だけ) |
| 97 | `herdr-app` | `Install-HerdrApp.ps1 -IfMissing`: 入れる・揃える (下げない。`-ReleasesFile` に clone の `nix/pkgs/herdr-core/releases.json`) | `windowsHerdr` | 有る |
| 97 | `herdr` | `Install-Herdr.ps1`: 入っていなければ入れる。ずれと Herdr.Herdr.Preview は知らせるだけ | `windowsHerdr` | 有る |
| 97 | `ntn` | `Install-Ntn.ps1`: 入れる・揃える (PATH のずれは知らせるだけ) | `windowsNtn` | 有る |
| 97 | `pin-updates` | Windows に固定した版 (`Install-*.ps1`・bootstrap の 5 つ・herdr-app と herdr-core の `releases.json`) より新しい版 (見送っていないもの) が出ていないかを、Windows の gh (`gh api`) で GitHub を読んで知らせる ([固定した版より新しい版の知らせ](#固定した版より新しい版の知らせ)と同じ名前・判定・文。herdr-app・herdr-core の版ごとの Windows の成果物は `curl.exe` の HEAD で見る)。新しい版は `·` (終了コードに数えない)、確かめられなければ ⚠。何も書かない (check・dry-run・apply は同じ) | `privateRepos` (gh のログインを使うホスト。中の名前ごとに `windowsNtn`・`windowsClaudeCode`・`windowsHerdr`・`windowsTailscale`・`windowsCodex` と、Windows の ghq の dotfiles の clone (bootstrap の 5 つと ghq・fzf・starship)) | 有る |
| 97 | `starship` | `Install-Starship.ps1`: 入れる・揃える (winget の portable。PATH のずれは知らせるだけ。MSI の starship が入っていれば入れずに、外し方を知らせる。[starship](#starship)) | いつも | 有る (Windows だけ) |
| 97 | `t3-code` | `Install-T3Code.ps1`: 入っていなければ入れる (user スコープ。UAC は出ない)。古いときは知らせるだけ (入っている版の方が新しければ揃っている扱い) | `windowsT3Code` | 有る (Windows だけ) |
| 97 | `type-clipboard` | `Install-TypeClipboard.ps1`: 入っていなければ入れる。ずれは知らせるだけ | `windowsTypeClipboard` | 有る |
| 98 | `google-ime` | Google 日本語入力の設定 (`config1.db`) とユーザー辞書 (`user_dictionary.db`) を、`google-japanese-input/` と dotfiles-private の辞書のテキストから組み立てて置く ([Google 日本語入力](#google-日本語入力) と同じ判定・pjp-google-ime と同じバイト列と digest。protobuf は runner が手で読み書きする)。置いたら `taskkill /F` で変換サーバーを落とし、落とせなければ印を残して次の apply が落とし直す。apply は設定画面・辞書ツールが開いていれば置かない (`tasklist` で見る)。衝突は触らない (辞書は行の数だけ出す。語の diff は `--show-words`)。`--force` は退避して置き直す。取り込みは `dotfiles import google-ime`。check と dry-run は読むだけ (tasklist・taskkill も打たない)。記録と印と退避 (10 回分) は `%LOCALAPPDATA%\dotfiles\state\google-japanese-input\` | いつも (辞書は `privateRepos`) | 有る |
| 98 | `hc-skill`・`herdr-app-skill` | `hc --skill`・`herdr-app --skill` に頭を足して `%USERPROFILE%\.claude\skills\{hc,herdr-app}\SKILL.md` を作る | `windowsHerdr` | 有る (Windows だけ) |
| 98 | `herdr-app-mods` | `herdr-app/mods/<名前>/` を herdr-app の home の `mods\<名前>\` へ記録つきのコピーで置く (herdr-app が mod のフォルダに書くファイルと、home のほかの場所には触らない。[後述](#herdr-app-の-mod)) | `windowsHerdr` | 有る (Windows だけ) |
| 98 | `herdr-app-pjp-spaces` | claude-skills の mod `pjp-spaces` を herdr-app の home の `mods\pjp-spaces\` へ記録つきのコピーで置き、同梱の layout `main` を写した `layouts\pjp-main.json` の spaces を pjp-spaces に替え、`pjp-sidebar-tabs` が置けていれば sidebar の Spaces と Agents をタブで切り替える stack にする (初めては `herdr-app do layout.clone` で写し、表示する layout が pjp-main に替わる。main が変わったら作り直す。[後述](#herdr-app-の印-pjp-spaces)) | `herdrHub` | 有る (Windows だけ) |
| 98 | `t3-code-settings` | T3 Code のテレメトリを切るユーザー環境変数 `T3CODE_TELEMETRY_ENABLED=false` と、`%USERPROFILE%\.t3\userdata\settings.json` の決めたキー (Claude の home・Launch arguments・新しいスレッドの既定・`CLAUDE_CODE_ENTRYPOINT`) を合わせる (ほかのキーと順は残す。Launch arguments は `claude-t3` の置き先に 2 つのファイルがそろっているときだけ書く。前の中身は `%LOCALAPPDATA%\dotfiles\state\t3-code-settings\backup\` へ。[後述](#t3-code)) | `windowsT3Code` | 有る (Windows だけ) |
| 99 | `claude-accounts` | claude-<名前> (既定の personal・work と `claude-account add` で足したもの) の `%USERPROFILE%\.claude-<名前>\` を用意し (settings.json と CLAUDE.md は `~/.claude` へのファイルの symlink。足りなければ UAC の確認が 1 回出る)、launcher の `claude-<名前>.exe` と管理のコマンドの `claude-account.exe` を `%LOCALAPPDATA%\dotfiles\bin` に置いてユーザーの PATH に足す ([後述](#claude-personalclaude-work)) | `windowsClaudeAccounts` と `windowsClaudeCode` | 有る (Windows だけ) |
| 99 | `claude-selector` | claude-selector (略語 `cs`。claude のアカウントと option を矢印キーで選んで Claude Code を起こす) を、Linux と同じ crate (`nix/pkgs/claude-selector`) から runner の toolchain で `cargo build` し、`%LOCALAPPDATA%\dotfiles\bin\claude-selector.exe` に置いてユーザーの PATH に足す。crate の元か toolchain が変わったときだけ作り直す (check と dry-run は cargo を打たない。[後述](#claude-selector-cs)) | `windowsClaudeCode` | 有る (Windows だけ) |
| 99 | `claude-tokens` | ホストの値の `[claude.tokens]` から `%USERPROFILE%\.local\state\dotfiles\claude-tokens.json` を書く (Linux の home-manager と同じ中身。宣言が無くても `{"accounts":{}}`。check と dry-run は書かない。読むのは `claude-account audit`。[後述](#claude-の-token-の置き場の宣言-claudetokens)) | `windowsClaudeAccounts` と `windowsClaudeCode` | 有る (Windows だけ) |
| 99 | `herdr-app-keys` | `herdr-app/keys.json` (dotfiles が持つキー) を herdr-app の home の `keys.json` に書き足す (ほかのキーと順は残し、dotfiles が書いた値でないキーは衝突として知らせる。`herdr-app/keys.defaults.json` に書いた herdr-app の既定の値は書き換える。keys.json が無ければ書かない。[後述](#herdr-app-のキー)) | `windowsHerdr` | 有る (Windows だけ) |
| 99 | `international` | `international/managed.json` の値だけを、日付と時刻の形式 (`HKCU\Control Panel\International`) へ書く ([日付と時刻の形式](#日付と時刻の形式) と同じ判定。WSL と同じ PowerShell の本文を `pwsh` (PowerShell 7) に `-EncodedCommand` で渡し、SetLocaleInfoW で書いて WM_SETTINGCHANGE を送り、読み戻す。衝突は触らない。`--force` は衝突も書く。取り込みは `dotfiles import international`。check と dry-run は読むだけ。SSH の会話の apply は書く値があれば書かずに ⚠)。記録は `%LOCALAPPDATA%\dotfiles\state\windows-international.applied.json` | いつも | 有る |
| 99 | `port-forward` | dotfiles-private の `ssh/port-forward.toml` を確かめて JSON にし、`%USERPROFILE%\.config\port-forward\hosts.json` に置く ([port forwarding (pf)](#port-forwarding-pf) と同じ確かめ・中身・判定。`--force` は元を `hosts.json.dotfiles-bak-<日時>` に退避して上書き)。記録は `%LOCALAPPDATA%\dotfiles\state\windows-port-forward.deployed.json` | `privateRepos` | 有る |
| 99 | `terminal` | `windows-terminal/managed.json` のキーだけを Windows Terminal の `settings.json` へ書き足す ([Windows Terminal](#windows-terminal) と同じ判定・`jq --indent 4` と同じバイト列。衝突は触らない。`--force` は退避して書く。取り込みは `dotfiles import terminal`)。記録は `%LOCALAPPDATA%\dotfiles\state\windows-terminal.applied.json`、退避は `…\state\windows-terminal\backup\` (10 回分) | いつも | 有る |

- ps1 は clone の中のものを、PATH の `pwsh` (無ければ Windows PowerShell) で `-Check` してから、WSL の wrapper と同じ判断で `-IfMissing` か
  引数なしで流す (出力は UTF-8 にしてから流す)。ps1 の締めの行の文言 (「→ Install-Ntn で揃える」など) を変えるときは
  `runner/src/steps/ps1.rs` も直す (WSL の wrapper と同じ約束)
- 待つ上限も WSL と同じ (`-Check` は 60〜120 秒、入れる・揃えるのは 300〜600 秒。Claude Code は 1800 秒 (約 340 MB を 2 回落とす)。Windows にしか
  無い Claude Desktop も 1800 秒 (約 300 MB の MSIX と、UAC の確認を押すまでの間))。
  時間切れなら pwsh を止める (子の winget までは止めない)。秒数は試験が WSL の wrapper の `timeout` と突き合わせる
- WSL にしか無かった手順のうち 9 つは、移す順と移し方を ADR 060 に決めてある (powershell-profile → ssh-config・port-forward → terminal・powertoys・
  fancyzones → international → google-ime → pin-updates)。9 つとも移し、その後に足した `op-reason` も ps1 の手順として移した。WSL の setup の
  Windows の手順は、全部 runner にある (まだ無い手順は無い)
- まだ無い手順の on/off は、WSL の script の `# tool:` と同じ道具の switch (行が無ければいつも)。`# tool:` のある手順は、移した後も同じ道具の
  switch で on/off する (試験が突き合わせる)

### runner の手順を足す

1. `runner/src/steps/<名前>.rs` に trait `Step` を書く (id・order・題・on/off (`Gate`)・`windows_only` (WSL の setup に同じ手順が無く、受け持ちによらず
   runner が流すなら true) と、`Mode` (check・dry-run・apply) ごとの中身)。外の
   コマンドは `ctx.sys` で打ち (試験で偽物に差し替えられる)、置き場所は `ctx` から引く (`ctx.repo_path(…)`・隣の clone の
   `ctx.sibling("claude-skills")` (隣に無ければ bootstrap の置き場)・`ctx.roots`・記録の置き場の `ctx.state_dir`)。記録が要れば `record::Records` (files と同じ形の JSON)。
   WSL の記録が版つき・入れ子 (`{"version":1,"files":{…}}`) なら `record::FileRecords`。置き先の中身と記録で書く・衝突を決めるコピー (files・ssh-config・
   port-forward の形) は `steps/deploy.rs` の判定 (`judge`。退避・消すことと、受け持ちで替える `--force` の案内も) を使う。WSL が jq で書く JSON を
   写すときは `runner/src/jv.rs` (数の字を保ち、jq と同じく比べて同じ形で書く) を使い、1 回ぶんの退避は `fsutil::backup_run_dir` (WSL の
   `<UTC の時刻>-<pid>` のディレクトリと同じ形) を使う
2. `runner/src/steps/mod.rs` の `all()` に 1 行足す (order と script の名前の順に並ぶ)。同じファイルの試験 (`order_matches_wsl_setup`) の並びにも
   足す。Windows にしか無い手順 (W0-2 など) は WSL の script を持たなくてよい (試験が WSL の script を求めるのは、WSL から写した手順とまだ無い手順だけ)
3. 偽の `Sys` (`testutil::FakeSys`) で分かれ道を試す (偽のコマンドの stderr の行は `testutil::stderr_line` で印を付ける。`stdout_only` の写しに入らず、
   流す口には届く本物の口と同じになる)
4. この節の表に行を足す

手順の順は WSL の `# order:` にそろえるので、前の手順が書く中身が、後ろの手順の入れるもので変わることがある (`git-config` (50) の `core.sshCommand` と、
OpenSSH を入れる `openssh` (96))。そのときは前の手順に trait `Step` の `rerun_after` を書く: apply で後ろの手順が流れた直後に runner が聞き、true なら
その場でもう一度流す (締めの表では、前の手順の行を「<後ろの手順> の後に流し直した: 」の行に置き換える。1 回目の出力は見出しの上に残る。check と
dry-run では聞かない)。書き直すものが無ければ false を返す (毎回流し直さない)。相手の手順の id と順は、前の手順の試験で確かめる (変わると黙って効かなくなる)

WSL の側に Windows の手順 (`nix/scripts/bootstrap-windows-<id>.sh`) を足したときは、runner に写すまで `runner/src/steps/pending.rs` の `PENDING`
に足し (gate は script の `# tool:` と同じにする)、`order_matches_wsl_setup` の並びと上の表にも足す。WSL の script が一覧に無い・`# tool:` と
gate が違うと、試験が落ちる

まだ無い手順を runner に移すときは、`PENDING` の行を消して 1〜3 のとおり module を足し、上の表の行を「有る」にする (`order_matches_wsl_setup` の
並びは変わらない)。判定・文言・記録の名前と形は WSL の script にそろえる (受け持ちを切り替えた後に、WSL が書いたものをそのまま引き継ぐ)

### runner を直すとき

- Windows の clone で runner を直して試すと、launcher は `win/runner` に commit していない変更を見て、cargo で build して流す (cargo が要る。gh の無い
  PC は `Install-Bootstrap.ps1 -Rust`)。commit した後・push していない間も、その key の Release が無いので cargo で build する。いつも build するなら
  `$env:DOTFILES_RUNNER = 'cargo'` ([runner の exe (Release)](#runner-の-exe-release))
- runner の exe に `win/runner` の外のファイルを埋めない (`include_str!`・`include_bytes!`)。key は `win/runner` の tree だけで決まるので、外を埋めると、
  そのファイルを変えても古い中身の exe が選ばれる。外のファイルは動くときに clone から読む (`runner/tests/embeds.rs` が見る)
- C ランタイムは `runner/.cargo/config.toml` で静的にリンクする (MSVC の target だけ。環境変数 `RUSTFLAGS` を置くと無視される)。Release の exe の CI が
  `dumpbin /dependents` で確かめる
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
- `Cargo.lock` (runner と claude-selector の) の版に届け出の済んだ脆弱性が無いかは、CI の `cargo-lock-vulns`
  ([`.github/workflows/cargo-lock-vulns.yml`](../.github/workflows/cargo-lock-vulns.yml)) が PR と毎朝照らす。落ちたときの直し方 (直した版へ上げる・
  理由と期限をつけて受け入れる) は [`nix/README.md`「Cargo.lock の既知の脆弱性 (osv-scanner)」](../nix/README.md#cargolock-の既知の脆弱性-osv-scanner)
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
  登録 (`src/steps/claude_hook.rs` の `REGISTRATIONS`) は `bootstrap-claude-hook.sh` の同じ hook の行と突き合わせる。`powershell-profile`
  (`src/steps/powershell_profile.rs`) は、`nix/scripts/bootstrap-windows-powershell-profile.sh` を偽の `pwsh.exe`・`wslpath` で流し、同じ `$PROFILE` から
  同じバイト列を書いて同じく記録するかを突き合わせる。`ssh-config`・`port-forward` (`src/steps/ssh_config.rs`・`port_forward.rs`) は、
  `bootstrap-windows-ssh-config.sh` (偽の `ssh.exe`)・`bootstrap-windows-port-forward.sh` (本物の `nix-instantiate` と jq。`DOTFILES_WIN_NIX_PARITY=1`) を同じ
  状態から流し、同じファイルを書き・消し・退避して同じ記録を書くか、正本の誤りの文が同じかを突き合わせる。`terminal`・`powertoys`・`fancyzones`
  (`src/steps/terminal.rs`・`powertoys.rs`・`fancyzones/`) は、`bootstrap-windows-terminal.sh` (bash と jq)・`bootstrap-windows-powertoys.sh` (偽の
  `powershell.exe`・`pwsh.exe`・`sleep`)・`bootstrap-windows-fancyzones.sh` (偽の `powershell.exe`・`sleep`) を同じ状態から流し、書く JSON のバイト列・
  記録・退避・PowerToys を止める・起こす・イベントを送る順・計画の行と、取り込み (`--import`) が同じかを突き合わせる (偽の exe は要るコマンドだけを
  並べた PATH で流し、本物の Windows の exe を見せない)。jq は 1.7 から数の字を保って書く (`1e2` → `1E+2`・`1.50` はそのまま。CI の Linux の
  ubuntu の jq 1.7.1 も手元の 1.8.2 も同じ)。その書き方は `jv.rs` の単体の試験でも比べる。`international` (`src/steps/international.rs`) は、
  `bootstrap-windows-international.sh` と runner を同じ偽の `pwsh.exe` (WSL の試験の偽物と同じ振る舞い) で同じ状態から流し、pwsh に渡す本文 (バイト単位)・
  書く値とその順・Windows の値・記録・取り込んだ `managed.json` が同じかと、WSL が書いた値を記録の無い runner が書き直さずに引き継ぐかを突き合わせる。
  PowerShell の本文と表 (`table`) は、bash の版が流れない Windows の CI でも WSL の script の字と比べ、Windows の CI では本物の `pwsh` に本文を流して
  読む (書かない)。`google-ime` (`src/steps/google_ime/`) は、組み立てたバイト列・digest・テキストへ戻したもの・取り込みが pjp-google-ime と 1 バイトも
  違わないかと、`bootstrap-windows-google-ime.sh` と runner を同じ偽の `tasklist.exe`・`taskkill.exe` (WSL の試験から抜き出す) で同じ状態から流し、置いた
  ファイル・記録・印・退避・打った引数・取り込んだテキストが同じかを突き合わせる。pjp-google-ime は、`PJP_GOOGLE_IME` (exe のパス) が無ければ nix で
  repo の flake (`nix/`) から作る (`DOTFILES_WIN_NIX_PARITY=1` なら作れないと落ちる)。protobuf の型の表 (`pb.rs`) は `nix/pkgs/pjp-google-ime/proto/` の
  .proto の写しと突き合わせるので、.proto を写し直したら表も直す。`pin-updates` (`src/steps/pin_updates/`) は、`check-winget-version.sh --json <名前>`・
  `check-herdr-app-version.sh --json` と `bootstrap-windows-pin-updates.sh` (setup の手順) を runner と同じ偽の `gh`・`curl` と同じ repo のファイルで流し、
  新しい版と見送り・確かめられなかったときの stderr の行・知らせる文・打った gh と curl の引数と順が同じかを突き合わせる (作り物の repo と、本物の
  ps1・見送りの一覧・`releases.json`)。版の並べ方は `sort -V` と比べる。名前ごとの題・ps1・param・変数・版の形・知らせる文は、bash の版が流れない
  Windows の CI でも WSL の script の字と比べる。`op-reason` (ps1 の手順の型の `src/steps/ps1.rs`。突き合わせは `src/steps/op_reason_parity.rs`) は、
  `bootstrap-windows-op-reason.sh` と runner を同じ偽の `pwsh.exe` (`-Check` と揃える流れに、決めた出力と終了コードを返す) で流し、同じ判定と終了コード・
  打った pwsh の引数と順・手順の行・見せた pwsh の出力・直し方が同じかを突き合わせる。PATH に `pwsh` があれば、本物の `Install-OpReason.ps1` の
  `-Check` (置き場所を一時ディレクトリに向ける。揃える流れは偽物が打たずに断る) でも突き合わせる (Windows の CI では runner の側だけ)。`local-env`
  (`src/steps/local_env.rs`) は、`nix/scripts/bootstrap-local-env.sh` を同じ skill の断片と同じ env のファイルから流し、何をしたか・欄の外のバイト・
  skill の節・欄に入れなかった断片・移した名前・印の行番号が同じかを突き合わせる (欄の前置きと dotfiles の節は Windows のものなので比べない)。
  `notion-tokens` (`src/steps/notion_tokens.rs`) は、runner が書いた `notion-tokens.json` と同じ env から `nix/scripts/bootstrap-notion-tokens.sh` を流し、
  入っている・いないとしたプロファイル・入れ方の行・宣言が無いときの知らせが同じかを突き合わせる (頭の BOM と空白だけの値の数え方、権限 (Linux は
  mode、Windows は ACL) は比べない)。`notion-tokens.json` の中身と宣言を止めるか通すかは、`tests/claude_parity.rs` が Linux の
  `nix/lib/notion-tokens.nix` の stateText と assertions (`nix eval`) と突き合わせる。ACL の読み方は、Windows の CI で本物の PowerShell と `icacls` で
  確かめる。`claude-tokens.json` の中身と `[claude.tokens]` を止めるか通すかも、`tests/claude_parity.rs` が `nix/lib/claude-tokens.nix` の stateText と
  assertions と突き合わせる (素の claude の `default` だけは、Nix が通し Windows が止める)。`claude-account audit` (`src/token_audit.rs`) の表・判定・文は
  Linux の `nix/pkgs/claude-account/claude-account.sh` の `cmd_audit` を写したもので、単体の試験 (`src/account_cli.rs`) が同じ字の行を見る。bash の版を
  直したら、Rust の写しも同じに直す

### claude-skills と Windows のハブ (W0-2)

claude-skills (private な skill 置き場。Rust の道具の入口 `pjp`) を Windows の Claude Code で使い、herdr-app と hc のハブ `%USERPROFILE%\h` を作る
手順 (claude-skills の spec `docs/superpowers/specs/2026-11-15-windows-herdr-app-hc-design.md` の §9 の Windows の項目。経緯は dotfiles-private の
ADR 064 (`docs/adr/064_win_w02_claude_skills_hub_*`))。どれも Windows にしか無い手順なので、受け持ちが WSL のホストでも `dotfiles apply` が流す
(ホストの値は要る。claude-skills は private な repo なので、`claudePrivateSkills`・`herdrHub` のホストは `privateRepos = true` も書き、bootstrap を
`-Private` で流す。[ホストの値](#ホストの値))。Linux の側は `nix/README.md` の「claude-skills の Rust の道具 (shim の pjp)」と「hc の skill」。

```powershell
dotfiles --self-update             # runner は clone を取得しない。先に 3 つの clone を進める (gh の資格情報で HTTPS を通す。上の「clone を進める」)
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
- まだ後の PR: ハブの見回り役 `pjp-hubd` を立てる (claude-skills の W2-3 の後)・plugin・`c` の `--no-chrome`・Defender の除外。pjp-spaces (W2-4) は
  [herdr-app の印 (pjp-spaces)](#herdr-app-の印-pjp-spaces)、pjp が読む API キーの置き場 `~/.config/pjp/env` は
  [マシンローカルの環境変数](#マシンローカルの環境変数-configpjpenv)。clone の更新は、runner ではなく PowerShell の `dotfiles --self-update` が受け持つ
  ([clone を進める](#clone-を進める-dotfiles---self-update))

### マシンローカルの環境変数 (`~/.config/pjp/env`)

そのマシンでしか使わない API キー (Notion の `PJP_NOTION_TOKEN_<名前>` など) の置き場。Windows では `%USERPROFILE%\.config\pjp\env`
(`XDG_CONFIG_HOME` があれば `<XDG_CONFIG_HOME>\pjp\env`) で、claude-skills の pjp がこのファイルを直に読む (Windows ではシェルが環境へ読み込まない)。
runner の手順 `local-env` (`claudePrivateSkills` のホスト) がファイルを置き、頭の「dotfiles が書く欄」を書き直す。Linux の `bootstrap-local-env`
([`nix/README.md`「マシンローカルの環境変数」](../nix/README.md#マシンローカルの環境変数-configpjpenv)) と同じ印と書き直し方で、Windows で変えたところと
その経緯は dotfiles-private の ADR 105 (`docs/adr/105_win_local_env_*`)。Windows にしか無い手順なので、受け持ちが WSL のホストでも `dotfiles apply` が流す。

```powershell
dotfiles check --steps local-env              # 差を見る (何も書かない)
dotfiles apply --steps local-env              # 無ければ作り、欄を書き直す
notepad "$env:USERPROFILE\.config\pjp\env"     # 値は欄より下に書く
```

値は欄 (`# >>> dotfiles` で始まる行から `# <<< dotfiles` で始まる行まで) より下に、行頭から `KEY=VALUE` で書く (例: `PJP_NOTION_TOKEN_PERSONAL=ntn_…`)。
クォートも展開もしない。pjp は打つたびに読むので、書いた後に開き直すものは無い。

| ファイルの様子 | すること |
| --- | --- |
| 無い | 欄だけのファイルを作る (UTF-8・改行は LF) |
| 印が 1 組 | 印の間を新しい欄に替える。印より上と下は 1 バイトも変えない |
| 印の間に `#` で始まらない行がある | その行を元の順のまま終わりの印のすぐ下へ移し、変数名を `!!` で知らせる (値は出さない) |
| 印が無い (空のファイルも) | 欄を頭に足す。今の行は 1 行も消さない (頭の UTF-8 の BOM は外す) |
| 印が壊れている・symlink・普通のファイルでない・NUL を含む (UTF-16 で保存した・UTF-16 の行を足した)・`env.bak` がディレクトリ・読み取り専用 (書き直すことがあるとき)・`XDG_CONFIG_HOME` が相対パス | 書かずに ⚠ で知らせる |

- 書き上がりが今と同じなら何も書かない。違えば前の版を同じディレクトリの `env.bak` (1 世代) に写し、一時ファイルから置き換える
- 欄の節は、`%USERPROFILE%\.claude\skills\*\pjp-env.txt` (`claude-files` と `claude-skills` がつないだ skill の断片) から名前の順に組む。Linux の欄にある
  dotfiles の節 (`nix/pjp-env/dotfiles.txt`) は入れない (Linux の setup が環境変数として読むもので、Windows では読むものが無い)。Windows で効くのは、
  pjp がこのファイルから読む変数だけ
- 印に化ける行・行の途中の制御文字を持つ断片と、名前に英数字と `. _ -` 以外の字がある skill は欄に入れず、⚠ で知らせる (欄はほかの断片で書く。
  断片の書き方は [`nix/files/claude/skills/README.md`「環境変数を受け取るとき」](../nix/files/claude/skills/README.md#環境変数を受け取るとき-pjp-envtxt))
- 文字コードは UTF-8 (BOM は無くても有ってもよい)。改行はファイルに合わせる (CR があれば CRLF、無い・新しいファイルは LF)。メモ帳はどちらの改行も
  そのまま保つ。Windows PowerShell 5.1 のリダイレクト (`>`・`>>`) と `Out-File` は既定で UTF-16 で書く (`>>` は UTF-8 のファイルに UTF-16 の行を
  足す) ので、このファイルに使わない (pjp も読めない)。足してしまったら、その行を消して書き直す
- 権限は締めない (`%USERPROFILE%` の下は、継いだ ACL で本人と SYSTEM・Administrators だけが読める)。書き直すたびに、env と `env.bak` は置き場所の
  ディレクトリの ACL を継ぐ (ファイルにだけ付けた ACL は残らない)。`XDG_CONFIG_HOME` で `%USERPROFILE%` の外に置くなら、そのディレクトリの ACL を確かめる。
  Notion の API キーを宣言したホストでは、手順 `notion-tokens` が env の ACL を見て知らせる (下の節。書き換えない)
- 値を守るために読み取り専用にしたファイルは、欄が最新のうちはそのまま ✔ で、欄を書き直すことがあるときだけ ⚠ になる (`attrib -r` で外してから流し、
  要れば `attrib +r` で付け直す。書き直したファイルは読み取り専用でなくなる)

#### Notion の API キーの宣言 (`[claude.notion.tokens]`)

Notion を `ntn login` でなく API キーで使うマシンは、どのプロファイルにどの種類の API キーを使うかを、ホストの値に書く (Linux の
`dotfiles.claude.notion.tokens` と同じ名前と形。[`nix/README.md`「Notion の API キーの種類を宣言する」](../nix/README.md#notion-の-api-キーの種類を宣言する))。
値 (token) は書かない。

```toml
[claude.notion.tokens.personal]
kind = "personal"                                  # "integration" (integration の API キー) か "personal" (個人用アクセストークン)
item = "op://<vault の ID>/<項目の ID>/<欄の ID>"   # 元の値の 1Password の参照。欄まで書く。分かるまで書かない (null)
```

| キー | 値 |
| --- | --- |
| `tokens` の下の名前 | プロファイルの名前 (`profiles.toml` の名前と同じ形。英小文字か数字で始め、英小文字・数字・`-` と `_` だけ)。変数名は名前を大文字にし、`-` を `_` にしたもの (personal → `PJP_NOTION_TOKEN_PERSONAL`) |
| `kind` | `integration` (integration の API キー)・`personal` (個人用アクセストークン)。書かなければ止まる |
| `item` | 元の値を置いた 1Password の参照。欄まで書く: `op://<vault の ID>/<項目の ID>/<欄の ID>` (セクションがあれば `op://<vault>/<項目>/<セクション>/<欄>`)。`pjp-op-ref` が出す ID の形の参照で、値ではない。書かなければ null |

次のときは runner が止まる (終了コード 2): 名前の形が違う・同じ変数になる 2 つの名前 (`my-ws` と `my_ws`)・知らないキー・`kind` が無いか 2 つの外・
`item` が欄まで書いた `op://` の参照でない (値そのものを書いたときも)。止める文には `kind` と `item` に書いた字を出さず、名前だけを出す (Nix の
`nix/lib/notion-tokens.nix` と同じ見方)。

手順 `notion-tokens` (order 55。`windowsClaudeCode` のホスト) は、Linux の home-manager (`notion-tokens.json` を置く) と setup の
`bootstrap-notion-tokens.sh` (知らせる) を 1 つにしたもので、check・dry-run・apply のたびに次をする:

1. `%USERPROFILE%\.local\state\dotfiles\notion-tokens.json` を書く (Linux と同じ中身。宣言が無くても `{"tokens":{}}`。check と dry-run は書かない)。
   読むのは claude-skills の棚卸しの道具 (`pjp notion-token-audit`)
2. 宣言したプロファイルごとに、`~/.config/pjp/env` (local-env と同じ置き場所) に変数の行があるかを、値を出さずに数える。無ければ ⚠ と、入れ方
   (ユーザーが自分の端末で `pjp notion-profile set-token <名前>` を打つ。`item` があればその参照) を出す。宣言が無ければ env を見ない
3. env があれば ACL を見る。読む権限を許す規則が、本人 (今のユーザー)・SYSTEM・Administrators のほかにもあれば ⚠ と直し方を出す
   (`%USERPROFILE%` の下は、継いだ ACL でこの 3 つだけが読める。runner は ACL を書き換えない)

```powershell
dotfiles check --steps notion-tokens      # 行の有る無しと ACL を見る (何も書かない)
dotfiles apply --steps notion-tokens      # notion-tokens.json を書き、同じく確かめる (set-token で入れた後の確かめにも)
```

- 行は、頭が `<var>=` で、`=` の後ろの値が空白だけでない行 (Windows でこのファイルを読む pjp と、棚卸しの道具と同じ数え方。ファイルの頭の
  UTF-8 の BOM は外して読む)。`#` で始まる行・頭に空白のある行・`export <var>=` の行は数えない
- env が無い (行が無いのと同じく知らせる。作らない)・symlink・普通のファイルでない・NUL がある (UTF-16 で保存した)・`XDG_CONFIG_HOME` が
  相対パスのときも ⚠ で知らせる (書き換えない)
- ACL は PowerShell の `Get-Acl` で読む。拒む規則と、自分に効かない規則 (InheritOnly・CREATOR OWNER) は数えない (拒む規則を差し引かないので、
  読める側に寄せて知らせる)。env は書き直すたびに置き場所のディレクトリの ACL を継ぐので、直すならディレクトリの ACL を直す
- 入れてからの日数は出さない (Linux の setup の知らせと同じ)。日数と回す時期は claude-skills の棚卸しの skill (`pjp-notion-token-audit`) が見る
- 値はユーザーが入れる。Claude は `set-token` を打たず、env と `env.bak` を開かず、値を読まない・書かない・出さない
  ([`nix/files/claude/CLAUDE.md`](../nix/files/claude/CLAUDE.md) の「シークレット」の例外と `pjp-secrets`。わけと守りは dotfiles-private の ADR 112 と、
  それを Windows へ広げた ADR 114)
- env に行が入るまで、Windows の pjp は今までどおり `ntn login` で Notion に入る

### Claude Code の設定

Windows の Claude Code (herdr-app のハブ) に、WSL の Claude Code と同じ決まり (dotfiles の `nix/files/claude/` の `CLAUDE.md`・skill と、settings.json の
hook・status line・skillOverrides・footer のリンク) を配る手順。Linux では `nix/home/modules/claude.nix` (home-manager) がファイルを置き、
`nix/scripts/bootstrap-claude-{hook,statusline,footer-links,skill-overrides}.sh` が settings.json に書く。Windows では runner の 5 つの手順が同じことをする
(経緯は dotfiles-private の ADR 065 (`docs/adr/065_win_claude_config_*`))。T3 Code の会話だけに足す設定は、Linux に無い手順 `claude-t3` が置く
([T3 Code の会話だけの設定](#t3-code-の会話だけの設定))。どれも Windows にしか無い手順なので、受け持ちが WSL のホストでも
`dotfiles apply` が流す (ホストの値は要る)。

```powershell
dotfiles check --steps claude-files,claude-hook,claude-statusline,claude-footer-links,claude-skill-overrides,claude-t3   # 差を見る (何も書かない)
dotfiles apply --dry-run                                                                                                 # することを出す
dotfiles apply                                                                                                           # 揃える
```

| 手順 | すること | 気をつけること |
| --- | --- | --- |
| `claude-files` | `CLAUDE.md` を、`claude-code/CLAUDE.windows.md` (Windows の冒頭) + 空行 + `nix/files/claude/CLAUDE.md` の最初の「## 」の行から後ろ (+ `devTracker` のホストは空行と `CLAUDE.dev-tracker.md`) にして置く (改行は LF)。`nix/files/claude/{skills,agents,commands}/` の中身を 1 つずつ置く (ディレクトリは junction、ファイルはコピー。`claude-code/skip-skills.txt` の skill は張らず、前に張ったものは外す)。runner の exe を `%USERPROFILE%\.claude\hooks\dotfiles-claude.exe` に写す (hook と status line の口) | `CLAUDE.md` とファイルは記録つきのコピー (`%LOCALAPPDATA%\dotfiles\state\claude-files.deployed.json`)。Windows 側で変えた・記録の無い違う中身は衝突で飛ばす (dotfiles に取り込むか、`dotfiles apply --steps claude-files --force` で上書き)。exe は dotfiles が持つ生成物で、違えば書き直す。動いている exe は上書きできないので、退けてから置く (退けたものは次に消す) |
| `claude-hook` | `settings.json` の `hooks` に、hook の口を exec form (`command` に exe の絶対パス、`args` に `claude-hook <名前>`) で登録する。event・matcher・if は Linux の `bootstrap-claude-hook.sh` の同じ hook の行と同じ。ただしコマンドを読む hook は PowerShell の tool にも登録する (matcher の `Bash` は `Bash\|PowerShell`、if で絞る pr-assignee-nudge は `PowerShell(gh pr create *)` の組も足す) | shell を通さないので、Git Bash が見つからない会話でも PowerShell が command を読まない (shell form の PreToolUse の hook は、Git Bash が無いと失敗が tool を止めうる)。この手順の口 (`dotfiles-claude.exe`) の登録で今は入れない組は外す。ほかの hook (ハブの `pjp hub guard` などのプロジェクトの hook は別のファイル) とキーの順は残す |
| `claude-statusline` | `settings.json` の `statusLine` を `~/.claude/hooks/dotfiles-claude.exe claude-statusline` にする (別の値は置き換える) | status line は Git Bash (無ければ PowerShell) が読む shell の文なので、Claude Code の docs のとおり `~` と `/` で書く |
| `claude-footer-links` | `settings.json` の `footerLinksRegexes` を `nix/files/claude/footer-links.json` で丸ごと置き換える (cc-page の規則の port は cc-pages の既定の 7777) | 手で足した項目も消える (Linux と同じ。足すなら repo の `footer-links.json`) |
| `claude-skill-overrides` | `settings.json` の `skillOverrides` に、`pjp-dev-tracker` (ホストの値の `devTracker` で on / off)・`pjp-t3-hub` (いつも off。T3 Code の会話だけが `--settings` で on にする)・pack の skill (入口 `pjp-pack-<pack>` があれば `name-only`)・claude.ai から同期された skill (`anthropic-skills:<名前>` を `user-invocable-only`) を書く。選び方は Linux の `bootstrap-claude-skill-overrides.sh` と同じ | 書いた key は `%LOCALAPPDATA%\dotfiles\state\claude-skill-overrides.applied.json` に控え、書かなくなったら戻す (`pjp-dev-tracker`・`pjp-t3-hub` は控えずにいつも書く)。手で別の値を書いた key には触らない。order は 60 (claude-files と claude-skills が skill をつないだ後) |
| `claude-t3` | `claude-code/t3/` の `settings.json`・`CLAUDE.t3.md` を `%USERPROFILE%\.claude\t3\` に置き (改行は LF。JSON は object かを確かめてから置く)、T3 の Launch arguments の文を出す (`windowsT3Code` のホストでは `t3-code-settings` が書く。[T3 Code の会話だけの設定](#t3-code-の会話だけの設定)) | 記録つきのコピー (`%LOCALAPPDATA%\dotfiles\state\claude-t3.deployed.json`)。Windows 側で変えた・記録の無い違う中身は衝突で飛ばす (dotfiles の `win/claude-code/t3/` に取り込むか、`dotfiles apply --steps claude-t3 --force` で上書き)。置くファイルから外したものは、置いたままなら消す。T3 の設定は書かない |

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
| `ssh-agent-notice.sh` | 入れない (前提が違う) | WSL の ssh は Windows の ssh.exe を包み、承認の画面がどこに出るかを知らせる hook。Windows の Claude の git は gh の HTTPS (`claude-env`) で SSH の鍵を使わず、Git Bash の ssh は 1Password の agent (Windows の named pipe) を使わない (git だけは `git-config` が書く `core.sshCommand` で Windows の OpenSSH の ssh を使う。[git の設定](#git-の設定))。承認の画面は、ユーザーが見ている Windows の画面に出る |

#### T3 Code の会話だけの設定

T3 Code (desktop app) の Claude の会話も、herdr-app のハブと同じ `~/.claude` (CLAUDE.md・skill・settings.json) を読む。T3 の会話だけに
足すもの (herdr-app を前提にした指示の読み替えと、skill の見え方) は、T3 の Launch arguments で Claude Code に渡す。ファイルは runner の
`claude-t3` が `%USERPROFILE%\.claude\t3\` に置く。Launch arguments は、T3 Code を dotfiles で入れたホスト (道具の switch `windowsT3Code`) では
`t3-code-settings` が T3 の settings.json に書き、ほかのホストは人が T3 に書く (経緯は dotfiles-private の ADR 090
(`docs/adr/090_win_claude_t3_launch_args_*`))。

| ファイル | 渡す引数 | 効き方 |
| --- | --- | --- |
| `settings.json` | `--settings` | T3 が読み、T3 自身の設定の下に重ねて渡す。flag settings なので user の `settings.json` より強く、`skillOverrides` は skill ごとに勝つ。herdr と hc のハブ・子の skill (`herdr-app`・`pjp-herdr-hub`・`pjp-herdr-other-repo`・`pjp-hc-hub`・`pjp-hc-hub-panel`・`pjp-pack-hc`・`pjp-hc-child`。T3 では hc のハブの panel を使わないので、hc の pack の入口 `pjp-pack-hc` も) を off、`pjp-t3-hub` (ほかの会話では `claude-skill-overrides` がいつも off にする) を on にする。`hc` は残す |
| `CLAUDE.t3.md` | `--append-system-prompt-file` | T3 の指示の後ろ (system prompt の末尾) に足す。`~/.claude/CLAUDE.md` は置き換えず、そのまま読まれる |

Launch arguments の文 (T3 の `%USERPROFILE%\.t3\userdata\settings.json` の `providerInstances.claudeAgent.config.launchArgs` に入る):

```text
--settings <ホーム>\.claude\t3\settings.json --append-system-prompt-file <ホーム>\.claude\t3\CLAUDE.t3.md
```

- `<ホーム>` は `%USERPROFILE%` の絶対パス。`claude-t3` の check・apply が、この PC のパスで同じ文を出す (パスに空白があれば `"` で囲む)
- `windowsT3Code` のホスト: `dotfiles apply` で、`t3-code-settings` (order 98) がこの文を `launchArgs` に書く。値ごと合わせるので、T3 の画面で
  変えても次の apply で戻る。書くのは `claude-t3` (order 50) の置いた 2 つのファイルがそろっているときだけで、そろっていなければ今の値を残し、
  ※ で知らせる (読めないファイルを渡すと、T3 はその会話の送信を失敗にする)。書いた後は T3 Code を開き直す (タスクトレイからも終える。
  [T3 Code](#t3-code) のほかの決めたキーと同じ)
- ほかのホスト: T3 の Settings → Providers → Claude → Launch arguments に、`claude-t3` が出した文を写して貼る。書くのは `dotfiles apply` で
  `claude-t3` がファイルを置いてから
- Launch arguments が変わった後と、`claude-t3` がファイルを置き直した後に効く時は、2 つのファイルで違う (`claude-t3` の check・apply も出す):
  - `settings.json` (`--settings`): claude の起動の flag なので、T3 の会話を開き直すと効く (開いている会話には効かない)
  - `CLAUDE.t3.md` (`--append-system-prompt-file`): T3 はターンごとにファイルを読み直して system prompt の後ろに足すが、Claude Code は会話の
    system prompt を最初の要求で記録し、resume でも次の compaction まで同じものを送る (claude の `systemPromptSnapshot` の既定)。そのため
    新しい会話から効く。今ある会話には、開き直しても次の compaction の後まで入らない
- 直すのは dotfiles の `win/claude-code/t3/` (置き先の写しを変えると、次の `dotfiles apply` が衝突として知らせる)
- 確かめるのは T3 の会話の skill の一覧 (herdr と hc のハブ・子の skill が無く、`pjp-t3-hub` がある)。herdr-app の会話の一覧には `pjp-t3-hub` が出ない
- T3 のハブの子は、つないだ Linux の環境に T3 のスレッドとして立てる (`pjp child new` は使わない。手順は claude-skills の `pjp-t3-hub`)。`CLAUDE.t3.md` もその向きで書く

### claude-personal・claude-work

Claude Code のログインを個人と会社のアカウントで分けるコマンド (Linux の `claude-personal`・`claude-work` と同じ考え。nix/README.md の
「[Claude Code のアカウントを分ける](../nix/README.md#claude-code-のアカウントを分ける-claude-personal--claude-work)」)。**分かれるのはログインだけ**で、
CLAUDE.md・skill・hook・設定・履歴と auto memory は素の `claude` (`%USERPROFILE%\.claude`) と同じものが効く。runner の手順 `claude-accounts`
(order 99。Windows にしか無い手順なので、受け持ちが WSL のホストでも `dotfiles apply` が流す) が用意する。on/off は道具の switch
`windowsClaudeAccounts` (グループ all なら既定で on、minimum では使うホストが書く。初回の apply で UAC の確認が出る) と `windowsClaudeCode` の両方
(経緯は dotfiles-private の ADR 081 (`docs/adr/081_win_claude_accounts_*`))。

| コマンド | 使う config dir | ログイン |
| --- | --- | --- |
| `claude` | `%USERPROFILE%\.claude` (今まで通り) | 今まで通り (Windows の素の claude は token を読まない。Linux は宣言 `dotfiles.claude.tokens.default` のあるホストで token) |
| `claude-personal` | `%USERPROFILE%\.claude-personal` | 個人のアカウント (初回に `/login`) |
| `claude-work` | `%USERPROFILE%\.claude-work` | 会社のアカウント (初回に `/login`) |
| `claude-<名前>` (`claude-account add` で足したもの) | `%USERPROFILE%\.claude-<名前>` | subscription は初回に `/login`。token は `claude setup-token` の token ([後述](#token-のアカウント-windows)) |

```powershell
dotfiles check --steps claude-accounts     # 差を見る (何も書かない。UAC の確認も出さない)
dotfiles apply --steps claude-accounts     # 揃える (初回は UAC の確認が 1 回出る)
# 初めて PATH に足した後は、新しい PowerShell で (herdr-app の中の端末なら herdr-app を上げ直してから)
claude-work                                # 初回は /login で会社のアカウント。/status で config dir とアカウントを見る
```

`claude-accounts` が置くもの:

| 置くもの | 形 |
| --- | --- |
| `.claude-<名前>\settings.json`・`CLAUDE.md` | `~/.claude` へのファイルの symlink。ファイルの symlink は管理者の権限か開発者モードが要るので、足りないものを全部のアカウントのぶん集め、直に張れなければ **UAC の確認 1 回**でまとめて張る (昇格した cmd の `mklink`)。足りていれば確認は出ない |
| `.claude-<名前>\projects` | `~/.claude\projects` への junction (履歴と auto memory。権限は要らない) |
| `.claude-<名前>\skills\`・`agents\`・`commands\`・`rules\` | 実体の dir。`~/.claude\<種類>` の中身を 1 つずつ写す (dir は junction、ファイルは記録つきのコピー。記録は `%LOCALAPPDATA%\dotfiles\state\claude-accounts.deployed.json`)。skills はリンク・`pjp-*`・runner が書く `hc`・`herdr-app` だけで、`synced`・`manifest.json` は写さない (Claude Code がアカウントごとに置く) |
| `.claude-<名前>\plugins\`・`.credentials.json`・`.claude.json` など | 実体。Claude Code が作る (触らない) |
| `%LOCALAPPDATA%\dotfiles\bin\claude-<名前>.exe`・`claude-account.exe` | runner の exe の写し (exe の名前で launcher・管理のコマンドとして動く)。置き場をユーザーの PATH の末尾に足す (`HKCU\Environment` の生の値に足す。値の型と、ほかの要素の `%VAR%` の書き方はそのまま) |

- launcher は `~/.claude-<名前>\settings.json` と `projects` が `~/.claude` の同じ名前へのリンクでなければ、Claude Code を起こさずに止まる (Claude Code は
  空の config dir に起動しただけで `projects\` などを実体で作り、runner がリンクを張れなくなる・履歴が分かれるため)。用意されていれば `ANTHROPIC_API_KEY`・
  `CLAUDE_CODE_OAUTH_TOKEN`・`ANTHROPIC_AUTH_TOKEN` (`/login` の資格情報より優先される env) を外し、`CLAUDE_CONFIG_DIR` を付けて PATH の
  `claude.exe` を起こし、その終了コードで終わる。exe なので PowerShell・Git Bash・cmd からも、`hc run` のように shell を通さない起こし方からも
  同じ名前で打てる
- Ctrl+C は Claude Code に任せる (launcher は Ctrl+C・Ctrl+Break を受け流すだけで、自分だけが落ちない)。launcher だけを外から止めると
  `claude.exe` は残る (端末を閉じれば両方終わる)
- UAC の確認を断った・出せない (SSH の会話・非対話) ときは、symlink の行だけを ⚠ にして、ほかは用意する。次の `dotfiles apply` でまた聞く。
  `check` と `apply --dry-run` は昇格しない。別の先を指す symlink は、昇格する前に外してから張り直す (断ると無いままになり、次の apply でまた聞く。
  外せなければ張らずに ⚠)
- **PATH に足しても、もう動いている process には効かない。** herdr-app とその中の端末・動いている Claude Code は古い PATH のままなので、
  初めて足した後は herdr-app を上げ直すか、新しい PowerShell で打つ
- launcher は runner の exe の写しなので、runner を作り直すと (clone を pull すると) `dotfiles check` が「書き直す」と出す。`dotfiles apply` で
  置き直す (会話の途中で動いている launcher は退けてから置き、退けたものは次に置くときに消す)
- アカウントごとに分かれるもの (Linux と同じ): `.claude.json` (repo ごとの「信頼する」の確認・MCP サーバーの設定)・↑ キーの入力履歴・
  巻き戻し・`plugins\`・`skills\synced\`。`claude-work` の会話の中で素の `claude` を打つと、`CLAUDE_CONFIG_DIR` が引き継がれて work で起動する
- `~/.claude` に skill や rule を足した・消したあと、薄い dir が追従するのは次の `dotfiles apply` から (rule などのファイルはコピーなので、
  中身が変わったときも同じ)
- Linux と違う所: settings.json と CLAUDE.md の symlink に管理者の権限が要る・projects は junction・rule などのファイルはリンクでなくコピー
  (ファイルの symlink にすると rule が増えるたびに UAC が要り、dir ごとの junction は Claude Code が実パスで見る所があるかを確かめていない)・
  plugin は入れない (Windows の settings.json に `enabledPlugins` が無い)・既定のアカウントの一覧は runner の中の固定 (`personal`・`work`。
  Linux の claude.nix と同じ。試験が突き合わせる)。足したアカウントは `claude-account` の登録 (下)
- 既定でも登録でもない名前の `claude-<名前>.exe` は起こさない (2。`claude-account add` を出す)

#### アカウントを足す (claude-account)

Linux の `claude-account` ([`nix/README.md`「アカウントを足す (claude-account)」](../nix/README.md#アカウントを足す-claude-account)) と同じ
サブコマンドと文。`claude-account.exe` は `claude-accounts` が launcher と一緒に置く runner の exe の写しで、PowerShell・Git Bash・cmd・
`hc run` から打てる (`dotfiles` 関数と違い、clone で cargo を流さない)。

```powershell
claude-account add token1 --mode token         # 登録・~/.claude-token1・claude-token1.exe を作り、token の置き方を出す (足りない symlink に UAC の確認が 1 回)
claude-account set-token token1                # token を見えない入力で入れる (DPAPI で暗号化して書く)
claude-account add sub2 --mode subscription    # /login で入るアカウント
claude-account list                            # 既定と登録のアカウントと、その状態
claude-account check token1                    # 0 = 使える / 1 = 用意が無い (stderr に手) / 2 = 知らない名前
claude-account check default                   # 素の claude (~/.claude) のログイン (~/.claude\.credentials.json の有る無し)
claude-account remove token1 [--purge]         # 登録と claude-token1.exe を消す (--purge なら ~/.claude-token1 と token のファイルと入れた時刻の控えも)
claude-account audit                           # token の置き場の宣言と、この PC の token・入れた時刻を値を見ずに並べる (後述)
claude-account help token [token1]             # token をこの PC とほかのマシンに置く手順
```

- 素の claude (`~/.claude`) は名前 `default` で扱う (`check default`・`list` の先頭の行)。Windows の素の claude は token を読まず `/login` で使うので、
  `set-token default` は 2。`add`・`remove` に `default` は使えない
- `set-token` は token を書いたあと、入れた時刻 (日本時間・秒まで) を `%USERPROFILE%\.local\state\claude-accounts\tokens.json` に控える (Linux と同じ形。
  値は置かない)。控えが読めない形なら、token を読む前に止まる

- 登録は**マシンごと** (`%USERPROFILE%\.config\claude-accounts\accounts.json`。Linux と同じ形)。Linux のマシンの子でも使うなら、そのマシンで
  add と set-token を打つ
- add は登録に書いたあと、手順 `claude-accounts` をそのアカウントのぶんだけ流す (dir・symlink・`claude-<名前>.exe`。足りない symlink は
  `dotfiles apply` と同じく、1 つ目を直に張ってみて落ちたら UAC の確認 1 回で張る)。UAC を断った・出せない (SSH の会話) ときは ⚠ を出して 1 で
  終わり、add の打ち直しか次の `dotfiles apply` でまた聞く
- `dotfiles apply` は、既定に加えて登録のアカウントの dir と launcher も保つ (launcher は runner の exe の写しなので、runner を作り直したら
  置き直す。Linux の link と違い、消えていれば置く)。登録が読めない形なら、既定だけを用意して ⚠。既定の `claude-personal`・`claude-work` は
  登録を読まないので、登録が壊れていても起きる
- `remove` は `claude-<名前>.exe` が動いている (会話が開いている) と消せないので、登録を変えずに 1 で止まる。閉じてから打ち直す。`--purge` は
  `~/.claude-<名前>` を、中の junction・symlink を辿らずに消す

#### token のアカウント (Windows)

| token のファイル `%USERPROFILE%\.config\claude-accounts\<名前>.env` の値 | 読み方 |
| --- | --- |
| DPAPI の暗号文 (`claude-account set-token` が書く) | System32 の `powershell.exe` で復号して渡す (既定。確認は出ない)。このユーザーとこの PC でだけ読める |
| `op://…` (1Password の参照) | 起こすたびに op-reason.exe (`--reason <理由> read <参照>`) で読む。1Password の承認と一緒に、理由と読む参照の窓が出る。op-reason.exe が無ければ op.exe に落とさずに止まる |
| token そのもの (手で書いた平文) | そのまま渡し、`set-token` で入れ直す (DPAPI) よう 1 行出す |

- ファイルの形・止まる行・token が無いときの忠告は Linux と同じ ([`nix/README.md`「token のアカウント」](../nix/README.md#token-のアカウント))
- `set-token` は Windows PowerShell の `Read-Host -AsSecureString` (パイプなら stdin の 1 行) で読み、形を確かめて (空・`op://`・token の形で
  ないものは書かない)、`ConvertFrom-SecureString` の暗号文だけを書く。平文は PowerShell の中だけにある。DPAPI の暗号文は、ほかのユーザー・
  ほかの PC・ディスクの写しでは読めない (同じユーザーの process は読める)
- **Git Bash (mintty) では `set-token` を打たない。** 見えない入力にできない (打った token が画面に出る) ので、読まずに止まる。PowerShell・
  Windows Terminal で打つか、`winpty claude-account set-token <名前>` で打つ。パイプ (`… | claude-account set-token <名前>`) はどこでも使える
- 復号と set-token の PowerShell は System32 の Windows PowerShell 5.1 で、受け継いだ `PSModulePath` を外して起こす (pwsh 7 から打っても
  `ConvertTo-SecureString` を読めるように)
- op-reason.exe は PATH か `%LOCALAPPDATA%\Programs\op-reason` (WSL の setup の `Install-OpReason` が入れる所) から探す。Smart App Control に
  止められるマシンの PowerShell の入口への回り道は、まだ無い (`set-token` でこの PC に置く)
- token の会話の注意 (Remote Control・connector・`/login`・`auth status`・env を出さない) と、シークレットの決まりの例外・漏れたときは Linux と同じ

#### claude の token の置き場の宣言 (`[claude.tokens]`)

`claude setup-token` の token (1 年有効) をこの PC のどのアカウントに置いたかを、ホストの値に書く (Linux の `dotfiles.claude.tokens` と同じ名前と形。
[`nix/README.md`「claude の token の置き場を宣言する」](../nix/README.md#claude-の-token-の置き場を宣言する-dotfilesclaudetokens))。値 (token) は書かない。
設計は dotfiles-private の ADR 123 (`docs/adr/123_claude_token_watch_*`)。

```toml
[claude.tokens.alt]                                # claude-account add alt --mode token で足したアカウント
label = "alt"                                      # token の呼び名。同じ token を置いたホスト・アカウントで同じにする。書かなければアカウントの名前
item = "op://<vault の ID>/<項目の ID>/<欄の ID>"   # 元の token の 1Password の参照。欄まで書く。分かるまで書かない (null)
```

| キー | 値 |
| --- | --- |
| `tokens` の下の名前 | アカウントの名前 (claude-account の名前と同じ形。英小文字・数字で始め、英小文字・数字・`-` と `_` だけで 32 字まで。`account`・`selector` は使えない)。素の claude の `default` は書けない (Windows の素の claude は token を読まない) |
| `label` | token の呼び名 (英小文字・数字で始め、英小文字・数字・`.`・`-`・`_` だけで 64 字まで)。書かなければアカウントの名前 |
| `item` | 元の token を置いた 1Password の参照。欄まで書く: `op://<vault の ID>/<項目の ID>/<欄の ID>` (セクションがあれば `op://<vault>/<項目>/<セクション>/<欄>`)。書かなければ null |

次のときは runner が止まる (終了コード 2): 名前の形が違う・`default`・表でない値・知らないキー・`label` の形が違う・`item` が欄まで書いた `op://` の参照でない
(値そのものを書いたときも)。止める文には、規則に合わない名前・`label`・`item`・知らないキーの字を出さない (名前は数だけ。Nix の
`nix/lib/claude-tokens.nix` と同じ見方に、Nix では型が見るものと `default` を足したもの)。

手順 `claude-tokens` (order 99。`windowsClaudeAccounts` と `windowsClaudeCode` のホスト) は、check・dry-run・apply のたびに
`%USERPROFILE%\.local\state\dotfiles\claude-tokens.json` を宣言に揃える (Linux と同じ中身。宣言が無くても `{"accounts":{}}`。check と dry-run は書かない)。
token のファイルは見ない。

```powershell
dotfiles check --steps claude-tokens      # claude-tokens.json が宣言と同じかを見る (何も書かない)
dotfiles apply --steps claude-tokens      # 書く
claude-account audit                      # 棚卸し (下)
```

`claude-account audit` は、宣言と、この PC の登録の token のアカウント・token のファイル・入れた時刻の控えを和にして、アカウントごとに置き方・ACL・入れた時刻と
経った日数を値を見ずに並べ、判定を出す。表・判定・終了コード (0 = 手を入れるものが無い / 1 = ある / 2 = 宣言・登録・控えを読めない) は Linux と同じ
([`nix/README.md`「棚卸し (claude-account audit)」](../nix/README.md#棚卸し-claude-account-audit))。Windows で違うのは次だけ:

- 頭の行のホストは `<PC の名前> (Windows)`
- 置き方は `ローカル (DPAPI)`・`ローカル (平文)`・`1Password`・`無い`・`空`・`形が違う`。平文は直す (`claude-account set-token <名前>` で入れ直すと DPAPI の
  暗号文になる)
- 権限の列は mode でなく ACL の要約 (`ACL 本人だけ`・`ACL SYSTEM・Administrators・本人`・`ACL 広い`・読めなければ `?`)。DPAPI と平文の token の
  ファイルを、本人・SYSTEM・Administrators のほかも読める・ACL を読めないなら直す。読み方と「広い」の数え方は手順 `notion-tokens` と同じ
  (PowerShell の `Get-Acl`。runner は ACL を書き換えない)
- 宣言の無い token の置き場の宣言漏れは、`[claude.tokens.<名前>]` に足すよう出す。素の claude の `default.env` があれば宣言漏れ (Windows の素の
  claude は読まない)

```text
claude-account audit: EXAMPLE-PC (Windows) (2026-11-28 21:00 JST・入れてから 330 日を超えたら回す)
宣言: ~/.local/state/dotfiles/claude-tokens.json (1 件)
控え: ~/.local/state/claude-accounts/tokens.json (1 件)

| アカウント | 呼び名 | 1Password の参照 | 置き方 | 権限 | 入れた時刻 | 日数 | 判定 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| alt | alt | - | ローカル (DPAPI) | ACL 本人だけ | 2026-11-18 21:00 | 10 | ok |

呼び名が同じ行は、ほかのホストの同じ呼び名の行とも同じ token。回すときは、その全部のホストで貼り直す。
判定: ok 1・回す 0・入れる 0・直す 0・宣言漏れ 0
```

#### 既に ~/.claude-<名前> があるとき

`$env:CLAUDE_CONFIG_DIR = "$HOME\.claude-work"; claude` のように先に起動していると、Claude Code が `settings.json` や `projects\` を実体で作って
いる。runner は実体を上書きせず (⚠ で知らせる)、launcher も「リンクではありません」と言って起動しない。片付けてから流し直す。

```powershell
$d = "$HOME\.claude-work"                         # claude-personal なら .claude-personal
Get-Content "$d\settings.json"                    # 残したい設定は ~/.claude\settings.json へ移す
Remove-Item "$d\settings.json"
(Get-Item "$d\projects").LinkType                 # 空 (実体) のときだけ次の 2 行を打つ
robocopy "$d\projects" "$HOME\.claude\projects" /E /XC /XN /XO /R:1 /W:1   # ~/.claude\projects へ寄せる (同じ名前のファイルは上書きしない)
if ($LASTEXITCODE -lt 8) { Rename-Item "$d\projects" projects.bak }        # 消さずに退ける (robocopy が落ちたら退けない)
dotfiles apply --steps claude-accounts
```

同じ名前で中身の違うファイル (`memory\*.md` など) は写さないので、`projects.bak` に残る。`~/.claude\projects` の同じ名前のものと見比べ、
要るものを移してから `projects.bak` を消す (`cmd /c rmdir /s /q "$d\projects.bak"`)。ログイン (`.credentials.json`・`.claude.json`) と `plugins\` は
そのまま残してよい (`/login` し直さなくてよい)。`CLAUDE.md` が実体のときも、
中身を見てから消す (共通の指示は dotfiles の `nix/files/claude/CLAUDE.md` に書く)。

#### switch を外したとき

`windowsClaudeAccounts = false` にしても、作ったものは消さない (runner が見なくなるだけ)。外すなら:

- `%LOCALAPPDATA%\dotfiles\bin\claude-*.exe` (`claude-account.exe` も) を消し、ユーザーの PATH から `%LOCALAPPDATA%\dotfiles\bin` を外す
  (`rundll32 sysdm.cpl,EditEnvironmentVariables` の「ユーザー環境変数」の Path)。`claude-selector.exe` は手順 `claude-selector` のもの
  (`windowsClaudeCode` で on/off。[claude-selector (cs)](#claude-selector-cs)) なので、cs を使い続けるなら残し、PATH も外さない
- `~/.claude-<名前>` を消すと、そのアカウントのログインも消える。中の junction は `cmd /c rmdir` で外し (先は消えない)、Windows PowerShell 5.1 の
  `Remove-Item -Recurse` を junction に打たない (先の中身まで消すことがある)

### claude-selector (cs)

`cs` (PowerShell の function と略語。中身は `claude-selector`) は、組み立てる claude のコマンド行をいつも見せ、その項目 (アカウントと option) を
矢印キーで選んで Claude Code を起こす。Linux の `cs` と同じ crate (`nix/pkgs/claude-selector`) の同じ画面で、選べるもの・既定・キーは
nix/README.md の「[アカウントと option を矢印キーで選んで起こす (claude-selector)](../nix/README.md#アカウントと-option-を矢印キーで選んで起こす-claude-selector)」
と同じ。設計は dotfiles-private の ADR 087 (`docs/adr/087_claude_selector_*`) と、画面と引数の並びを作り替えた ADR 116
(`docs/adr/116_claude_selector_command_line_ui_*`)。

```powershell
dotfiles check --steps claude-selector     # 置いた exe が今の元のものか (cargo を打たない。何も書かない)
dotfiles apply --steps claude-selector     # 作って置く (初めては crossterm などの依存も作るので 1 分ほど)
# 初めて PATH に足した後は、新しい PowerShell で (herdr-app の中の端末なら herdr-app を上げ直してから)
cs                                         # 選んで起こす。cs -c・cs "質問" の後ろの引数は、組み立てた引数の後ろにそのまま付く
```

- runner の手順 `claude-selector` (order 99。Windows にしか無い手順なので、受け持ちが WSL のホストでも `dotfiles apply` が流す。on/off は
  `windowsClaudeCode`) が、clone の `nix/pkgs/claude-selector` を runner と同じ toolchain (`runner/rust-toolchain.toml` の版を
  `RUSTUP_TOOLCHAIN` に付ける) で `cargo build --release --locked` し (置き場は crate の `target\`)、`%LOCALAPPDATA%\dotfiles\bin\claude-selector.exe`
  に置いて、置き場をユーザーの PATH の末尾に足す (claude-<名前>.exe と同じ置き場。動いていれば退けてから置く)
- 作り直すかは、crate の元 (`Cargo.toml`・`Cargo.lock`・`src\` の下の全部) と toolchain の版の SHA-256 を、置いた exe の SHA-256 と組で
  `%LOCALAPPDATA%\dotfiles\state\claude-selector.built.json` に控えて決める。元・toolchain・置いた exe のどれかが変わっていれば、`dotfiles check` が
  「作り直して置く」と出し、`dotfiles apply` が作り直す。作れなければ (cargo が落ちた) この手順だけが落ち、置いてある exe と控えはそのまま
- cargo が無いホスト (Build Tools と rustup を入れない minimum の PC。runner は配った exe で動く) では、作り直しが要っても作らず、`·` で
  「cs を使うなら `Install-Bootstrap.ps1 -Rust` で Build Tools と rustup を入れる」と知らせる (PATH にも触らない。置いてある exe が今の元のものなら ✔)。
  cs の exe も runner と同じ Release で配るのは、後続の PR (dotfiles-private の ADR 117)
- claude-<名前>.exe・claude-account.exe と違って runner の exe の写しにしないのは、画面の crate (crossterm とその依存) を runner に入れず、
  selector の `Cargo.lock` を Linux の Nix と同じ 1 つにするため。`claude-accounts` の外に置くのは、`windowsClaudeAccounts` が
  off のホストでも素の `claude` を選んで起こせるようにするため
- アカウントの並びは、既定 (`personal`・`work`。runner の `claude-accounts` と同じ。試験が突き合わせる) のあとに `claude-account` の登録
  (`%USERPROFILE%\.config\claude-accounts\accounts.json`) を名前の順。launcher (`claude-<名前>.exe`) が PATH に無いアカウントは選べない
  (`windowsClaudeAccounts` が off のホストでは、素の `claude` だけを選べる)
- 起こすときは、選んだ `claude.exe` か `claude-<名前>.exe` (launcher) を子 process で起こして待ち、その終了コードで終わる (Windows に exec が
  無いため。launcher と同じ)。Ctrl+C は Claude Code に任せ、claude-selector は受け流すだけで、自分だけが先に落ちない。選ぶ画面の Esc・Ctrl+C は
  何も起こさずに 130 で終わる
- 見せるコマンド行は PowerShell の書き方で囲む (`'質問 です'`)。起こすのは argv のままなので、引用は見せるためだけ
- `selector` はアカウントの名前に使えない (`claude-account add selector` は断る。`claude-<名前>.exe` の launcher が `claude-selector.exe` を
  上書きするため)

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
| `config` | git.toml の `[settings]`・`[user]` (`gitIdentity` が true のとき)・`[filter "lfs"]`・`core.sshCommand` (下の表) を home-manager と同じ形 (節とキーは名前の順) で並べ、`gitIdentity` なら後ろに owner ごとの `[includeIf "gitdir/i:~/ghq/github.com/<owner>/"]` |
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
| `core.sshCommand` | 書かない | Windows の OpenSSH の `ssh.exe`。`%ProgramFiles%\OpenSSH\ssh.exe` (`Install-OpenSSH` が winget で入れる版) があればそれ、無ければ `%SystemRoot%\System32\OpenSSH\ssh.exe` (Windows の機能の版) を、`'C:/Program Files/OpenSSH/ssh.exe'` の形 (`/` 区切りで `'…'` に囲む。git は値を shell で起こす) で書く。どちらも無ければ書かずに ⚠ で知らせる (無い exe を書くと ssh の remote が全部起こせなくなる) | 無いと git は Git for Windows 付属の MSYS の ssh (`C:\Program Files\Git\usr\bin\ssh.exe`) を使う。MSYS の ssh は Windows の named pipe の agent (1Password の `\\.\pipe\openssh-ssh-agent`・op-reason の中継 `\\.\pipe\op-reason-ssh-agent`) に届かず、`ssh-add -l` では鍵が見えるのに `git pull` (`git@github.com:…` の remote) が `Permission denied (publickey)` で落ちる。中継を使わないホスト (`opReasonSshRelay` が off) にも書く。git.toml には書けない (Linux の git に効かせない。書けば runner が止まる) |
| credential helper | 書かない | 書かない | bootstrap が gh に書かせない決まりと、`claude-env` が settings.json の env に足す組を壊さない |

- 置き方は `CLAUDE.md` と同じ記録つきのコピー (`%LOCALAPPDATA%\dotfiles\state\git-config.deployed.json`)。git.toml が変われば `dotfiles apply` で書き直す。
  Windows 側で変わった・記録の無い違う中身は衝突で飛ばして ⚠ で知らせる (dotfiles の git.toml へ取り込むか、`dotfiles apply --steps git-config --force` で
  上書き)。書かなくなったファイル (`gitIdentity` を外したときの `config.<owner>`) は、中身が記録どおりなら消す
- `~/.gitconfig` が無いと、`git config --global` (gh の `auth setup-git` なども) はここの `config` に書き、次の `dotfiles check` が衝突で知らせる。Windows だけの
  設定は `~/.gitconfig` に書く (`git config --file "$HOME\.gitconfig" <キー> <値>`)。git は `~/.config/git/config` の後に `~/.gitconfig` を読むので同じキーは
  `~/.gitconfig` が勝ち、`~/.gitconfig` があれば `git config --global` もそこへ書く。`~/.gitconfig` がある間は、締めの表の ※ にそう添える
- 入れたての Windows 11 には Windows の機能の版 (`System32\OpenSSH`) が既定で入っていて、winget の版は同じ apply の手順 `openssh` (order 96。
  `windowsOpenssh` が on のホストだけ。off のホストは Windows の機能の版のまま) が後から入れる。そこで apply は、`openssh` の後に、置いた `config` (記録どおりのもの) の `core.sshCommand` が今選ぶ `ssh.exe` と違えば `git-config` をもう一度
  流す (見出しに「(openssh の後に流し直す)」と出て、締めの表の git-config の行は「openssh の後に流し直した: 」の行に置き換わる)。受け持ちが runner のホストなら、入れたての Windows でも
  1 回の apply で揃う。順は 50 のまま (ハブを作る `hc-hub` (60) の `pjp hub init` の commit を、ここで書く名前とメールにする。ADR 066)。check と dry-run は
  流し直さないので、Windows の機能の版を選んだときは、その行に「apply の手順 openssh (96) が winget の版を入れた後に書き直す」と添える
- `core.sshCommand` を書くようになる前に置いた `config` も、中身が記録どおりなら次の `dotfiles apply` で書き換わる (衝突にならない)。`OpenSSH` を後から入れた・
  消したときも同じく書き換える。Claude Code の会話の git は `claude-env` の env (`GIT_CONFIG_*`) で GitHub の ssh の URL を https に読み替えるので、GitHub
  には ssh を使わない (この値に左右されない。GitHub の外の ssh の remote にはこの値が効く)
- `gitIdentity` が false のホスト (自社・客先) には名前もメールも書かない (WSL と同じ。git は commit の前に止まる)。そのホストで使う名前とメールは `~/.gitconfig` に書く
- `core.autocrlf = false` が Git for Windows の system の `true` より先に効く (WSL と同じく、取り出すときに LF を CRLF にしない)。repo に `core.autocrlf` を
  書いていない既にある clone のうち、作業ツリーが CRLF で取り出されたものは、触ったファイルが変わったように見えることがある (`git ls-files --eol` の
  `i/lf w/crlf` の行)。その repo に `git config core.autocrlf true` を書けば今までどおり。bootstrap の clone は repo に `false` を書いてある
- git は `XDG_CONFIG_HOME` があれば `%XDG_CONFIG_HOME%\git\config` を、無ければ `$HOME\.config\git\config` を読む。どちらかの環境変数で git が別の場所を
  読むなら ⚠ で知らせる (ここに置いた設定は効かない)

### herdr-app の mod

dotfiles の自作の herdr-app の mod (`herdr-app/mods/<名前>/`) を、herdr-app の home の `mods\<名前>\` に置く手順 `herdr-app-mods`。herdr-app は
Windows だけなので Windows にしか無い手順で、受け持ちが WSL のホストでも `dotfiles apply` が流す (ホストの値は要る。on/off は herdr-app を入れる
手順と同じ `windowsHerdr`)。経緯は dotfiles-private の ADR 068 (`docs/adr/068_win_herdr_app_mods_*`)。

```powershell
dotfiles check --steps herdr-app-mods             # 差を見る (何も書かない)
dotfiles apply --dry-run --steps herdr-app-mods   # することを出す
dotfiles apply --steps herdr-app-mods             # 置く
```

| mod | 置くファイル | 中身 |
| --- | --- | --- |
| `pjp-hub-panel` | `main.js`・`mod.json`・`ring.svg`・`copy.svg` | ハブの Claude がユーザーに見せる panel。ハブの端末の横のペインに、質問 (選んで送る)・チケット・進み具合・PR の木 (チケットの下に進み具合の段と PR を 1 段下げて並べる。`answer` のある段は押してハブへ送れる)・ユーザーの問いへの答え (Q&A。問いごとに開け閉めし、項目ごとに消す印を付けられる)・状況の説明 (markdown。絵だけの行で項目の下に小さな絵も)・進み具合 (段の並び)・チケットと PR の一覧・図 (SVG と、その上に重ねる動き: 一方向に流れる点・点滅する枠・行って戻る点・文字) を出す。済んだもの (Done・Canceled のチケット・merged と closed の PR・done の段・`done: true` の節) は、消さずに小さな字で出し (済んだ行の ID と題は薄い色)、チケットの行と節は初めから畳む。チケットの行の ID の右のボタンで、ID だけをクリップボードへ写せる。props の `role` で「まとめ」(状況) と「問い」の 2 つのペインに分けて開け、問いのペインは送信すると自分で閉じる。図はペインの幅に合わせて縮め・大きくし、クリックすると大きく見る小窓で開く。答えは問いごとに 1 行にし、改行で区切って `hc send` で送る (「入力欄に入れる」はクリップボードから貼る)。上の行の `−`・`+` で panel の文字だけを上げ下げでき、大きさは herdr-app を上げ直しても残る。props・panel.json の形・図の置き場所と大きさ・文字の大きさ・罠の正本は `main.js` の頭のコメント |
| `pjp-prefix` | `main.js`・`mod.json` | 旧 herdr の prefix (`Ctrl+K`) の小窓。keys.json の `Ctrl+K` が開き、次の 1 キーで分割・タブ・worktree などの命令を流して閉じる ([次節](#herdr-app-のキー))。キーの一覧と命令の正本は `main.js` の頭のコメントと `BINDINGS` |
| `pjp-worktree-remove` | `main.js`・`mod.json` | prefix の後の `d` と `Ctrl+Q` が開く確かめの小窓 (window)。今の space の端末を全部止め、終わるのを待ってから space を閉じて worktree を消す ([次節](#herdr-app-のキー))。止める端末・待つ上限・やり直し・残ったフォルダの扱いの正本は `main.js` の頭のコメント |
| `pjp-sidebar-tabs` | `main.js`・`mod.json`・`spaces.svg`・`agents.svg` | 左のサイドパネルの Spaces と Agents を切り替える、上端のアイコンのタブ (layout pjp-main の stack `sidebar-lists` の header。layout に置くのは `herdr-app-pjp-spaces`)。選んでいるタブはアイコン + 名前、ほかはアイコンだけで、Agents のタブに blocked の agent の数の印を出す。Agents を出していない間は、agents の一覧の順 (`agent.next` の順) を代わりに渡す ([サイドパネルのタブ](#サイドパネルのタブ-pjp-sidebar-tabs))。herdr-app の決まりと見た目の正本は `main.js` の頭のコメント |

- herdr-app の home は `HERDR_APP_HOME` → `%XDG_CONFIG_HOME%\herdr-app` → `%USERPROFILE%\.config\herdr-app` の順に決める (`Install-HerdrApp.ps1` の
  置き場所と同じ)。どれにしたかは手順の出力の頭に出る
- 置き方は `CLAUDE.md` と同じ記録つきのコピー (`%LOCALAPPDATA%\dotfiles\state\herdr-app-mods.deployed.json`)。手で置いた同じ中身は引き取り (記録だけ
  作る)、Windows 側で変わった・記録の無い違う中身は衝突で飛ばして ⚠ で知らせる (dotfiles の `herdr-app/mods/` へ取り込むか、
  `dotfiles apply --steps herdr-app-mods --force` で上書き)。repo から消したファイルは、中身が記録どおりなら消す。repo から mod を丸ごと消しても、
  置き先の mod のフォルダ (herdr-app が書いたファイルが残る) は消さないので、要らなければ手で消す
- herdr-app は mod のフォルダを見張っていて、ファイルを保存すると mod を読み直す (herdr-app が書くファイルと、名前が `.` で始まるものは除く)。
  clone を pull したら `dotfiles apply` で配り直す
- herdr-app (gpui-shell) は mod を読むと、`gpui-kit.d.ts` (約 800 KB。gpui-kit を import するディレクトリごとに毎回書き直す) と `jsconfig.json` (無ければ
  1 度だけ書き、その後は書き直さない) を mod のフォルダに書く。runner はどちらもどの深さでも配らず、置き先のものにも触らない。repo にも入れない
  (`herdr-app/mods/.gitignore`。Windows の mod のフォルダから写し戻すときに混ざらないように)。名前が `.` で始まるもの (エディタの設定など) も配らない
- 置き先の mod のフォルダがリンク (手でつないだ場所) なら、その mod には触らない。home のほかの場所 (下の図の置き場など) にも触らない
- mod は Windows で確かめたバイト列のまま repo に置く (`.gitattributes` の `-text`。commit でも取り出しでも改行を変えない)
- mod を直すときは、Windows の置き先で直して `herdr-app check <mod のフォルダ>` で確かめてから `herdr-app/mods/<名前>/` に写し戻し、PR を出す (merge の
  後に pull して `dotfiles apply` を流すと、中身が揃って記録だけが変わる)。Windows の `herdr-app check` は素で打つと何も出ないので、終了コードと出力を
  受けて見る:

```powershell
$mod = Join-Path $HOME '.config\herdr-app\mods\pjp-hub-panel'   # 確かめる mod のフォルダ (HERDR_APP_HOME を置いていれば、その下)
$p = Start-Process herdr-app -ArgumentList ('check "{0}"' -f $mod) -NoNewWindow -Wait -PassThru `
    -RedirectStandardOutput "$env:TEMP\herdr-app-check.out" -RedirectStandardError "$env:TEMP\herdr-app-check.err"
$p.ExitCode; Get-Content "$env:TEMP\herdr-app-check.out", "$env:TEMP\herdr-app-check.err"   # 0 と「check passed」。落ちたらわけが出る
```

- ほかの herdr-app の命令 (`status`・`ls`・`do …`・`shot`) も、PowerShell では出力を pipeline の次のコマンドへ流して待つ (`herdr-app status | Out-String`・
  `herdr-app status | ConvertFrom-Json`・`$r = (herdr-app do … | Out-String).Trim()` の後で `$LASTEXITCODE`・`herdr-app shot <png> | Out-Null`)。herdr-app.exe は
  GUI の exe (PE の subsystem が 2) で、PowerShell は GUI の exe を、出力を pipeline に流すときにだけ終わりまで待つ。行に単独で打つ・
  `$x = (herdr-app …)`・`$null = herdr-app …` は待たずに次へ進み、出力は空・`$LASTEXITCODE` は前のコマンドの値のままで、herdr-app は後から書こうと
  して `failed printing to stdout: … (os error 232)` で panic する (2026-11-18。herdr-app 0.1.15・pwsh 7)。`check` は上の `Start-Process -Wait` の形でよい

ハブの panel (`pjp-hub-panel`) の使い方 (ハブの Claude がすること。手順の正本は claude-skills の pjp-hc-hub の `references/panel.md`):

```powershell
# 会話の scratchpad に panel.json を書き、まとめのペインを開く。split は right と down だけなので、ハブの端末を right に split してまとめの
# ペインを開き、pane.swap でハブの端末の左へ移す ([まとめ 1/2 | ハブの端末 1/2])。出力の pane (まとめのペインの ID) を控える
# (PowerShell 7.3 以降。Windows PowerShell 5.1 は外のコマンドに渡す引数の中の " を落とす)。ユーザーが見ている tab では split がキーボードを
# 新しいペインへ移すので、split のたびに pane.focus で前のペインへ戻す (戻し方は references/panel.md。下の箇条)
herdr-app do pane.split '{"direction":"right","pane":"<ハブの端末のペイン>","mod":"pjp-hub-panel","props":{"file":"<panel.json の絶対パス>","terminal":"<答えを送る端末>","role":"summary"}}' | Out-String
herdr-app do pane.swap '{"pane":"<まとめのペイン>","target":"<ハブの端末のペイン>"}' | Out-String
# 問いを出すとき: panel.json に questions を書き、ハブの端末を right に split して問いのペインを開く ([まとめ 1/2 | ハブの端末 1/4 | 問い 1/4])。
# 出力の pane (問いのペインの ID) を控える
herdr-app do pane.split '{"direction":"right","pane":"<ハブの端末のペイン>","mod":"pjp-hub-panel","props":{"file":"<panel.json の絶対パス>","terminal":"<答えを送る端末>","role":"questions"}}' | Out-String
# 答えを受けたとき・問いを取り下げるとき: 問いのペインが残っていれば、控えた ID で閉じる (JSON でなく --pane <ID> の形。pane を省かない)
herdr-app do pane.close --pane '<問いのペイン>' | Out-String
```

- 並び: ふだんは [まとめ | ハブの端末] の 1:1。問いのペインはハブの端末の右に開き ([まとめ 1/2 | ハブの端末 1/4 | 問い 1/4])、問いのペインが
  閉じると、その幅は左隣のハブの端末へ戻って 1:1 に戻る。herdr-app (0.1.15) は閉じたペインの幅を左隣のペインへ渡すので、問いのペインを
  端末の左に置くと (split してから swap)、閉じた幅がまとめへ行き [まとめ 3/4 | ハブの端末 1/4] になる (2026-11-18 にハブの tab で試した)
- `pane.swap` は 2 つのペインの場所だけを替え、キーボードは動かさない (mod のペインでも `{ "ok": true }` で返る)。`pane.split` は、ユーザーが
  見ている tab ではキーボードを新しいペインへ移すので、ハブは split の後に `pane.focus` でハブの端末へ戻す (手順は `references/panel.md`)
- `role` は `summary` (まとめ: title・updated・sections だけ)・`questions` (問い: questions だけ。空なら「問いはありません」) のどちらか。省くと
  role を足す前と同じく、問いと状況を 1 つのペインに出す。どの role のペインも、開いたときに自分からはキーボードを取らない
- 問いがあるときの答えの欄は、上の行 (題・更新の時刻 | 文字の大きさの組) のすぐ下に出す。欄の 1 行目がわけの字と、右寄せの「入力欄に入れる」「送信」
  (右上)、その下が答えの文。その下の問いの一覧だけがスクロールする。herdr-app の通知 (toast) は窓の右下に出るので、ペインの下端に置くと問いのペインの「送信」と重なる
- 問いのペインは、「送信」(ペインの Enter も) で送れたら自分を閉じ、ユーザーがその時にハブの端末のある tab を見ていれば、キーボードをハブの端末
  (`terminal`) へ戻す (別の space・tab を見ていれば戻さない。`pane.focus` は端末のある space へ画面を移すので、ユーザーを引き戻さない)。mod は自分のペインの ID を
  知る手段が無いので、送信の頭で、この panel がキーボードを持つとき (handle の `is_focused()`) にキーボードのあるペインを控え、それが端末を持たない
  `pjp-hub-panel` (写しの `pjp-hub-panel-<何か>` も) のペインだと確かめられたときだけ閉じる。確かめられなければ閉じずに「送った (閉じるのはハブ)」と
  出す。そのときと、「入力欄に入れる」で入れたとき・端末で直に答えたときは問いのペインが残るので、ハブは答えを受けたら控えた ID で閉じる
- `pane.close` は `--pane <ID>` の形で打つ (JSON を引用符で包んで渡したら効かなかった)。`pane` なしで打たない。今キーボードのあるペインを閉じ、それが
  端末のペインならその端末が終わる (ハブの端末なら会話ごと終わる)。閉じる前に `herdr-app ls | Out-String` で、その ID が端末の行に出ていないことを確かめる (panel の
  ペインは ls に出ない。出ていれば端末のペイン)
- panel の文字の大きさは、どの role のペインでも上の行 (題・更新の時刻の行) の `− <今の %> +` で変える。1 回で 10% ずつ、70%〜200%。% を押すと既定 (100%) に
  戻る。100% は前の固定の大きさ (本文 13px など) の 1.2 倍で、字と札・ボタンの大きさが同じ倍率で変わり、カードの余白と図 (ペインの幅に合わせる) は変わら
  ない。`− % +` の組はいつも 100% の大きさで右上に留まる (押してもボタンが動かない)。大きさは herdr-app の shared の `pjp-hub-panel.textPercent` (整数の %) に
  残るので、どの space の panel も、後から開いた問いのペインも同じ大きさで出て、herdr-app を上げ直しても残る。変わるのは panel の文字だけで、アプリの zoom
  (`settings.json` の `zoom`・`Ctrl+=` などのキー) と端末・ほかの mod は変わらない。ペインが狭いときは、題と更新の時刻、答えの欄のボタンが折り返す
- panel は panel.json のフォルダを見張って読み直す。答えは問いの順に 1 つ 1 行にし、改行でつなぐ。「送信」かペインの Enter では、mod が `hc send`
  を 1 回打って答えをハブの端末へ送る (hc が 1 回で貼り、Enter も押す)。クリップボードは使わず、フォーカスも動かさない (別の space にいても画面が戻らない。
  問いのペインが閉じた後にキーボードを戻すのは、上の箇条のとおりハブの端末のある tab を見ているときだけ)。
  端末の外 (herdr-app) から打つ `hc send` なので、届く文に `<hc from=…>` の札は付かない。複数行の答えが Claude Code の入力欄に 1 つの入力として入るのは、
  hc が bracketed paste で貼ることを当てにしている。`terminal.paste` で貼ってから `hc keys` で Enter を押す形にしないのは、`terminal.paste` が端末への
  人の入力に数えられ、`hc keys` が 3 秒の静けさを待つので、Enter が遅れるため
- エージェントが人を待っている (status が `blocked`。許可・問いの画面) 端末には、`hc send` が打たずに断る (終了コード 9)。panel はわけを出して止まる
  (ほかのわけで断られたら hc の error の message を出す)。人がハブの端末に打ちかけの文を残していると、`hc send` はそれが送られるか消されるまで待つ
  (人の最後のキーから最長 60 秒)。hc は最後の Enter (か Ctrl+C・Ctrl+U) の後に押された字を、画面によらず打ちかけと数えるので、確かめの画面にキーで
  答えた後などは、入力欄が空でも待つ。送るのが 4 秒を超えたら、panel はわけと手 (入力欄の文を送るか消す。空ならハブの端末で Enter を 1 回押す) を出す。
  herdr-app は 30 秒で hc を止めるので、それより長く待つと panel は「届いたか分からない」とわけを出して止まる (打つ前に止めたら hc は打たない。
  打った後に止めたら届いている)
- 「入力欄に入れる」は、答えを herdr-app の `write_to_clipboard` でクリップボードに入れ、ハブの端末にフォーカスを移して 1 回で貼る (`terminal.paste`。
  Enter は押さない)。貼る前に `hc get --json` で端末を見て、`blocked` ならクリップボードにも入れずに止める。`write_to_clipboard` は入れられなくても
  知らせないので、入れた字を読み返し、違えば 3 回まで入れ直し、それでも違えば貼らずにわけを出す。写しのペイン (まとめと問いのペイン) が同時に送らないよう、
  送っている間 (送信も入れるのも) は
  herdr-app の shared の `pjp-hub-panel.sendingUntil` に時刻を置き、ほかのペインはその間は送らずにわけを出す (送り終えたら外す。herdr-app が途中で
  落ちても 35 秒で外れる)
- チケットの行 (チケットの一覧の行と、木の `kind` が `ticket` の行) の ID の右に、小さなコピーのボタンを出す (PR・item の行には出さない)。押すと
  ID の字 (前後の空白を除く) だけを、herdr-app の `cx.write_to_clipboard` で押した中ですぐクリップボードに入れ、ボタンを 1.5 秒 ✓ にする (端末には
  貼らず、Enter も押さない。ID を押すと Notion などの URL を開くのは今までどおり)。panel のペインが送っている間
  (`pjp-hub-panel.sendingUntil` の時刻が過ぎていない間) は写さない。送っているペインでは写すボタンを薄く出して押せなくし、ほかのペインで押すと ✗ にして
  わけの行にわけを出す (「入力欄に入れる」の途中でクリップボードを ID に替えると、答えの代わりに ID が入力欄に貼られる。送信の `hc send` はクリップボードを
  使わないが、同じ印で止める。写す側は印を置かない)
- 図はペインの幅 (一覧とカードの余白を引いた幅) に合わせて縮め・大きくする (0.1〜2 倍。ペインの境を動かすと追う)。幅はアプリの zoom
  (`settings.json` の `zoom`) で割ってから合わせるので、zoom が 1 でなくてもペインの端で切れない。図は panel の文字の % には従わない
- 図をクリックすると、その図だけを大きく出す小窓 (dialog。窓の幅の 92%・高さの 90%) が開く。図は小窓に縦横とも収め (4 倍まで)、marks の
  動きも重ねる。Esc・「閉じる」・図のクリック・小窓の外のクリックで閉じる。小窓は panel と同じ mod を `props.image` で開き、開く mod の名前は
  `main.js` の `MOD` から取るので、写しを試すときは `MOD` を写しの名前に書き換える (書き換えないと、写しの図から本物の panel の小窓が開く)
- 図は herdr-app の home の `pjp-hub-panel-media\<会話ごとのフォルダ>\` に置き、panel.json にはそこからのパスを書く。`image()` は herdr-app の home の
  下しか読めない (scratchpad の絶対パスを渡すと何も出ない)。mod のフォルダには置かない (dotfiles が配る所で、書き換えると mod も読み直す)。
  `pjp-hub-panel-media` はハブの Claude が書く実行時のデータなので、runner は触らない
- `pjp-hub-panel-media` の図は、同じ名前で書き換えても描き直らない (herdr-app がパスで覚えている。保存で描き直るのは `mods\` の下の画像だけ)。図を
  変えるときは名前を変える (`x.svg` → `x-2.svg`)
- SVG の `font-family` は名前を引用符で囲む (`'Yu Gothic UI', 'Meiryo UI', Meiryo, sans-serif`)。囲まないと日本語を混ぜた行が BIZ UDGothic に落ち、
  `~` が `‾` に、`\` が `¥` に化ける
- markdown の文 (節の `text`・問いの `body`) の `[字](URL)`・`<URL>`・素の URL はリンクになり (色・下線・指の形のポインタは TextView が theme から
  決める)、押すと既定のブラウザで開く。開くのは http と https の URL (host のあるもの) だけで、ほかの scheme (`file:`・`mailto:` など) やパスは開かず、
  panel のわけの行 (問いがあれば上の帯のすぐ下の答えの欄、無ければペインの一番下の行) にわけを出す
- markdown の節の `text` に絵だけの行 `![<説明>](<図のパス>)` を書くと、その行で文を切り、そこに小さな絵 (ミニ絵) を出す。図のパスは image の節と同じく
  `pjp-hub-panel-media\` からのパスで、大きさは 1 つ (幅 200・高さ 80 を panel の文字の % で変える。100% で 240×96。ペインの幅には合わせず、入らない
  ときだけ比を保って縮める)。横の位置はすぐ上の行の字の頭 (箇条書きなら記号の後ろ) にそろえ、押すと図と同じ小窓で大きく見る (説明は小窓とポインタの
  ヒントにだけ出す)。パスが決まりの外 (絶対パス・`..`・URL) や図が無いときは、その場所に薄い字で「ミニ絵を出せない: <わけ>」と出す。問いの `body` と
  図の説明ではミニ絵にしない。書き方・置く場所・位置の決め方の正本は `main.js` の頭のコメントの「ミニ絵」:

```markdown
- **畳み方**
  - Done・Canceled で、動くものが無いチケットは上の段だけに畳む
  ![畳む前と後](TKT-n/mini-fold.svg)
- **データ**
  - 新しい節の type work
```

- チケットの一覧と PR の一覧は、節の型 `tickets`・`prs` で書く。panel はハブが書いた行をそのまま出す (panel から gh や Notion を引かない)。行ごとに ID・
  状態の札・題と、その下に一言 (`note`) を出し、ID か題を押すと `url` を開く (リンクと同じく http と https だけ)。状態の札の色は、チケットの `status`
  (Todo・In Progress・In Review・Done・Canceled・Blocked)、PR の `state` (open・draft・merged・closed) と `ci` (pass・fail・pending) で決まる。
  色と、知らない値の出し方の正本は `main.js` の頭のコメント:

```json
{ "type": "tickets", "id": "tickets", "title": "チケット", "rows": [
  { "id": "TKT-n", "title": "panel の図を大きく見る", "url": "https://app.notion.com/p/<…>", "status": "In Progress", "note": "PR はまだ" } ] }
{ "type": "prs", "id": "prs", "title": "PR", "rows": [
  { "id": "dotfiles#251", "title": "panel の文字を 1.2 倍に", "url": "https://github.com/pollenjp/dotfiles/pull/251", "state": "merged", "ci": "pass", "note": "当てた" } ] }
```

- チケット・進み具合・PR の木は、節の型 `work` で書く (ハブはまとめのペインの一番上に置く。panel は節を並べ替えない)。行は
  `{ kind, id, title, url, status, state, ci, who, note, steps, children, related }` で、`kind` は `ticket` (省いてよい)・`pr`・`item`。チケットの行の
  `children` に子のチケット・PR・item を入れると 1 段下げて出し、字下げに縦と横の線を引く (3 段まで)。行ごとに ID・状態の札・題・誰が (`who`。枠だけの札)
  を並べ、その下に段 (`steps` の `{ label, state, answer }`。flow の段と同じ札で、`answer` のある段は押せる。下の「段の answer」)・一言 (`note`)・子を出す。
  ID か題を押すと `url` を開く (一覧と同じく http と https だけ)。
  Done・Canceled のチケットで、下に動いているもの (active か blocked の段・open か draft の PR) が無ければ初め上の段だけに畳み、下の PR の数を足す
  (「PR 3 本 merged」。`▸` で開き、`▾` で畳む。畳んだ行は小さな字の 1 行で出す。下の「済んだもの」)。`related` が true の根の行は、点線の下に「関連」
  として出す。欄の意味・札の色・畳み方の正本は `main.js` の頭のコメント:

```json
{ "type": "work", "id": "work", "title": "チケット・進み具合・PR", "rows": [
  { "id": "TKT-n", "title": "ハブのチケット", "url": "https://app.notion.com/p/<…>", "status": "In Progress", "who": "ハブ", "children": [
    { "id": "TKT-m", "title": "子のチケット", "url": "https://app.notion.com/p/<…>", "status": "In Progress", "who": "子 C · example-wsl/t6v",
      "steps": [ { "label": "spec", "state": "done" }, { "label": "実装", "state": "active" }, { "label": "PR", "state": "todo" } ], "children": [
      { "kind": "item", "title": "解説動画 (短尺)", "who": "子 D",
        "steps": [ { "label": "作る", "state": "done" }, { "label": "見る", "state": "active", "answer": "TKT-m 解説動画 (短尺 2:41) -> 見た" } ] } ] },
    { "id": "TKT-k", "title": "済んだ子のチケット", "url": "https://app.notion.com/p/<…>", "status": "Done", "who": "子 A", "children": [
      { "kind": "pr", "id": "dotfiles#251", "title": "panel の文字を 1.2 倍に", "url": "https://github.com/pollenjp/dotfiles/pull/251", "state": "merged", "ci": "pass" } ] } ] },
  { "id": "TKT-j", "title": "前の会話のチケット", "url": "https://app.notion.com/p/<…>", "status": "Done", "note": "前の会話", "related": true } ] }
```

- 済んだもの: チケットの木の済んだ行 (下に動いているもの (active か blocked の段・open か draft の PR) が無く、チケットは Done・Canceled、PR は
  merged・closed、item は段が全部 done) と done の段、`done: true` を書いた節 (どの type も) は、消さずに小さな字 (13 と 12 は 10、11 と 10 は 9。
  panel の文字の % に従う) で出す。済んだ行は ID と題を薄い色にし、済んだ行どうしの間を詰める。済んだ行の下 (開いたときの段・一言・子) も小さく、
  下の行も薄い。済んだチケットの行は初めから畳み、畳んだ間は 1 行に収める (題は入るだけ出して後ろを `…` で省き、PR の数は省かずに右に寄せ、`who` を
  出さない。`▸` で開くと全部出す)。
  done の段は札の字と余白を小さくする (label は残す)。`done: true` の節は見出しを小さく薄く出して初めから畳み、開いた中身の字も小さい (図とミニ絵の
  大きさはそのまま)。節の初めの開け閉め (`done` か `collapsed` の節を畳む) は panel.json を読み直すたびに決めるので、`version` を替えずに後から
  足した節も畳んで出る (手で開け閉めした節は覚え、`version` が変わると初めに戻る)。ハブは済んだものを外さずに残し、済んだ話の節に `done: true` を
  書く (`collapsed: true` も一緒に書くと、`done` を知らない古い mod でも `version` が替わったときに畳む)。正本は `main.js` の頭のコメントの「済んだもの」
- ユーザーの問いへの答えは、節の型 `qa` (Q&A) で書く。答えがほかの子の返答に紛れて、どこで答えたか分からなくならないように、ハブはユーザーに問われたら
  答えをこの節の項目に書く。項目は `{ id, q, at, a, open }` で、1 つの項目がユーザーの問い 1 つとハブの答え 1 つ。panel は項目を枠のついた小さなカードで
  panel.json の順に縦に並べ、節の題の後ろに項目の数を `(N)` で足す。項目の頭の行に `▸`・`▾`・`Q. <q>` (太字)・時刻 (`at`。小さく薄く)・項目の `×` を
  並べ、頭の行を押すと開け閉めする。開いた項目は答え (`a`。markdown の節の `text` と同じく、リンク・ミニ絵・入れ子の箇条書き) を 1 段下げて出す (無い・空
  なら「(まだ答えていない)」)。初めは `open` (boolean) のとおりで、無ければ 1 つ目の項目だけを開く (ハブは新しい問いを `items` の頭に足す)。手で開け閉め
  した形は panel.json を書き直しても残り、`version` が変わると初めに戻る。`id` は節の id ともほかの項目の id とも重ならない値にする (開け閉めと消す印の鍵)。
  欄の意味と出し方の正本は `main.js` の頭のコメントの「Q&A」:

```json
{ "type": "qa", "id": "qa", "title": "Q&A", "items": [
  { "id": "qa-1123-1412", "q": "panel の Q&A はどこに出る?", "at": "11/23 14:12", "a": "- まとめのペインの節に出す\n  - 新しい問いは頭に足す" },
  { "id": "qa-1123-1350", "q": "前の問い", "at": "11/23 13:50", "a": "前の答え" } ] }
```

- 節を消す印: まとめのペイン (role が `summary` か無い) の、`id` (空でない文字列) のある節の右上に `×` が出る。ユーザーが押すと印が付き (warn の
  点線の枠・題の取り消し線・薄い中身と「次の更新で消える」)、`戻す` で外れる。問いのペインには出ない。Q&A の節の項目 (`id` のあるもの) にも、
  項目の頭の行の右に同じ `×` が 1 つずつ出る (印が付くと、項目の枠が warn の点線になり、問いに取り消し線が引かれ、答えが薄くなる)。印は panel が panel.json の隣の
  `<名前>.dismiss.json` (panel.json の名前の `.json` を `.dismiss.json` に替えたもの。`panel.json` なら `panel.dismiss.json`) に書く:
  `{ "file": "panel.json", "dismissed": [{ "id": "<節の id>", "title": "<印を付けたときの題>", "at": "<時刻 (UTC)>", "base": "<panel が使う指紋>" }] }`。
  項目の印も同じ `dismissed` に項目の `id` で書き、`title` は印を付けたときの `q`、どの節の項目かを `section` (節の id) で足す。
  panel.json はハブだけが書き、印のファイルは panel だけが書く (写しのペインどうしは `writeTextFile` の expected で書き違いを防ぐ)
- 印を付けた後に panel.json の中身が変わると、panel はその節 (項目の印なら、その項目) を出さない (キーの順と空白は比べないので、同じ中身の書き直しは
  変わったと数えない)。ハブが同じ id で書き続けても、印がある間は出さない。panel.json の節にも Q&A の節の項目にも無くなった id の印は、panel が印のファイルから消す。印はファイルに残るので、まとめのペインを
  開き直しても (herdr-app を上げ直しても) 同じに出る (印の後に panel.json が変わっていれば出さず、変わっていなければ印つきで出す)
- ハブは panel.json を書く前に印のファイルを読み (無ければ印は無い)、印の付いた id を、節の id と Q&A の節の項目の id の両方に当てて外して書く。同じ話を
  続けて出すなら別の id (`next-2` など) にする。印のファイルは書き換えない (要らなくなった印は、節や項目を外せば panel が消す):

```powershell
# panel.json を書く前に (PowerShell 7。$panel は書く中身、$panelPath は panel.json の絶対パス)
$dismiss = Join-Path (Split-Path $panelPath) 'panel.dismiss.json'
$ids = @()
if (Test-Path $dismiss) { $ids = @((Get-Content $dismiss -Raw | ConvertFrom-Json).dismissed | ForEach-Object { $_.id }) }
# id の無い節は残す (dismissed が空のとき、$x.dismissed.id は $null になり、$null -notin @($null) は偽になるので、-notin だけでは外れる)。
# panel は id の大文字小文字を区別するので -cnotin で比べる
$panel.sections = @($panel.sections | Where-Object { -not $_.id -or $_.id -cnotin $ids })
# Q&A の節の項目も、印の付いた id の項目を外す (id の無い項目は残す)
foreach ($s in $panel.sections) {
    if ($s.type -eq 'qa' -and $null -ne $s.items) { $s.items = @($s.items | Where-Object { -not $_.id -or $_.id -cnotin $ids }) }
}
```

- 段の answer: チケットの木 (`work`) の行の段に `answer` (1 行の字。問いの `answer` と同じく、それだけで読める「何を -> どうした」) を書くと、panel はその段を
  押せる札にする (ポインタの形・hover・ヒント。色と点滅は今の札のまま)。ハブはユーザーの番の段 (解説動画の「見る」・手で確かめる段) に書き、ユーザーは
  panel を押して「見た」「済んだ」をハブに伝える。押すと (①) 段の並びのすぐ下に「「<answer>」を送る?」と `送る`・`やめる` の小さな確かめが出る (②。もう
  一度段を押すと `やめる` と同じ)。`送る` は問いの「送信」と同じ手 (`hc send`) で `answer` をハブの端末へ送り、
  送れたら確かめの代わりに「「<answer>」を送った」と出す (ハブの端末が確かめの画面で止まっているときは送らず、わけを出す)。`やめる` は何も送らない。
  空・改行を含む `answer` の段は押せないまま。flow の節の段の `answer` は見ない
- 段を押すと、panel は panel.json の隣の `<名前>.steps.json` (panel.json の名前の `.json` を `.steps.json` に替えたもの。`panel.json` なら
  `panel.steps.json`) に押した印を書く。`送る` を押さずに置いた印もハブが拾えるように、押した時に書く:
  `{ "file": "panel.json", "pressed": [{ "section": "<work の節の id>", "row": "<行の id。id の無い行は @ と木の中の位置 (例 @0.2)>", "label": "<段の label>", "answer": "<押したときの answer>", "at": "<時刻 (UTC)>", "sent": false }] }`。
  `送る` で送れたら `sent` が true になり、`やめる` で印が外れる。同じ section・row・label で `answer` の同じ段が panel.json から無くなると、panel が
  印を外す。消す印と同じく、印のファイルは panel だけが書く。欄の意味の正本は `main.js` の頭のコメントの「段の answer」
- ハブは panel.json を書く前に (消す印を読むのと同じ時に) 押した印のファイルを読み、`sent` が false の印を「ユーザーがその `answer` を送った」とみなして、
  端末で `answer` が届いたときと同じに扱う (`sent` が true の印は端末に届いているので数えない)。数えるのは、今の panel.json の、印の `section` と同じ id の
  work の節の木 (深さを問わず) に、`label` と `answer` の同じ段がある印だけ (無い印は、もう扱って `answer` を外した段のもの。まとめのペインが閉じている
  間は、panel が印を外せずに残る)。扱ったら、その段の `answer` を外し、`state` を `done` にして書く (panel が印を外す)。手順の正本は claude-skills の
  pjp-hc-hub の `references/panel.md`:

```powershell
# panel.json を書く前に (PowerShell 7。$panel は今の panel.json を ConvertFrom-Json で読んだもの、$panelPath は panel.json の絶対パス)
$steps = Join-Path (Split-Path $panelPath) 'panel.steps.json'
$pressed = @()
if (Test-Path $steps) { $pressed = @((Get-Content $steps -Raw | ConvertFrom-Json).pressed | Where-Object { $_ -and $_.sent -ne $true }) }
# 今の panel.json の work の節の木 (深さを問わず) にある段の「節の id・label・answer」の組。組が今の段に無い印は数えない
$live = [System.Collections.Generic.HashSet[string]]::new()
$walk = {
    param($sec, $rows)
    foreach ($r in @($rows)) {
        if (-not $r) { continue }
        foreach ($st in @($r.steps)) { if ($st -and $st.answer) { [void]$live.Add("$sec`n$($st.label)`n$($st.answer)") } }
        & $walk $sec $r.children
    }
}
foreach ($s in @($panel.sections | Where-Object { $_ -and $_.type -eq 'work' })) { & $walk $(if ($s.id -is [string]) { $s.id } else { '' }) $s.rows }
$pressed = @($pressed | Where-Object { $live.Contains("$($_.section)`n$($_.label)`n$($_.answer)") })
# 押したが、送ったと書かれていない answer。端末で届いた answer と同じに扱う
$pressed | ForEach-Object { "押した: $($_.answer)" }
```

### herdr-app のキー

旧 herdr ([`herdr/config.toml`](#herdr) の `[keys]`) と同じ手で herdr-app を操るキー。herdr-app の `keys.json` には 2 回に分けて打つキー (prefix) の
仕組みが無いので、prefix は自作の mod `pjp-prefix` (小窓) で作る。keys.json に dotfiles のキーを書き足すのは runner の手順 `herdr-app-keys` (order 99)、
mod を置くのは `herdr-app-mods` ([前節](#herdr-app-の-mod))。どちらも Windows にしか無い手順で、受け持ちが WSL のホストでも `dotfiles apply` が流す
(on/off は `windowsHerdr`)。経緯は dotfiles-private の ADR 070 (`docs/adr/070_win_herdr_app_keys_*`) と、space の移動を `Ctrl+PageUp/Down` と
`Ctrl+Alt+↑↓` にした ADR 085 (`docs/adr/085_win_herdr_app_space_ctrl_alt_*`)、prefix の後の `c` (新しいタブ) を足した ADR 086
(`docs/adr/086_win_herdr_app_prefix_c_new_tab_*`)、`Shift+C`・`Shift+G` の worktree の名前の頭を `hc/` にした ADR 088
(`docs/adr/088_win_herdr_app_worktree_hc_prefix_*`)、prefix の後の端末を止めてから space を閉じて worktree を消すキーを足した ADR 100
(`docs/adr/100_win_herdr_app_prefix_worktree_remove_*`)、そのキーを `Shift+Q` から `Shift+D` に替えた ADR 102
(`docs/adr/102_win_herdr_app_prefix_worktree_remove_shift_d_*`)、さらに Shift なしの `d` に替え、prefix なしの `Ctrl+Q` でも開けるようにした
ADR 103 (`docs/adr/103_win_herdr_app_prefix_worktree_remove_d_*`)、サイドパネルのタブを `Ctrl+Shift+←→` で切り替えるキーを足した ADR 108
(`docs/adr/108_win_herdr_app_sidebar_tab_keys_*`)、そのキーを `Ctrl+Alt+←→` に替えた ADR 110 (`docs/adr/110_win_herdr_app_sidebar_tab_keys_ctrl_alt_*`)。

```powershell
dotfiles check --steps herdr-app-mods,herdr-app-keys             # 差を見る (何も書かない)
dotfiles apply --dry-run --steps herdr-app-mods,herdr-app-keys   # することを出す
dotfiles apply --steps herdr-app-mods,herdr-app-keys             # 置く・書き足す (herdr-app は保存するとすぐ読み直す)
```

| キー | herdr-app ですること | 旧 herdr |
| --- | --- | --- |
| `Ctrl+PageUp`・`Ctrl+PageDown` | 前・次の space (`space.prev`・`space.next`。herdr-app の既定ではタブの移動) | `previous_workspace`・`next_workspace` (旧 herdr は `Ctrl+Alt+↑↓`。旧 herdr は PageUp・PageDown をキーに使えない) |
| `Ctrl+Alt+↑`・`Ctrl+Alt+↓` | 同じく前・次の space | 同じキー (`previous_workspace`・`next_workspace`) |
| `Ctrl+↑`・`Ctrl+↓` | 前・次のタブ (`tab.prev`・`tab.next`) | `previous_tab`・`next_tab` |
| `Ctrl+K` | prefix の小窓を開く (`mod.open:pjp-prefix`) | `prefix` |
| `Ctrl+Alt+←`・`Ctrl+Alt+→` | layout pjp-main を出している間だけ、左のサイドパネルのタブの Spaces・Agents を出す (`layout.select` で stack `sidebar-lists` の子 `spaces`・`agents` を選ぶ。端で回らない。[サイドパネルのタブ](#サイドパネルのタブ-pjp-sidebar-tabs)) | (無い) |
| `Ctrl+Q` | prefix の後の `d` と同じ確かめの小窓を開く (`mod.open:pjp-worktree-remove`。今の space の端末を全部止めて worktree を消す。下の `d` の説明) | (無い) |
| prefix → `Shift+C` | 名前を自動で付けた worktree を作り、新しい space で開く | `new_worktree` |
| prefix → `Shift+G` | 同じく worktree を作り、新しい space の最初のタブで Claude Code を起動する | `new_worktree` (旧 herdr は `Shift+C` と同じ) |
| prefix → `v`・`\|` | 右に分割 (`pane.split` の right) | `split_vertical` |
| prefix → `-`・`Shift+S` | 下に分割 (`pane.split` の down) | `split_horizontal` |
| prefix → `n`・`p` | 次・前のタブ | `next_tab`・`previous_tab` |
| prefix → `c` | 新しいタブ (`tab.new`。`Ctrl+Shift+T` (herdr-app の既定) と同じく、今の space の focus のペインのフォルダで開く) | (無い) |
| prefix → `Shift+T`・`,` | タブの名前を変える (名前を訊く) | `rename_tab` |
| prefix → `Tab`・`o` | 今のタブの次のペイン (端末のペインを順に回る) | `cycle_pane_next` |
| prefix → `g`・`"` | 端末の picker (`mod.open:picker`) | `goto` |
| prefix → `Shift+O` | 次のエージェント (`agent.next`) | `open_notification_target` の代わり |
| prefix → `d` | 今の space の端末を全部止め、終わるのを待ってから space を閉じて worktree を消す (確かめの小窓 `pjp-worktree-remove` で Enter を待つ。branch は残す) | (無い。旧 herdr の `d` は `detach`) |
| prefix → `Ctrl+K` | prefix を開く前の端末へ `Ctrl+K` を送る (shell の行末まで消すなど、端末のプログラムの `Ctrl+K` を使うとき) | (無い) |

- 割り当てないもの: detach (`q`) と設定の読み直し (`Shift+R`)。herdr-app は窓を閉じても端末が止まらず、設定は保存するとすぐ読み直す。
  旧 herdr で detach のもう 1 つのキーだった `d` は、herdr-app では worktree を消すキー (上の表) にした。旧 herdr の detach のつもりで押しても、
  確かめの小窓が開くだけで、Enter を押すまで端末も space も worktree も触らない (Esc で何もせずに閉じる)。`Ctrl+K` の後に `d` で始まる語を
  打ち続けて Enter まで押しても、小窓はキーが届いた後の Enter と開いてすぐの Enter で進まない (下の `d` の説明)
- prefix の小窓は窓の上の方に出て、押せるキーの一覧を出す (行を押しても同じ命令)。`Esc` で取り消し、割り当てに無いキーは何もせずに閉じる。キーは打った
  文字で見るので、日本語の配列でも `"` (Shift+2)・`|` (Shift+¥) で届く
- `Ctrl+K` は shell などのプログラムが使うキー (bash・fish の行末まで消すなど) で、herdr-app に取られる (herdr-app の案内も、prefix に使うと何を
  取るかを伝えるよう書いている)。端末のプログラムに送るときは、prefix の後にもう一度 `Ctrl+K`。小窓に focus がある間の `Ctrl+K` を mod に
  渡すのは keys.json の section `mod:pjp-prefix` (細かい section が `global` より勝つ。無いと `global` の `Ctrl+K` が小窓を閉じるだけになる)
- `Ctrl+Q` も herdr-app に取られ、端末のプログラムには届かない (端末の XON・Emacs の quoted-insert など)。確かめの小窓に focus がある間の `Ctrl+Q` は、
  keys.json の section `mod:pjp-worktree-remove` が mod の命令 (`pjp-worktree-remove.again`) にし、`Esc` と同じに扱う (小窓を閉じる。止めている間は
  閉じない)。無いと `global` の `Ctrl+Q` (mod.open の 2 回目) が小窓を閉じ、止めている途中の仕事を打ち切る。focus が小窓の外 (端末を押した後など) に
  あるときの `Ctrl+Q` は `global` のまま小窓を閉じるので、止めている間は押さない (途中で止まったら通知が出て、もう一度開いて続きを流せる)
- `Ctrl+Alt+←→` (サイドパネルのタブ) は keys.json の section `layout:pjp-main` に書く (その layout を出している間だけ効き、`global` より勝つ)。
  action は名前つきの引数のオブジェクト (`{"command": "layout.select", "args": {"stack": "sidebar-lists", "child": "spaces"}}`)。左のタブが Spaces、
  右が Agents なので、`←` で Spaces、`→` で Agents (今出ているタブで押しても何も替わらない)。**pjp-main を出している間は、このキーは端末のプログラムに
  届かない**。表示を main に戻せば、section が効かず端末に届く。section `terminal` に同じキーを書くと (herdr-app の既定には無い)、そちらが勝って
  タブは替わらない。`Ctrl+Alt+↑↓` (space の移動) と同じく、Ctrl+Alt は Windows で AltGr として読まれるが、矢印は字を打たないので打てなくなる字は無い。
  グラフィックのドライバーなどが `Ctrl+Alt+矢印` を global hotkey に取っている PC では、herdr-app に届かずタブが替わらない。前に当てた
  `Ctrl+Shift+←→` は割り当てない (記録どおりの値なら、次の apply で keys.json から外れ、端末のプログラムに届く)
- space の移動は `Ctrl+PageUp`・`Ctrl+PageDown` と `Ctrl+Alt+↑↓` の両方。`Ctrl+PageUp`・`Ctrl+PageDown` は herdr-app の既定ではタブの移動
  (`tab.prev`・`tab.next`) に使うキーなので、repo の `herdr-app/keys.defaults.json` にその既定の値を書いて上書きする (下の「書き足し方」)。タブの移動は
  `Ctrl+↑↓` と、herdr-app の既定の `Ctrl+Tab`・`Ctrl+Shift+Tab`・`Alt+]`・`Alt+[` が残る。`Ctrl+PageUp`・`Ctrl+PageDown` は herdr-app の既定でも取って
  いるキーで、端末のプログラムに届かないのは前と同じ。`Ctrl+Alt+↑↓` も herdr-app が取るので、端末のプログラムには届かない
- `Ctrl+Alt+↑↓` は旧 herdr の workspace の移動と同じキー。Windows では Ctrl+Alt が AltGr として読まれるので、herdr-app の案内 (home の `AGENTS.md` の
  Keys の節) は、Ctrl+Alt のキーを自分からは選ばず、頼まれて割り当てるときは打てなくなる字を伝えるよう書いている。矢印は AltGr を足しても字を打たない
  ので、打てなくなる字は無い。グラフィックのドライバーなどが `Ctrl+Alt+矢印` を global hotkey に取っている PC (画面を回すキーなど) では、herdr-app に
  届かず space が移らない。前に space の移動に使った `Ctrl+Shift+↑↓` は割り当てない (当てると、記録どおりの値なら keys.json から外れ、端末のプログラムに
  届く)
- 旧 herdr は PageUp・PageDown をキーの名前に持たない (0.9.5 でも、どう綴っても `herdr config check` が invalid keybinding にする。
  [`nix/files/herdr/config.toml`](../nix/files/herdr/config.toml) のコメント) ので、旧 herdr の workspace の移動は `Ctrl+Alt+↑↓` のまま。herdr-app の中で
  旧 herdr を動かすと、`Ctrl+Alt+↑↓` も `Ctrl+PageUp`・`Ctrl+PageDown` も herdr-app が先に取り (herdr-app の space が移る)、旧 herdr には届かない。
  旧 herdr の workspace を `Ctrl+Alt+↑↓` で移るなら、herdr-app の外 (Windows Terminal など) で旧 herdr を開く
- worktree の名前は `hc/<形容詞>-<名詞>-<16 進 4 桁>` (例 `hc/calm-river-8281`。フォルダは `~/.herdr/worktrees/<repo>/hc-calm-river-8281`)。
  頭の `hc/` (herdr-app と hc の世代の印) は、旧 herdr が付ける `worktree/<形容詞>-<名詞>-<16 進 4 桁>` とずらすため。同じ形だと、Windows のハブ
  (`%USERPROFILE%\h`) の worktree の branch が WSL の旧 herdr のハブ (`~/h`) のものと丸ごと重なりうる。重なると、両方のマシンの見回り役が同じハブの
  チケットを読む (claude-skills の spec `docs/superpowers/specs/2026-11-15-windows-herdr-app-hc-design.md` の §7.10)。prefix を開く前に focus があった
  ペインのフォルダの repo に、同じ名前の branch があれば名前を作り直してから、herdr-app の worktree の小窓に渡す。小窓は Enter を待たずに、その
  checkout の HEAD から branch を切って worktree を作り、新しい space を開く (sidebar では repo の space の下に並ぶ)。machine (WSL・SSH の先) の space
  なら、その machine で作る。git の repo でないフォルダでは、小窓がわけを出す
- prefix の後の `d` (と prefix なしの `Ctrl+Q`) は、ゴミ箱の印 (🗑️) の付いた space などを片付けるキー。herdr-app の同梱の Remove worktree (space の
  menu) は `space.close` を打ってすぐ `git worktree remove` を打つので、Windows では space の shell や Claude Code がまだ worktree のフォルダを今の
  フォルダにしている間に git が消しに行き、`failed to delete '…': Permission denied` で落ちる (git は登録を消してから落ちるので、空のフォルダだけが
  残る)。`d` と `Ctrl+Q` は確かめの小窓 (`pjp-worktree-remove`。外を押しても閉じない window) を開き、Enter (か「止めて消す」) で次の順に進める。
  `d` は prefix を開く前の space、`Ctrl+Q` は focus のある space を消す。Enter には守りが 2 つある (どちらもボタンには効かない):
  - 小窓が開いてからキー (字と空白、`Ctrl+C`・`Ctrl+R` など Ctrl・Alt・Win を足したキー。修飾キーだけ・押しっぱなしの繰り返し・Tab・矢印は数えない)
    が 1 つでも届いたら、その小窓では Enter で進めない (止めたときのやり直しも)。`d` や `Ctrl+Q` の後に、端末へ打つつもりのキーを打ち続けて Enter まで
    押しても消さないため。進めるならボタン (「止めて消す」・「やり直す」) を押すか、Esc で閉じて開き直す
  - 開いてから 1 秒の間の Enter は受けず、受けなかった Enter からも 1 秒を数え直す。`Ctrl+Q` を押し違えた直後の Enter と、続けて押す Enter で消さない
    ため。小窓を見てから、1 秒あけて Enter を押せば進む

  Enter を受けなかったときは小窓にわけが出る。わざと消すときは、`Ctrl+K` → `d` か `Ctrl+Q` で開き、小窓を見てから Enter を押す。進めた後は、済むまで
  Esc で閉じない (小窓を閉じると、小窓の仕事は herdr-app に打ち切られる)。済めば小窓は自分で閉じ、済んだ・止まったは通知で出る。layout の切り替え
  などで閉じられたら、どこで止まったかを通知で出す (残っていれば、もう一度 prefix の後の `d` か `Ctrl+Q` で続きを流す)
  1. 止める端末: space の全タブの端末 (ペインの無い space の端末も) と、同じ machine の生きた端末のうちフォルダが worktree の中のもの (ほかの space の
     端末・`hc run` の手伝いの端末。小窓では分けて出し、ほかの space の端末は赤い警告にも出す)。全部に `hc kill` を打ち、`hc` で全部が finished に
     なるまで待つ。60 秒で止まらなければ、space と worktree に触らずに止まり、残った端末を出す (小窓で Enter を押すとやり直す)
  2. space を閉じる (`space.close`)。`git worktree remove` は、同梱の Remove と同じく未 commit の変更か submodule があるときだけ `--force`
     (小窓が警告を出す)。git の登録が残ったまま落ちる間は、間を置いてやり直す。git が登録を消してフォルダだけが残ったら、中身が空のフォルダだけを
     消す (ファイル・symlink・junction が残っていれば消さずに知らせる)。`git worktree prune` は打たない (repo の全部の worktree に効くため)
  3. branch は消さない。linked worktree でない (repo の main の checkout・git の外)・`git worktree lock` があるときは、わけを出して何もしない。
     WSL・SSH の先の machine の space でも同じに動く (git はその machine で打つ)
- `Shift+G` で起動するのは `c` と同じ引数の claude (`claude --dangerously-skip-permissions --effort max --model claude-opus-5-5 --remote-control=`)。
  `c` は fish では abbr、bash では alias で、herdr-app が argv で起こすときに広がるとは限らないので、中身を並べている。machine の space でも同じ argv で、
  claude が PATH に無ければ herdr-app が端末のエラーを出し、shell が残る。`c` を直すときは `pjp-prefix/main.js` の `CLAUDE` もそろえる (runner の試験
  `claude_argv_matches_c` が、fish・bash・PowerShell の `c` と突き合わせる)
- 書き足し方: repo の `herdr-app/keys.json` (herdr-app の keys.json と同じ形で、dotfiles が持つキーだけ) を、herdr-app の home の `keys.json` に足す。
  ほかのキー・section と順は残し、キーの順を見ずに同じなら書かない。書いたキーは `%LOCALAPPDATA%\dotfiles\state\herdr-app-keys.applied.json` に記録し、
  repo から消したキーは、今の値が記録どおりなら外す (空になった section も外す)。dotfiles が書いた値でないキー (herdr-app の既定・手で書いた値) と、
  書いた後に herdr-app の側で書き換えたキーは、上書きせずに ⚠ で知らせる (残すなら repo の `herdr-app/keys.json` に取り込み、dotfiles の値にするなら
  `dotfiles apply --steps herdr-app-keys --force`)。書く前の中身を `%LOCALAPPDATA%\dotfiles\state\herdr-app-keys\backup\` に写す (いちばん古いものと、
  新しい方から 10 個)
- herdr-app の既定のキーを替える: repo の `herdr-app/keys.defaults.json` (keys.json と同じ形) に、dotfiles が上書きしてよい herdr-app の既定の値を書く
  (今は `global` の `ctrl-pageup` = `tab.prev`・`ctrl-pagedown` = `tab.next`)。今の値がその値なら、⚠ を出さずに書き換えて記録する (新しい PC でも、
  逃げ道のキーで既定に戻されたときも)。ほかの値 (手で変えた値・herdr-app の別の版の既定) は今までどおり ⚠ で飛ばす。repo の keys.json から消した
  キーは、今の値が記録どおりなら、keys.defaults.json に値があれば外さずにその値へ戻す (外すと herdr-app のそのキーが無くなるので、keys.defaults.json の
  行は残す)。`--force` はほかの衝突も上書きするので、既定のキーを替えるためには使わない
- **keys.json を一度書き換えると、herdr-app を上げても新しい既定のキーは足されない。** herdr-app は手を入れていない keys.json だけを新しい版の既定に替え、
  少しでも書き換えたファイルは丸ごとユーザーのものとして残す (herdr-app の home の `AGENTS.md` の Keys の節)。herdr-app を上げたら、更新ノート
  (Settings → Updates の What's new。命令は `app.whats_new`) を見る。既定のキーが増えた版は「keys.json を書き換えたなら自分で足す」として、足すキーと
  section を書いている (例: section `terminal` に `"ctrl-shift-f": "terminal.search"`)。要るものを手で足す (どの PC でも使うなら repo の
  `herdr-app/keys.json` に足す)。dotfiles が固定した版を上げる PR では、上げる版までの CHANGELOG で見て、その PR で repo に足す
  ([固定した版を上げる](#固定した版を上げる)の 3)。setup の新しい版の知らせも、herdr-app に新しい版があればこの注意を添える
  ([固定した版より新しい版の知らせ](#固定した版より新しい版の知らせ))
- keys.json が無ければ書かない (herdr-app をまだ起こしていない新しい PC)。herdr-app は keys.json をキーの全部として読むので、dotfiles のキーだけの
  ファイルを作ると既定のキーが無くなる。herdr-app を一度起こしてから `dotfiles apply --steps herdr-app-keys`。herdr-app の逃げ道のキー
  (`Ctrl+Alt+Shift+Esc`) は keys.json を `keys.json.reset-<時刻>` へ退けて既定に戻すので、その後も `dotfiles apply --steps herdr-app-keys` で足し直す
- herdr-app は keys.json を保存するとすぐ読み直す。読めなければ前に読めたキーのまま動き、隣の `keys.error` にわけを書く。書き足した後は少し置いて
  `dotfiles check --steps herdr-app-keys` を流すと、`keys.error` があれば ※ で知らせる (書いたその apply では、`keys.error` は前の中身のものなので
  知らせない。`herdr-app status | Out-String` でも見られる)。section は細かい方が勝つ (`terminal` > `layout:<名前>` > `global`) ので、`terminal` に同じキーを書くと、端末に
  focus がある間はそちらが効く
- キーを足す・変えるときは repo の `herdr-app/keys.json` を直す (prefix の後のキーは `pjp-prefix/main.js` の `BINDINGS`。herdr-app の既定のキーを替える
  ときは `herdr-app/keys.defaults.json` にその既定の値も書く)。キーの書き方と命令の名前は、herdr-app の home の `AGENTS.md` の Keys の節と
  `herdr-app commands`。既定の値は、herdr-app を一度も書き換えていない keys.json (新しい PC で herdr-app が書いたもの) で見る

### herdr-app の印 (pjp-spaces)

herdr-app の sidebar の space の行の 2 行目に、旧 herdr の sidebar の 2 行目と同じハブと子の印 (`🌱`・`🌳[N]`・`🔄`・`👀`・`🗑️`・`↑ TKT-n`) を出す。
印を出すのは claude-skills の mod `pjp-spaces` (herdr-app の同梱の mod `spaces` を写して印を足したもの。claude-skills の spec
`docs/superpowers/specs/2026-11-15-windows-herdr-app-hc-design.md` の §7.5・W2-4)。runner の手順 `herdr-app-pjp-spaces` (order 98) がそれを herdr-app の
home に置き、同梱の layout `main` を写した自分の layout `pjp-main` の sidebar の spaces を pjp-spaces に替える。Windows にしか無い手順で、受け持ちが
WSL のホストでも `dotfiles apply` が流す (on/off はハブの手順 `hc-hub` と同じ `herdrHub`)。経緯は dotfiles-private の ADR 072
(`docs/adr/072_win_herdr_app_pjp_spaces_*`)。

```powershell
dotfiles check --steps herdr-app-pjp-spaces             # 差を見る (何も書かない)
dotfiles apply --dry-run --steps herdr-app-pjp-spaces   # することを出す
dotfiles apply --steps herdr-app-pjp-spaces             # 置く。初めて置くときは、表示する layout が pjp-main に替わる (画面が替わる)
```

| 置くもの | 置き先 (herdr-app の home の下) | 置き方 |
| --- | --- | --- |
| claude-skills の clone の `skills/pjp-hc-hub/herdr-app/mods/pjp-spaces/` | `mods\pjp-spaces\` | `herdr-app-mods` と同じ記録つきのコピー (記録は `%LOCALAPPDATA%\dotfiles\state\herdr-app-pjp-spaces.deployed.json`) |
| 同梱の `layouts\main.json` の、spaces を指す block (`content.mod` が `spaces`) を `pjp-spaces` に替え、`pjp-sidebar-tabs` が置けていれば `sidebar-lists` をタブの stack にしたもの ([サイドパネルのタブ](#サイドパネルのタブ-pjp-sidebar-tabs)) | `layouts\pjp-main.json` | 初めては `herdr-app do layout.clone '{"name":"main","as":"pjp-main"}'` で写してから替える。その後は runner が今の main から作り直す (同じ記録) |

- **初めて置く apply は、表示する layout を main から pjp-main に替える** (`layout.clone` は写した layout へ表示を替える)。sidebar の幅などの clicks
  (`layouts\.state\`) は herdr-app が clone で写すので、main で広げた幅のまま。表示を替えるのはこの 1 回だけ。表示が main でない (ほかの layout を
  選んでいる) ときは作らずに · で知らせる。herdr-app の窓が開いていないと clone が落ちる (⚠。窓を開いて流し直す)
- runner が herdr-app に打つのは `herdr-app do layout.clone` だけ (窓を止めない・立て直さない。出力を受けて終わりまで待つ)。表示している layout は herdr-app の home の `shared.json`
  の `layout` で読む。同梱の `main.json` は直さない (herdr-app は起動のたびに同梱のファイルを書き戻し、直したものは `main-edited` に移す)
- herdr-app を上げて main が変わったら、`dotfiles check` が pjp-main の行に変わった node を出す (⚠。例「同梱の main から作り直す。変わった node:
  sidebar・status」)。`dotfiles apply` が今の main に同じ差し替えをした形へ書き直す (clone し直さない。`cloned_from` と clicks は残る)。main が変えた
  欄は、herdr-app の決まり (ファイルを直した欄はファイルが clicks に勝つ) で新しい値になる
- pjp-main.json を手で直すと、次の apply は書き直さずに ⚠ で知らせる。残すなら別の名前の layout に写して使い
  (`herdr-app do layout.clone --name pjp-main --as <名前> | Out-String`)、main から作り直すなら `dotfiles apply --steps herdr-app-pjp-spaces --force`。spaces を
  pjp-spaces に替えると今の形になるもの (人が `layout.clone` で main を写し直した・中身は同じで保存し直した) は、⚠ にせずに引き取って書き直す
- 書かなかった実行で、herdr-app が layout を読めなかった理由のファイル (`layouts\pjp-main.error`、pjp-main を表示しているときは home の `layout.error`)
  があれば、pjp-main の行に ※ でその 1 行目を添える。`herdr-app status | Out-String` でも見られる
- 同梱の main に spaces を指す block が無くなったら (herdr-app の形が変わった)、pjp-main は前のままにして ⚠ で知らせる。claude-skills の pjp-spaces と
  合わせて差し替え方を決め直す
- 同梱の mod `spaces` が変わったとき (herdr-app を上げた) に pjp-spaces へ差を取り込むのは claude-skills (pjp-spaces の頭に、写した元の herdr-app の版が
  ある)。取り込んだ版は、clone を pull して `dotfiles apply` で届く
- claude-skills の clone に pjp-spaces がまだ無い (claude-skills の PR の merge 前) うちは何もしない (· で知らせる)。置いた後で clone から無くなったら、
  置いたものに触らずに ⚠ で知らせる (layout が mod を指しているので、片付けると sidebar が壊れる)
- mod.json の `place` が `none` でない mod は置かない (⚠。herdr-app は初めて見た mod を、place に従って表示中の layout へ差し込む)。mod.json は先に置く。
  同梱の main が無い (herdr-app をまだ起こしていない) ときは mod も置かずに ⚠ (一度起こしてから apply)
- 置き方の細部 (herdr-app が mod のフォルダに書く `gpui-kit.d.ts`・`jsconfig.json` は配らない・置き先の mod のフォルダがリンクなら触らない・元から
  消えたファイルは記録どおりなら消す) は [herdr-app の mod](#herdr-app-の-mod) と同じ。置いた後は `herdr-app status | Out-String` で errors が無いか、mod は
  `herdr-app check <mod のフォルダ>` ([herdr-app の mod](#herdr-app-の-mod) の見方) で確かめる

切り戻し (PowerShell):

```powershell
# 1. 表示を同梱の main に戻す (ctrl-shift-l で巡ってもよい)。runner は自分から pjp-main へ替え直さない。| Out-String で終わりまで待つ (上の「herdr-app の mod」)
herdr-app do layout.switch --name main | Out-String
# 2. 配ったファイルも外すなら (1 の後で)。runner は記録から「作った pjp-main が無い」と分かり、次の apply から mod も layout も置かない
$h = Join-Path $HOME '.config\herdr-app'   # HERDR_APP_HOME を置いていれば、その値
Remove-Item (Join-Path $h 'layouts\pjp-main.json')
Remove-Item -Recurse (Join-Path $h 'mods\pjp-spaces')   # 手でリンクにしていたら cmd /c rmdir で外す (先は消さない)
dotfiles check --steps herdr-app-pjp-spaces             # · で「mod も layout も置かない」と出る
```

- 1 だけなら pjp-main と mod は残り、apply は main が変わるたびに pjp-main を作り直す (表示は替えない)。`ctrl-shift-l` でいつでも pjp-main に戻れる
- 2 の後は、`--force` を付けても置き直さない (ほかの手順の衝突を解く `dotfiles apply --force` で、表示を替えない)。戻すときは、人が
  `herdr-app do layout.clone --name main --as pjp-main | Out-String` で main を写し直し (表示が pjp-main に替わる)、`dotfiles apply --steps herdr-app-pjp-spaces` で
  mod を置いて spaces を差し替える
- 逃げ道のキー (`ctrl-alt-shift-escape`) は、表示中の layout (pjp-main) と `keys.json` を `*.reset-<時刻>` へ退けて main に戻す。runner は 2 と同じく
  外したものとして扱う。戻すときは上の写し直しか、`layouts\pjp-main.json.reset-<時刻>` の名前を `pjp-main.json` に戻す (中身が記録どおりなら揃う)。
  dotfiles のキーは [herdr-app のキー](#herdr-app-のキー) のとおり `dotfiles apply --steps herdr-app-keys` で足し直す
- `layouts\.state\pjp-main.json` (pjp-main の clicks) は herdr-app のファイルなので消さない (herdr-app の決まり)。写し直すと main の clicks で写し直される

#### サイドパネルのタブ (pjp-sidebar-tabs)

pjp-main の左のサイドパネルの Spaces と Agents を、上端のアイコンのタブで切り替える (出すのはどちらか 1 つで、縦いっぱいに出す)。選んでいる
タブはアイコン + 名前 (薄い地の角丸)、ほかはアイコンだけ (hover で名前)。Agents のタブには、確認の画面で止まっている (status が `blocked` の)
agent の数を赤い丸の数の印で出す (0 なら出さない)。タブを描くのは dotfiles の mod `pjp-sidebar-tabs` (`herdr-app-mods` が置く)、layout を直すのは
`herdr-app-pjp-spaces`。経緯は dotfiles-private の ADR 106 (`docs/adr/106_win_herdr_app_sidebar_tabs_*`)。

```powershell
dotfiles check --steps herdr-app-mods,herdr-app-pjp-spaces   # 差を見る (何も書かない)
dotfiles apply --steps herdr-app-mods,herdr-app-pjp-spaces   # mod を置き、pjp-main の sidebar-lists をタブの stack にする
```

pjp-main の `sidebar-lists` (同梱の main では spaces と agents を縦に並べる column) を、herdr-app の layout の `stack` (子を 1 つだけ出し、上端に
header の mod を置く) にする。子 (spaces・agents の block) はそのまま:

```json
{ "id": "sidebar-lists", "type": "stack", "active": "spaces",
  "header": { "content": { "mod": "pjp-sidebar-tabs", "props": { "stack": "sidebar-lists" } }, "height": 36 },
  "children": [ { "id": "spaces", "…": "…", "content": { "mod": "pjp-spaces" } }, { "id": "agents", "…": "…", "content": { "mod": "agents" } } ] }
```

- タブを押すと `layout.select {stack: "sidebar-lists", child}` で出す子を替える。選んだ子は herdr-app が clicks (`layouts\.state\pjp-main.json`) に
  残し、herdr-app を上げ直しても残る。runner はファイルの `active` をいつも `spaces` にし (main の子の並びが替わっても)、clicks に触らない。
  herdr-app はファイルの `active` が前と同じなら clicks の選んだ子を残すので、main が変わって pjp-main を書き直しても、選んだタブはそのまま
- タブにするのは、herdr-app の home に `mods\pjp-sidebar-tabs\` が置けている (`main.js` があり、`mod.json` の `place` が `none`) ときだけ。置くのは
  `herdr-app-mods` (同じ order 98 で、名前の辞書順で `herdr-app-pjp-spaces` より先に流れる。on/off は `windowsHerdr`)。置けていなければ column の
  まま、pjp-main の行に ※ でわけを添える (layout から無い mod を指すと sidebar が壊れる)。check と dry-run は今の置き先で判定するので、まだ
  置いていない PC の初めの `dotfiles check` は ※ を出す (apply では、herdr-app-mods が mod を置いた後の続きでタブにする)
- 前に作った pjp-main (column の形) も、次の apply でタブにする (`変わった node: sidebar-lists`。clone し直さない・表示は替えない)。mod が無く
  なれば column に戻す。pjp-main を手で直していて書き直せない (衝突) ときに mod が無くなると、header は無い mod を指したままになるので、※ が
  そう言う (mod を置き直すか、`dotfiles apply --steps herdr-app-pjp-spaces --force` で column に戻す)
- タブにするとき、同梱の main に `sidebar-lists` (spaces と agents を子に持つ column) が無くなったら (herdr-app の形が変わった)、pjp-main は前の
  まま ⚠ で知らせる。タブにする所を決め直す
- 今どちらが出ているかは layout から読むので、ほかの手 (コマンドの `layout.select`・clicks の復元) で替わっても描き直しで追いつく。blocked の
  数も agent の状態が変わるたびに描き直る (timer は回さない)。sidebar を 160px 未満 (rail) に細めると、タブは小さなアイコンだけになり、数の印は
  点になる (数は hover で出る。rail から広げるのは brand の行の sidebar のボタン)
- キーでも切り替えられる: `Ctrl+Alt+←` で Spaces、`Ctrl+Alt+→` で Agents (タブの左右の位置どおり。端で回らない)。タブを押したときと同じ
  `layout.select {stack: "sidebar-lists", child}` を、keys.json の section `layout:pjp-main` に書いてある (runner の `herdr-app-keys` が書き足す。
  [herdr-app のキー](#herdr-app-のキー))。pjp-main を出している間、このキーは端末のプログラムに届かない
- Agents のタブを出していない間は、`pjp-sidebar-tabs` が agents の一覧の順 (`agent.next`・`agent.prev` が辿る順。prefix の小窓の `Shift+O`) を
  代わりに渡す。herdr-app は出ていない slot の mod を描かず、同梱の agents は描くときにだけ順を渡すため。並べ方は同梱の agents の既定 (ピン留め →
  blocked → done → working → idle、同じなら新しく変わった順。並べ方を grouped にしていれば一覧の順) に寄せた (sub-agent の急ぎは親に寄せない)
- 置いた後は `herdr-app status | Out-String` で errors が無いか、mod は `herdr-app check <mod のフォルダ>` ([herdr-app の mod](#herdr-app-の-mod)
  の見方) で確かめ、`herdr-app shot <png> | Out-Null` で見た目を見る
- やめるときは、dotfiles の `herdr-app/mods/pjp-sidebar-tabs/` を外す PR を出す (merge の後の apply で、`herdr-app-mods` が置き先のファイルを消し、
  同じ apply の続きで `herdr-app-pjp-spaces` が `sidebar-lists` を column に戻す)。`--steps herdr-app-mods` だけを流さない (mod だけが消え、pjp-main が
  無い mod を指したまま残る)。`herdr-app-pjp-spaces` が途中で止まる (pjp-spaces が無い・`herdrHub` が off など) ホストでは、先に表示を main に戻して
  おく (上の切り戻しの 1)。すぐ見えなくするだけなら、表示を main に戻す

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
- 受け持ちを runner に切り替えたホストは `windowsFiles.enable = false` で、WSL は配らない。配るのは Windows の `dotfiles apply` の手順 `files` (同じ判定。
  記録は `%LOCALAPPDATA%\dotfiles\state\windows-files.deployed.json`。[受け持ちを runner に切り替える](#受け持ちを-runner-に切り替える))
- 配り先の `/mnt/c/Users/<名前>` は `dotfiles.wsl.windowsUserName` で決まる
- 配るのは setup を流した checkout の作業ツリー。commit していない変更も配られる
- 置いたファイルをアプリが読み直すとは限らない。書き換えたときは manifest の `hint` が出る
  (Orca なら「設定 → キーボードショートカット → ディスクから再読み込み」)。runner の手順 `files` は、`runnerHint` があればそちらを出す
  (`hint` が WSL の setup の手 (`setup --update`・`bootstrap-windows-*.sh` など) を指す項に、runner の手で書く。WSL の無いホストにも出るため。
  runner が出す案内に WSL の手が残っていないかは、runner の試験が本物の manifest で確かめる)

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
# runnerHint = "…"   # 任意。runner が hint の代わりに出す文 (hint が WSL の setup の手を指すとき)
```

- `dst` は `%USERPROFILE%` / `%APPDATA%` / `%LOCALAPPDATA%` のどれかで始める。区切りは `/`
- 書けるキーは `src` / `dst` / `hint` / `runnerHint` / `base` だけ。`..` と `\` は書けない
- `hint` は WSL の setup (`bootstrap-windows-files.sh`) と runner の両方が出す。`setup --update`・`bootstrap-windows-*.sh`・`dotfiles.wsl.*` を書くなら、
  runner の手 (dotfiles apply の手順の名前と、on/off を決めるホストの値の `[tools]`) で `runnerHint` も書く (runner の試験が、runner の出す案内に
  WSL の手が残っていると落ちる)
- `base = "nix"` の表だけ、`src` は repo 直下の `nix/` からの相対パスになる (既定は `"win"`)。Linux の home-manager も同じファイルを
  読むときに使う (home-manager からは `nix/` しか見えないので、1 か所は `nix/` に置く。今は herdr の固定した版の `releases.json` と、
  [starship](#starship) の `starship.toml`)。`src` は `win/` の外なので、[`.github/workflows/win-runner.yml`](../.github/workflows/win-runner.yml) の
  `paths` にも足す (runner が読むファイルを変えた PR で、runner の CI を流す)
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

## winget

dotfiles の Windows の道具は **winget 1.30 以降**を前提にする。1.30 で portable の入れ方が変わり (昇格した会話からの user スコープの portable を
`0x8A15007D` で断る・symlink を作れないときは置き場所に別名の hardlink を作って PATH に足す)、winget の portable の道具は昇格した会話では入れずに止まる
([winget の portable の道具](#winget-の-portable-の道具))。`Install-Codex` は hardlink の形にも合わせてある ([Codex CLI](#codex-cli)。1.29 以前で開発者モードが
off なら入れずに止まる)。新しく入れた Windows の winget は古いことがあり (入れたての Windows 11 で
v1.11.510 を見た)、Microsoft Store が使えない・止められた PC (会社の PC など) では Store の自動の更新でも上がらない。そこで runner の手順 `winget`
(order 6。bootstrap の次で、winget を使うほかの手順より先) が、winget 自身を固定した版以上に揃える
(dotfiles-private の ADR 121 (`docs/adr/121_win_winget_pin_*`))。

```powershell
Install-WinGet -Check   # 固定した版以上か (0 = 揃っている、1 = 古い、3 = 入っていない)
Install-WinGet          # 古ければ固定した版に上げる (dotfiles apply --steps winget と同じ)
Install-WinGet -Force   # 固定した版と同じでも落として入れ直す (流れを確かめるため。新しい版なら何もしない)
```

| すること | 中身 |
| --- | --- |
| 取得元 | GitHub の `microsoft/winget-cli` の Release `v<固定した版>` の `Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle` (約 220 MB) と `DesktopAppInstaller_Dependencies.zip` (約 100 MB)。Microsoft Store は使わない |
| 確かめ | 2 つの SHA-256 を `Install-WinGet.ps1` の表 (`Get-WinGetRelease`) の値と比べ、違えば何も入れずに止まる。msixbundle は Microsoft の署名も Windows が確かめる |
| 依存 | zip の中のこの CPU (x64・arm64) の `Microsoft.VCLibs.140.00`・`Microsoft.VCLibs.140.00.UWPDesktop`・`Microsoft.WindowsAppRuntime.1.8` のうち、入っている framework の版が足りないものだけを `-DependencyPath` に渡す |
| 入れ方 | `Add-AppxPackage -Path <msixbundle> -DependencyPath … -ForceApplicationShutdown` をこのユーザーに。管理者に昇格しない (UAC を出さない)。`-AllUsers`・`Add-AppxProvisionedPackage` は使わない (Release の License の xml は要らない)。Appx の cmdlet は PowerShell 7 から読めないことがあるので、いつも System32 の Windows PowerShell に打たせる |
| 下げない | `winget --version` が固定した版以上なら何もしない (Store が上げた新しい版・preview もそのまま。`-Force` でも下げない) |
| 入れられないとき | CPU が x64・arm64 でない・`curl.exe` が無い・固定した版の SHA-256 が表に無いときは、何もせずに知らせる (締めの行は「→ ※ の手順で直す」)。`Add-AppxPackage` が落ちたら HRESULT を出し、`0x80073CFF` (サイドロードを方針で止めた PC の見込み) などには直し方を添える |

- 入れる・上げるときは、動いている winget とアプリ インストーラーが終わる (`-ForceApplicationShutdown`)。別の端末で winget を打っている間は流さない
- 落とす先は `github.com` と `release-assets.githubusercontent.com` (proxy で止めている PC では落とせない)
- PSGallery の `Microsoft.WinGet.Client` の `Repair-WinGetPackageManager` は使わない (module を PSGallery から入れる手が増え、落とした物の SHA-256 を
  dotfiles で固定できない。落とす先は同じ GitHub の Release)

### winget の固定した版を上げる

固定した版は**下限**で、winget の新しい版を追いかけない (Store が使える PC は Store が上げる)。上げるのは次のときだけ:

- dotfiles の道具が新しい winget の動きを前提にするとき (1.30 の portable の入れ方のように)。その道具の直しと同じ PR で上げる
- 固定した版より古い winget に、直したい不具合・脆弱性が見つかったとき

上げる版は、GitHub の Release の版から、出てから日の経ったもの (依存の更新の猶予。7 日を目安。急ぐときはユーザーが決める) を選び、`-preview` の版は
選ばない。新しい版の知らせ (`pin-updates`・`winget-versions`) には載せていない (追いかけないため)。

1. 上げる版の 2 つの物の SHA-256 を GitHub の API の digest で読む (Release の `<物>.txt` にも同じ値がある):

   ```sh
   gh api repos/microsoft/winget-cli/releases/tags/v<版> \
     --jq '.published_at, .prerelease, (.assets[] | select(.name | test("msixbundle$|Dependencies.zip$")) | "\(.name) \(.digest)")'
   ```

2. `win/winget/Install-WinGet.ps1` の `-Version` の既定値と、`Get-WinGetRelease` の表 (`Bundle`・`Dependencies`) を変える (古い行は消してよい)。
   `Install-WinGet.Tests.ps1` の `$V` も変える
3. 依存の zip の中の形 (`<arch>/<Name>_<Version>_<arch>.appx`) と依存の名前が変わっていないかを、Release の `DesktopAppInstaller_Dependencies.json` で見る
   (変わっていれば `Get-WinGetDependencyEntries` を直す)
4. 試験 (`Install-WinGet.Tests.ps1`) を流し、Windows で `Install-WinGet -Check` と `Install-WinGet` (古い PC で) を打って確かめる
5. 前提にする版を上げたなら、この節の頭と、前提を見ている道具 (`Install-Codex` の 1.30 の見分け) も合わせる

## winget の portable の道具

winget の portable (zip の中の portable か、portable の exe。管理者無しで `%LOCALAPPDATA%\Microsoft\WinGet\Packages` の下に入る) で入れる道具は、
共通の枠 `winget/WingetPortable.ps1` で固定した版に揃える (dotfiles-private の ADR 122 (`docs/adr/122_win_winget_portable_frame_*`))。道具ごとの
`Install-<道具>.ps1` は、道具の表 (hashtable) と、要るときだけの custom の関数を持つ薄い入口で、引数 (`-Version`・`-Check`・`-IfMissing`)・終了コード
(0 揃っている・1 差がある・3 入っていない・2 確かめられない)・出力の形 (状態の表と締めの行) は道具によらず同じ。

| 道具 | 入口 | 表のほかに持つもの |
| --- | --- | --- |
| fzf | `fzf/Install-Fzf.ps1` | MSI の fzf を見る (表の `Msi`) |
| ghq | `ghq/Install-Ghq.ps1` | (なし) |
| starship | `starship/Install-Starship.ps1` | MSI の starship を見る (表の `Msi`) |
| ntn | `ntn/Install-Ntn.ps1` | (なし) |
| Claude Code | `claude-code/Install-ClaudeCode.ps1` | 自動更新の変数 (`CLAUDE_CODE_PACKAGE_MANAGER_AUTO_UPDATE`) を見て ※ で知らせる (`ReadState`・`Notes`) |
| herdr | `herdr/Install-Herdr.ps1` | 前の `Herdr.Herdr.Preview` (残っていれば知らせ、入れ替えを止め、外す手順を出す。`ReadState`・`PathKind`・`Manual`・`Blocker`・`RowsAfterPath`・`Notes`・`Verdict`)。依存の VCRedist を winget に入れさせるので、`--installer-type` を名指ししない (表の `InstallerType = $null`) |
| Codex CLI | `codex/Install-Codex.ps1` | `codex` と打てる形 (symlink・hardlink)・同梱の rg の PATH・化けた `codex-path` の行・1.29 以前の winget (`ReadState`・`Reinstall`・`Holds`・`Drift`・`BeforeWinget`・`AfterWinget`・`RowsBeforePath`・`RowsAfterPath`・`Verdict`) |

winget 自身 (`winget/Install-WinGet.ps1`) は msixbundle で、枠に入れない。

流れ (`Invoke-WingetPortable`)。() の中は道具が足せる custom の口で、表の `Hooks` に関数の名前を書く:

```text
① 入口             Install-<道具>.ps1 が道具の表を渡す。枠が既定の値で埋める (知らない key は止める)
② 打ってよいか     見張り: MSI の道具 (Msi)・道具の見張り (Holds)・昇格した会話 (winget 1.30 以降)
③ 状態を読む       置き場所の exe と版・winget の版の一覧と pin・PATH で引かれるもの・動いている exe・winget の版と昇格 (ReadState・PathKind)
④ することを決める install / change / relink / none (Reinstall)・直る差と直らない差 (Drift・Manual)・止める理由 (Blocker)
⑤ winget を打つ    取得を確かめ (download)、pin を外し、外して入れ、pin を足す (BeforeWinget・AfterWinget)
⑥ 表と終了コード   状態の表 (RowsBeforePath・RowsAfterPath・Notes)・締めの行 (Verdict)・終了コード
```

表の key と custom の口の中身は `WingetPortable.ps1` の頭に書いてある。揃える流れは [ntn](#ntn) の「揃えるときにすること」のとおり (取得を確かめてから
外して入れ、pin を足し、読み直す)。

### 昇格した PowerShell では入れない

winget 1.30 は、昇格した会話 (UAC で昇格した PowerShell・管理者として実行した端末。token の `TokenElevationType` が Full) から user スコープの portable を
入れる・外すのを `0x8A15007D` で断る (dotfiles-private の ADR 120 (`docs/adr/120_codex_cli_without_uac_*`))。どの portable の道具も、入れる・入れ替える・
入れ直すときに、会話が昇格していて winget が 1.30 以降なら、winget を打たずに止まる:

- `-Check` の表に「⚠ 昇格した PowerShell では winget が <道具> を入れない」と打ち直し方の ※ が出る。締めの行はその 1 行 (「→ ※ の手順で直す」) だけで、
  終了コードは入っていなくても 1 (runner が `-IfMissing` で入れにいかない)
- runner (`dotfiles apply`) と WSL の setup は入れずに知らせる。昇格していない PowerShell (デスクトップの普通の端末) か、そこから開いた WSL で流し直す
- pin を足す・外すだけなら止めない (winget 1.30.310 で、昇格した会話からの `winget pin add` が通ることを確かめた)。UAC の分かれていない管理者
  (Administrator・UAC が off) は昇格した会話に当たらない (winget も断らない)。見分けは winget と同じ (`Runtime::IsRunningWithNonDefaultFullToken`)
- winget の版が読めなければ、止めずに打ってみる。token を読めない (`Add-Type` が方針で止められたなど) ときも昇格していないとして打つ (管理者の
  ロールで代えると、UAC が off の管理者を昇格したと見誤って入れられなくなる)。`0x8A15007D` で落ちたら (pin を足す・外すのを断られたときも)、昇格して
  いない PowerShell で打ち直す行を添える

### PATH の形

winget は portable を入れると、`WinGet\Links` に symlink を置く (開発者モードが on のときなど) か、symlink を作れなければ置き場所 (exe のディレクトリ) を
ユーザーの PATH に足す。manifest に `ArchiveBinariesDependOnPath: true` がある道具 (herdr) は、開発者モードでも symlink を作らず、置き場所を PATH に足す。`-Check` の「PATH の <コマンド>」は、どちらも winget の portable のものとして読み、どちらの形かを括弧で添える
(`(WinGet\Links の symlink)`・`(置き場所)`)。ほかのものが先に引かれる・入っているのに見つからないときは ⚠ と直し方の ※ を出す (揃える手順では直らない)。
PATH は `.exe` のほか `.cmd`・`.bat`・`.ps1` も、PowerShell と同じくディレクトリの順に見る。

`WinGet\Links` のものは、symlink の指す先も読む。指す先がその道具の置き場所の外 (同じ名前のコマンドを持つほかのパッケージ。herdr の
`Herdr.Herdr.Preview` など) なら winget の portable のその道具とは読まず、「PATH の <コマンド>」に `<Links のパス> → <指す先>` と出して ⚠ にする。
直し方の ※ は、指す先を入れたパッケージを `winget uninstall` で外すか symlink を消す (`WinGet\Links` をユーザーの PATH から外すと、winget の portable の
どれもが引けなくなるので勧めない)。指す先が読めなければ、今までどおり `(WinGet\Links の symlink)` と読む。

### 道具を足す

1. `win/<道具>/Install-<道具>.ps1` を、ほかの入口 (`ghq/Install-Ghq.ps1` など) を写して作る。変えるのは頭の説明・param の `-Version` の既定値・
   `$packageId` の行・道具の表 (`Get-<道具>Tool`)。枠を探す頭の数行と、末尾の入口の数行はそのまま写す
2. `[string]$Version = '<版>'` と `$packageId = '<ID>'` の 2 行は、版の知らせ (runner の `pin-updates`・WSL の `check-winget-version.sh`) と依存の更新の
   skill が読むので、この形のまま置く
3. winget の manifest (`microsoft/winget-pkgs` の `manifests/<頭の字>/<発行元>/<名前>/<版>/<ID>.installer.yaml`) に依存 (`Dependencies`) があり、それを
   入れる道具は、表の `InstallerType` を `$null` にする。winget は `--installer-type` を依存の解決にも効かせ、burn しか無い `Microsoft.VCRedist.2015+.x64`
   などに合うインストーラーが無くなって `0x8A150104` で落ちる (herdr の manifest がこの形)。依存を入れない道具 (`InstallArguments` に `--skip-dependencies`。codex) は名指ししてよい。
   MSI のある道具 (fzf・starship) は portable を名指しし、表の `Msi` で MSI を見張る
4. 試験 `Install-<道具>.Tests.ps1` は、表の値 (版の拾い方・exe の置き場所・見出しと締めの行の字) と custom の関数を確かめる。流れ・見張り・終了コードの
   決まりは枠の試験が見る
5. `manifest.toml` に入口を足し (枠は足してある)、`powershell/dotfiles.ps1` に `Install-<道具>` を、runner の `runner/src/steps/ps1.rs` に手順を足す
   (`output_fixes` に `elevated_fix!`。runner の試験が、入口と枠の字を突き合わせる)。依存の更新の拡張 (`.claude/skills/pjp-dotfiles-deps/`) にも足す

### WingetPortable.ps1 を書くときの注意

- `dotfiles.ps1` と同じく **BOM 付きの UTF-8** で保存し、Windows PowerShell 5.1 と PowerShell 7 の両方で動く書き方にする
- 入口が dot-source する ps1 で、PowerShell の module (`.psm1`) にしない (試験が dot-source した後に `Invoke-Winget` などを差し替えて流れを確かめる。
  module の中の呼び出しは module の関数を引き、差し替えが効かない。`Import-Module` は開いたままの PowerShell に古い module を残しうる)
- 表は `Complete-PortableTool` が既定の値で埋めてから使う (StrictMode では、hashtable に無い key を `.` で読むと例外になる)。custom の口が返す行も
  hashtable で、添字で読む。口が返した `$null` は除く (`return $null` も 1 つの値になり、`@()` で包むと数に入る)
- パスは `\` で切る (`Get-PortableParent`)。`Split-Path` は Linux の pwsh で `/` に組み直すので、試験と字がずれる
- 副作用の無い関数と、winget とプロセスを偽物に差し替えた流れ (見本の道具の表で、custom の口と見張りまで) は `winget/WingetPortable.Tests.ps1` で
  確かめる (Linux の pwsh)。本物の `Get-PortableState` も、葉 (ファイルの有無・winget・PATH・symlink・昇格) だけを偽物にして流し、読んだ値の入り先と
  custom の口が受け取るものを見る。枠を使う入口を全部、配った写しの形 (隣の枠) と clone の形で起こし、枠が無ければ終了コード 2 で止まることも見る:

  ```sh
  nix shell nixpkgs#powershell -c pwsh -NoProfile -File win/winget/WingetPortable.Tests.ps1
  ```

- 状態の表の見出し (`<Name> (winget の <PackageId>`)・締めの行 (`→ <Command> で入れる`・`→ <Command> で揃える`・`→ ※ の手順で直す`)・見張りの行
  (`MSI の <Name> (machine スコープ) が入っている`・`昇格した PowerShell では winget が <Name> を入れない`) は、runner の `runner/src/steps/ps1.rs` と WSL の
  wrapper (`nix/scripts/bootstrap-windows-ntn.sh` など) が読む。runner の試験 (`scripts_carry_the_phrases_the_runner_reads`) は、枠の字の `$($Tool.Name)`・
  `$($Tool.Command)`・`$($Tool.PackageId)` を入口の表の値に替えてから突き合わせるので、この 3 つはこの形のまま書く (変えるときは向こうも直す)
- `Invoke-Winget` の本文は `openssh/Install-OpenSSH.ps1` と同じ ([Install-OpenSSH.ps1 を書くときの注意](#install-opensshps1-を書くときの注意))
- winget やプロセスに触る本物の部分は、実機で `-Check` と本番を打って確かめる

## winget の pin

winget で版を固定して入れるもの (OpenSSH・herdr・Google 日本語入力・ntn・Claude Code・Tailscale・ghq・fzf・starship・Codex CLI と、[bootstrap](#bootstrap-新しい-windows-で最初に流す) が
入れる 4 つ) は、入れた後に `winget pin add --id <ID> --exact` で pin (種類は Pinning) を足し、`winget upgrade --all` から外す。版を変えるときに
自分の pin に止められない打ち方は、winget の作り (`microsoft/winget-cli` の `WorkflowBase.cpp`・`PinningData.cpp`) に合わせて決めてある
([ADR 063](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/063_win_winget_pin_include_pinned_20261116T132001JST/README.md)):

| 打つもの | pin (Pinning) があるとき |
| --- | --- |
| 入っているものへの `winget upgrade --id <ID> --exact --version <版>` | 止められる (終了コード `0x8A150068`。版を名指しすると、名指しの upgrade でも pin を見る) |
| 上に `--include-pinned` を付ける | 通る (Pinning を越える。Blocking の pin と、Gating の pin の範囲の外は越えない) |
| 入っているものへの `winget install --version <版>` | 止められる (upgrade の道に移る。install は `--include-pinned` を受け付けない) |
| 入っていないものへの `winget install`・`winget uninstall`・`winget download` | pin を見ない (pin が残っていても) |

- 上げる道は `--include-pinned` を付けた upgrade (OpenSSH・Google 日本語入力・Tailscale)、入れ替える道は uninstall → install (herdr・ntn・Claude Code・ghq・fzf・starship・Codex CLI。
  入っていない形にしてから入れるので pin を見ない)。どちらも `*.Tests.ps1` が確かめる (upgrade には `--include-pinned` を付け、install・
  uninstall には付けない)
- 手で揃えるときも、版を名指しした upgrade に `--include-pinned` を付ける (bootstrap の ※ の行と[版のずれを手で揃える](#版のずれを手で揃える))。
  pin は付いたまま残る
- `0x8A150068` で落ちたら (pin を Blocking・Gating に替えた・入っていると winget が見ているのに install を打った)、OpenSSH・Google 日本語入力・Tailscale は
  pin の確かめ方と外し方を ※ で添える。`winget pin remove --id <ID> --exact` で外して打ち直すと、揃えた後に pin を足し直す

## winget の新しい版を確かめる

winget で版を固定しているもの (OpenSSH・herdr・Google 日本語入力・ntn・Claude Code・Tailscale・ghq・fzf・starship・Codex CLI と、[bootstrap](#bootstrap-新しい-windows-で最初に流す) が
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
| `tailscale` | `tailscale/Install-Tailscale.ps1`・`tailscale/skipped-versions.txt` | winget-pkgs に載った日 (GitHub の release には winget に載らない版があるので比べない) | [Tailscale の新しい版が出たとき](#tailscale-の新しい版が出たとき) |
| `ghq` | `ghq/Install-Ghq.ps1`・`ghq/skipped-versions.txt` | winget-pkgs に載った日 (GitHub の release の多くが winget に載らないので比べない) | [ghq・fzf の新しい版が出たとき](#ghqfzf-の新しい版が出たとき) |
| `fzf` | `fzf/Install-Fzf.ps1`・`fzf/skipped-versions.txt` | winget-pkgs に載った日 (GitHub の release には winget に載らない版があるので比べない) | 同じ |
| `starship` | `starship/Install-Starship.ps1`・`starship/skipped-versions.txt` | winget-pkgs に載った日 (GitHub の release には winget に載らない版があるので比べない) | [starship の新しい版が出たとき](#starship-の新しい版が出たとき) |
| `codex` | `codex/Install-Codex.ps1`・`codex/skipped-versions.txt` | winget-pkgs に載った日 (GitHub の release には winget に載らない版があるので比べない) | [Codex CLI の新しい版が出たとき](#codex-cli-の新しい版が出たとき) |
| `git` | `bootstrap/Install-Bootstrap.ps1` の `-GitVersion`・`bootstrap/skipped-versions/git.txt` | GitHub の release (`git-for-windows/git` の `v<X.Y.Z>.windows.<N>`。winget の版は N が 1 なら `X.Y.Z`、ほかは `X.Y.Z.N`) が出た日 | [bootstrap の固定した版の新しい版が出たとき](#bootstrap-の固定した版の新しい版が出たとき) |
| `gh` | `bootstrap/Install-Bootstrap.ps1` の `-GhVersion`・`bootstrap/skipped-versions/gh.txt` | GitHub の release (`cli/cli` の `vX.Y.Z`) が出た日 | 同じ |
| `pwsh` | `bootstrap/Install-Bootstrap.ps1` の `-PwshVersion`・`bootstrap/skipped-versions/pwsh.txt` | winget-pkgs に載った日 (7.6 の線の版だけを読む。7.7 は MSI が無く、MSIX は別の package。GitHub の release には読まない線の版も並ぶので比べない) | 同じ |
| `vs-buildtools` | `bootstrap/Install-Bootstrap.ps1` の `-VsBuildToolsVersion`・`bootstrap/skipped-versions/vs-buildtools.txt` | winget-pkgs に載った日 (GitHub の release が無い) | 同じ |
| `rustup` | `bootstrap/Install-Bootstrap.ps1` の `-RustupVersion`・`bootstrap/skipped-versions/rustup.txt` | winget-pkgs に載った日 (tag だけで GitHub の release を出さない) | 同じ |

- 確かめるのは `nix/scripts/check-winget-version.sh <名前>`。ps1 から固定した版とパッケージ ID (`$packageId`。bootstrap の 5 つは
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
- パッケージ ID を確かめる: job が出す `winget search …` (`OpenSSH`・`herdr`・`JapaneseIME`・`ntn`・`ClaudeCode`・`Tailscale`・`ghq`・`fzf`・`starship`・`codex`・`Git.Git`・`GitHub.cli`・
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
    ※ herdr-app を上げるなら、新しい既定のキーも足す (dotfiles がキーを書き足した keys.json には、herdr-app を上げても新しい既定のキーが足されない)
      → 上げる版までの更新ノート (What's new。中身は herdrdev/herdr-app の CHANGELOG.md) で keys.json に触れた項 (「if you edited keys.json, add …」など) を探し、Windows で効くキーを win/herdr-app/keys.json に足す (dotfiles のキーと重なる既定のキーは、その既定の値を keys.defaults.json に書く。win/README.md の「固定した版を上げる」)
```

| 名前 | 固定した版 | 新しい版の一覧と出た日 | 見送りの一覧 |
| --- | --- | --- | --- |
| `openssh`・`herdr`・`google-japanese-input`・`ntn`・`claude-code`・`tailscale`・`ghq`・`fzf`・`starship`・`codex` | `win/<名前>/Install-*.ps1` の `-Version` の既定値 | `nix/scripts/check-winget-version.sh --json` (winget-pkgs の版。出た日は [winget の新しい版を確かめる](#winget-の新しい版を確かめる) の表と同じ) | `win/<名前>/skipped-versions.txt` (「版 理由」) |
| `herdr-app`・`herdr-core` | `nix/pkgs/herdr-core/releases.json` | `nix/scripts/check-herdr-app-version.sh --json` (GitHub の tag のうち Windows の成果物があるもの。出た日は成果物の Last-Modified) | `nix/pkgs/herdr-core/skipped-versions.txt` (「app か core・版・理由」) |
| `git`・`gh`・`pwsh`・`vs-buildtools`・`rustup` | `win/bootstrap/Install-Bootstrap.ps1` の名前ごとの param (`-GitVersion` など) の既定値 | `nix/scripts/check-winget-version.sh --json` (出た日は [winget の新しい版を確かめる](#winget-の新しい版を確かめる) の表と同じ) | `win/bootstrap/skipped-versions/<名前>.txt` (「版 理由」) |

- 対象は Windows へ配るマシン (`dotfiles.wsl.windowsFiles.enable = true`) だけ。ntn・Claude Code・herdr (herdr-app・herdr-core も)・Tailscale・Codex CLI は、
  入れるマシン (`windowsFiles.ntn.enable`・`windowsFiles.claudeCode.enable`・`windowsFiles.herdr.enable`・`windowsFiles.tailscale.enable`・
  `windowsFiles.codex.enable`) でだけ確かめる。bootstrap の
  5 つ (git・gh・pwsh・vs-buildtools・rustup) は、Windows の ghq に dotfiles の clone がある (`<windowsHome>/ghq/github.com/pollenjp/dotfiles/.git`
  がある。bootstrap を流した) マシンでだけ確かめる。ghq・fzf・starship も同じマシンでだけ確かめる (入れるのは bootstrap の clone の runner の手順
  `ghq`・`fzf`・`starship` だけで、WSL の setup は入れない)。下の `--candidates` と JSON の口は、このマシンで入れるかによらず全部を出す
- 知らせるのは、固定した版より新しく、見送っていない版。新しい版の数が 4 つ以上なら、頭と末尾と個数だけを出す。無ければ「無い」の
  1 行だけ (警告のまとめには載らない)
- herdr-app に見送っていない新しい版があるときは、続きの行の末尾に keys.json の注意を 2 行添える (上の例の ※ と →)。dotfiles がキーを
  書き足した keys.json には、herdr-app を上げても新しい既定のキーが足されない ([herdr-app のキー](#herdr-app-のキー))。上げる作業の中で、上げる版
  までの更新ノートの既定のキーを repo の `win/herdr-app/keys.json` に足す ([固定した版を上げる](#固定した版を上げる)の 3)。herdr-core だけのとき・
  herdr-app は見送った版だけのときは添えない。末尾に置くのは、警告のまとめが続きの行の長い警告の間を省いても、末尾は残すため
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

### runner の pin-updates

Windows の runner の手順 `pin-updates` (`runner/src/steps/pin_updates/`) も、同じ名前・判定・文で知らせる。受け持ちを runner に切り替えたホストでは
`dotfiles check`・`dotfiles apply` が流し、受け持ちが WSL の間も `dotfiles check` で同じものを見られる (Windows のホストの値と WSL の記録、Windows の
dotfiles の clone と WSL の `~/dotfiles` が揃っていれば、WSL の setup と同じ名前と版が出る)。

```text
━━ [97] pin-updates: 固定した版より新しい版が出ていないかを知らせる ━━
!! Windows に固定した版より新しい版があります → Claude Code に「dotfiles の Windows に固定した版を上げて」と頼み、上げるか (どの版か) を決める
   Windows の GitHub CLI: 2.103.3 → 2.104.0・2.105.0
…
  · [97] pin-updates          Windows に固定した版より新しい版があります → Claude Code に「dotfiles の Windows に固定した版を上げて」と頼み、上げるか (どの版か) を決める
      ※ Windows の GitHub CLI: 2.103.3 → 2.104.0・2.105.0
```

- 名前の on/off は、WSL の記録の代わりに Windows のホストの値の道具の switch (ntn は `windowsNtn`、Claude Code は `windowsClaudeCode`、herdr・
  herdr-app・herdr-core は `windowsHerdr`、Tailscale は `windowsTailscale`、Codex CLI は `windowsCodex`。それを入れる手順と同じ switch) と、Windows の ghq の dotfiles の clone
  (`%USERPROFILE%\ghq\github.com\pollenjp\dotfiles\.git`。bootstrap の 5 つと、その clone の runner の手順 `ghq`・`fzf`・`starship` が入れる ghq・fzf・starship) で決める
- GitHub は Windows の gh (`gh api`。bootstrap が入れてログインする) で読む。herdr-app・herdr-core の版ごとの Windows の成果物があるかは、WSL と
  同じ引数の curl (PATH で最初に見つかるもの。ふつうは System32 の `curl.exe`。`Install-HerdrApp.ps1` も同じ探し方で同じ取得元を落とす) の HEAD で
  見る (runner に HTTP の crate を足さない)
- 締めの表の行: 見送っていない新しい版があれば `·` (知らせるだけで、終了コードに数えない。上げるのは repo の PR なので、`dotfiles apply` では直らない)。
  無ければ ✔。gh が無い・ログインしていない・確かめられなかった名前があれば ⚠ (出力の `!!` の行がわけ)。何も書かず、check・dry-run・apply は同じ
- 手順の出力は WSL の script と同じ字。違うのは、gh が無いときの直し方 (WSL は home-manager switch、runner は bootstrap)・確かめられなかったときに
  「setup は続けます。」を書かないこと・`releases.json` の誤りの文のパス (runner の clone の Windows のパス)・runner にしか無い失敗の文 (見送りの一覧が
  読めない・gh や curl を起こせない・curl が無い)。空白は WSL の setup が流れる C.UTF-8 の bash の `[[:space:]]` と同じに読む (見送りの一覧の全角の
  空白だけの行も読み飛ばす)
- SSH の会話 (鍵で入った会話) では、gh の資格情報 (Windows の資格情報マネージャー) を読めず、gh がログインしていないように見えるかもしれない
  (確かめていない)。そのときは ⚠ の行にその旨を添える。デスクトップの端末で流す
- `--candidates` と JSON の口は runner に写していない。依存の更新の skill は今までどおり Linux の repo で WSL の script の口を打つ

## PowerShell のテスト

`win/*/*.Tests.ps1` (`Install-OpenSSH.Tests.ps1`・`Install-Herdr.Tests.ps1`、winget の portable の道具の共通の枠の `WingetPortable.Tests.ps1` など) は、`*.ps1` の
副作用の無い関数を確かめる。
Linux の pwsh で流すので Windows には触らない。CI の `lint` ([`.github/workflows/nix.yml`](../.github/workflows/nix.yml)) が、
flake が固定している nixpkgs の pwsh で全部を流す (`Start-PortForward.Tests.ps1` は PATH の ssh を引くので、nixpkgs の
openssh も渡す。`dotfiles.Tests.ps1` は PATH に ghq と fzf があれば cdrepo を本物でも流すので、nixpkgs の ghq と fzf も渡す。
`Invoke-DotfilesSelfUpdate.Tests.ps1` は PATH の git で一時の repo と手元の remote を作って `dotfiles --self-update` を流す。git の設定は一時の空のファイルに
し、git が無ければその試験を飛ばす。`Invoke-DotfilesRunner.Tests.ps1` は PATH の git で一時の repo を作って launcher を流し、python3 があれば手元の HTTP
server から runner の exe を落とす組も流す (無ければその組を飛ばす))。手元で同じことをするには、repo の root で:

```sh
nix shell --inputs-from ./nix nixpkgs#powershell nixpkgs#openssh nixpkgs#ghq nixpkgs#fzf nixpkgs#python3 --command bash -c '
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

配るのは共有設定の `powershell/dotfiles.ps1` だけで、`$PROFILE` そのものは配らない (`dotfiles --self-update` の中身の
`powershell/Invoke-DotfilesSelfUpdate.ps1` も配らず、`dotfiles` 関数が clone の中のものを呼ぶ。[clone を進める](#clone-を進める-dotfiles---self-update))。
`$PROFILE` はドキュメントの下にあり、ドキュメントの位置は OneDrive の設定でマシンごとに
変わる (この PC では `OneDrive\ドキュメント`) ので、manifest の `dst` に書けない。

`$PROFILE` に読み込みの 1 行を足すのは、`setup --update` の
`nix/scripts/bootstrap-windows-powershell-profile.sh` (`dotfiles.ps1` を配る手順の後に走る)。受け持ちを runner に切り替えたホストでは、
runner の `powershell-profile` の手順が同じ判定で足す ([runner の手順](#runner-の手順))。
`pwsh.exe` に `$PROFILE` の場所を聞き、次の 1 行が無ければ足す:

```powershell
if (Test-Path "$HOME\.config\powershell\dotfiles.ps1") { . "$HOME\.config\powershell\dotfiles.ps1" }
```

- `Test-Path` で囲むのは、`$PROFILE` が OneDrive で他の PC へ同期されるため。dotfiles を
  配っていない PC でも、起動のたびにエラーを出さずに済む
- dot-source (`.`) で読む。`&` で呼ぶと子の scope で定義され、呼び終わりに消える
- 直して配ったら、開いている PowerShell では `. $PROFILE` で読み直す
- `$PROFILE` は手元のファイルのまま残る。dotfiles が足すのは、この 1 行と、その前に置く starship の init の 1 行 (runner の `starship-init`。
  [starship](#starship)) だけ。そのマシンだけの設定はそこに置いたままでよい。ただしキーの割り当て (`Set-PSReadLineKeyHandler`。PSFzf など) は、`dotfiles.ps1` を読む行より後に置く
  (`dotfiles.ps1` が EditMode を Vi に替え、PSReadLine は EditMode を替えるとそのモードの既定の割り当てに戻すので、前に置いた割り当ては消える。
  [Vi モード](#vi-モード))
- 足した 1 行を消すと、次からは足し直さない (Windows 側で外したものとして扱う)。戻すなら
  `nix/scripts/bootstrap-windows-powershell-profile.sh --force` (受け持ちを runner に切り替えたホストでは
  `dotfiles apply --steps powershell-profile --force`)
- WSL の setup は `$PROFILE` の場所を WSL の interop で聞く (runner は pwsh に直に聞く)。聞けないと足せないので、そのときは
  setup (runner) が出す次のコマンドを PowerShell 7 で 1 回打つ:

  ```powershell
  Add-Content -Path $PROFILE -Value 'if (Test-Path "$HOME\.config\powershell\dotfiles.ps1") { . "$HOME\.config\powershell\dotfiles.ps1" }'
  ```

alias の名前と中身は WSL の fish の abbr (`nix/home/modules/fish.nix`) と bash の alias
(`nix/home/modules/bash.nix`) とそろえてある。`dotfiles.ps1` は、同じ名前と中身を略語の表 (`$DotfilesAbbr`。
[略語を広げる](#略語を広げる-fish-の-abbr-に似せる)) にも持つ。
足す・直すときは 3 つを変える (`dotfiles.ps1` では function・alias と略語の表の両方。食い違いは `dotfiles.Tests.ps1` が見つける)。

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
| `cs` | `claude-selector` (claude のアカウントと option を矢印キーで選んでから起こす。runner の手順 `claude-selector` が置く exe。[claude-selector (cs)](#claude-selector-cs)) |

叩くのは Windows に入れた `herdr.exe` (WinGet の `Herdr.Herdr`) で、WSL の herdr とは
別の server (session を共有しない)。`c` も Windows に入れた `claude.exe` (WinGet の `Anthropic.ClaudeCode`。
dotfiles が固定した版で入れる。[後述](#claude-code)) を叩き、WSL の claude とは別のもの。

### cdrepo (ghq の repo を選んで移る)

`cdrepo` は、ghq の repo の一覧 (`ghq list`) を fzf で絞り込んで 1 つ選び、`ghq root` の下のその repo へ移る。WSL の fish と bash の `cdrepo`
(`nix/home/modules/fish.nix`・`bash.nix` の function) と同じ動きにそろえてある (知らせる文と fzf の引数は `dotfiles.Tests.ps1` が突き合わせる)。
PowerShell 7 と Windows PowerShell 5.1 のどちらでも動く。

- fzf は `-1 +m` で起こす (候補が 1 つならそのまま選び、選べるのは 1 つ)。Enter で選ぶと移り、Esc・Ctrl+C で選ばずに抜けると移らない
  (そのときの `$LASTEXITCODE` は fzf の 130)
- ghq と fzf は、Windows の runner の手順 `ghq`・`fzf` (`dotfiles apply`) か `Install-Ghq`・`Install-Fzf` が winget で入れる ([ghq・fzf](#ghqfzf))。
  どちらかが無ければ、fish・bash と同じ `ghq is not installed`・`fzf is not installed` を出して止まる。PowerShell の function は終了ステータスを
  返せないので、止めたときは `$LASTEXITCODE` を 1 にする (fish・bash の `return 1` に当たる。`dotfiles` 関数と同じ)
- ghq の root は ghq の既定の `%USERPROFILE%\ghq` (bootstrap が dotfiles などを clone する所)。`ghq list` は `/` で区切って出すが、移った後の
  場所は `\` にそろう
- ghq と fzf (Go) は UTF-8 で読み書きするので、cdrepo は 2 つを呼ぶ間だけ `[Console]::OutputEncoding` と `$OutputEncoding` を BOM の無い UTF-8 に
  し、終わったら戻す。日本語の Windows の既定 (`[Console]::OutputEncoding` は CP932、5.1 の `$OutputEncoding` は ASCII) のままだと、ASCII でない
  repo のパスや ghq の root が化けて移れない。Windows PowerShell 5.1 は関数の中で替えた `$OutputEncoding` を外のコマンドへのパイプに使わないので、
  global の値を替えて戻す (5.1 と 7 で確かめた)
- ghq と fzf を入れた直後は、新しい PowerShell を開く。winget は置き場所をユーザーの PATH に足すだけなので、`dotfiles apply` を流した PowerShell
  のままでは `ghq is not installed` になる
- 略語ではない (fish でも function) ので、上の表と略語の表 (`$DotfilesAbbr`) には入れていない

### 略語を広げる (fish の abbr に似せる)

上の表の略語は、打った所 (入力行の中) で中身に広げてから実行する (WSL の fish の abbr と同じ)。`hr` と打って Space を押すと、
入力行が `herdr --remote ` になる。何が動くかを打つ前に見られ、履歴にも広げた行が残る。`dotfiles.ps1` の略語の表 (`$DotfilesAbbr`)・
広げる所を決める関数 (`Get-DotfilesAbbrExpansion`)・PSReadLine のキーの割り当てでしていて、`$PROFILE` で読んだ対話の PowerShell で効く。
キーは [Vi モード](#vi-モード)の挿入モードに割り当てる。

| キー | すること |
| --- | --- |
| Space・`;`・`\|`・`&`・`)` | 略語を広げてから、打った字を入れる |
| Enter | 略語を広げてから実行する (行が閉じていなければ、いつもどおり次の行へ進む) |
| Ctrl+Space・Shift+Space | 広げずに空白を入れる (略語の名前のまま打ちたいときに使う。Ctrl+Space は fish と同じ。Shift+Space は Windows Terminal などで効き、herdr・hc の端末ではただの Space として届いて広がる) |

- 広げるのは、カーソルの直前で終わる語がコマンドの名前の位置にあり、表にあるときだけ。コマンドの位置かは PowerShell の構文で見る
  (入力行を Parser で読む)
  - 広げる: 行頭 (先頭の空白の後も)、`|`・`;`・`&&`・`||` の後、閉じていない `(`・`{`・`$(`・`@(` の中、`$x = hr` の右、2 行目、
    文字列の中の `$(` の中 (`"$(hr`。構文ではコマンドの位置)
  - 広げない: 引数 (`git hr`)・`-hr`、引用符の中、`& hr`・`. hr`、長い語 (`hrx`)、大文字小文字が違う語 (`HR`。表は区別する)、
    `$hr`、コメント、`--%` の後、function の名前・ハッシュテーブルのキー・リダイレクトの先、カーソルが語の後ろの空白の後や
    後ろの語の上にあるとき
  - `e` (中身の `exit` はキーワード) は、文の頭 (行頭・`;` の後・`$(`・`@(`・`{` の中・`$x = e` の右) でだけ広げる。`|`・`&&`・`||` の
    後と閉じていない `(` の中では、`exit` がコマンドの名前として読まれ、`exit` というコマンドは無いので落ちる (function の `e` なら
    シェルを抜ける)。そこでは広げずに function に任せる
- 広げた後に Ctrl+Z を 2 回押すと略語に戻る (1 回目で打った字を、2 回目で広げたのを戻す)。字を選んでいる間は広げない
- コマンドモードの Enter (`ViAcceptLine`) と、挿入モードの Ctrl+d (`ViAcceptLineOrExit`) で実行したときは広げない。略語の function・alias が
  そのまま動くので結果は同じで、履歴には略語のまま残る
- 略語の function・alias は残してある。script や PSReadLine の無い所 (`pwsh -File`・`-NonInteractive`・ISE) では今までどおり
  function・alias が動く (割り当ては PSReadLine を読み込んだ PowerShell でだけする)
- 広げた行は、function・alias を呼んだときと同じに動く。違うのはパイプの後に置いたときで、function (`hst` など) は前のコマンドの
  出力を中のコマンドへ渡さないが、広げた行 (`… | herdr status`) は渡す (fish の abbr と同じ)
- 今の割り当ては `Get-PSReadLineKeyHandler | Where-Object Function -like 'DotfilesAbbr*'` で見られる
- Windows PowerShell 5.1 (PSReadLine 2.0.0) でも同じに動く (`&&`・`||` は 5.1 に無い)

fish の abbr との違い:

- 端末から貼り付けた文字でも広がる。端末の貼り付け (Windows Terminal の Ctrl+V・右クリックなど) は文字を 1 字ずつキーとして
  PSReadLine に送るので、貼り付けた行の中の略語も広がる (fish は bracketed paste の間は広げない)。PSReadLine の `Paste` (端末が
  Ctrl+V をそのまま PSReadLine に渡したとき。Vi モードの Shift+Insert は `Paste` ではない) は、まとめて入れるので広がらない
- `>` と `<` では広げない。PowerShell では `>` が前の語にくっつき (`Write-Output x> $null` は `x>` を出す)、広げると最後の語が
  変わる。`<` は PowerShell では使えない
- 広げずに空白を入れるキーは、fish の Ctrl+Space に Shift+Space を足した 2 つ。IME の切り替えに Ctrl+Space を割り当てた PC では、
  Ctrl+Space を IME が先に取って PowerShell に届かない (広げないキーが使えないだけで、害は無い) ので、Shift+Space を使う
  - Ctrl+Space は `Ctrl+Spacebar` と `Ctrl+@` の両方に割り当てている。herdr・hc の端末や WSL から開いた PowerShell のように、
    端末が Ctrl+Space を NUL の字で送ると PSReadLine には `Ctrl+@` として届く (Windows Terminal のように Windows のキーの形で送る
    端末では `Ctrl+Spacebar`)
  - Shift+Space は `Shift+Spacebar` に割り当てている。Windows Terminal などの Windows のキーの形で送る端末では Shift 付きの Space として
    届き、広げずに空白が入る。herdr・hc の端末は Shift+Space をただの空白の字で送るので、PSReadLine には Shift の無い Space として届き、
    Space と同じに広がる。herdr-app の中では Ctrl+Space を使う (IME が Ctrl+Space を取る PC の herdr-app では、広げずに空白を入れる
    キーが無い)

気をつけること:

- PSReadLine の Ctrl+Space の補完 (Vi モードの既定は候補を並べる `PossibleCompletions`。Windows モードの既定は補完メニューの `MenuComplete`) は
  使えなくなる (Tab の補完はそのまま)。Shift+Space には PSReadLine の既定の割り当てが無い (PSReadLine 2.4.5 で確かめた) ので、使えなくなるものは無い
- 割り当てが消える場合がある
  - `$PROFILE` で、`dotfiles.ps1` を読む行より後に `Set-PSReadLineOption -EditMode …` を打つと、割り当てが既定に戻る
    ([Windows モードに戻す](#windows-モードに戻す))
  - starship の `Enable-TransientPrompt` は Enter の割り当てを上書きする (Enter では広がらなくなる。Space などでは広がる)。
    今の `$PROFILE` では使っていない

### Vi モード

`dotfiles.ps1` は、入力行の編集を Vi の流儀にする (PSReadLine の EditMode を `Vi` にする。Windows の PowerShell の既定は `Windows`)。
`$PROFILE` で読んだ対話の PowerShell で効く。入力行は挿入モードで始まる。Esc でコマンドモード (Vim のノーマルモード) に入り、`h`・`l`・`w`・
`b`・`0`・`$` で動き、`x`・`dw`・`D` で消し、`i`・`a`・`I`・`A` などで挿入モードに戻る。コマンドモードの割り当ては PSReadLine の Vi の
既定のまま。挿入モードには、[略語を広げる](#略語を広げる-fish-の-abbr-に似せる)キーと、下の bash に似たキーを割り当てる。
`dotfiles.ps1` が割り当てるキーは、Windows PowerShell 5.1 (PSReadLine 2.0.0) でも同じに動く (Ctrl+u の関数の名前だけが違う。Vi モードの既定の
割り当ての違いは下の「Windows モードから替わるキー」)。

EditMode を替えると、PSReadLine はそのモードの既定の割り当てに戻す (同じモードを選び直しても戻す)。`$PROFILE` で `dotfiles.ps1` を読む行より
前に置いたキーの割り当て (`Set-PSReadLineKeyHandler`。PSFzf など) は消えるので、`dotfiles.ps1` を読む行より後に置く。

#### bash に似たキー

bash (readline) でよく使う行の中の移動と消し方を、挿入モードで bash と同じ動きにする。PSReadLine の Emacs モードと同じ関数に割り当てる。

| キー | PSReadLine の関数 | bash (readline) | Vi の挿入モードの既定 |
| --- | --- | --- | --- |
| Alt+f | `ForwardWord` (語の終わりへ) | `forward-word` | 無い |
| Alt+b | `BackwardWord` (語の頭へ) | `backward-word` | 無い |
| Ctrl+w | `UnixWordRubout` (前の空白まで消す) | `unix-word-rubout` | 無い |
| Alt+d | `KillWord` (語の終わりまで消す) | `kill-word` | 無い |
| Ctrl+a | `BeginningOfLine` (行の頭へ) | `beginning-of-line` | 無い |
| Ctrl+e | `EndOfLine` (行の終わりへ) | `end-of-line` | 無い |
| Ctrl+k | `KillLine` (カーソルから入力の終わりまで消す) | `kill-line` | 無い |
| Ctrl+u | `BackwardKillInput` (入力の頭からカーソルまで消す。PSReadLine 2.2.0 より前 (5.1 の 2.0.0) は同じ動きの `BackwardKillLine`) | `unix-line-discard` | `BackwardDeleteInput` (2.0.0 は `BackwardDeleteLine`。同じ所を消すが、消した字を Vi のレジスタに入れる) |

- `cd foo/bar baz` のような行では、止まる所は bash と同じ。行末から Alt+b で `baz` の頭、もう一度で `bar` の頭 (`/` で止まる)。
  Ctrl+w は空白だけを区切りにし、`cd foo/bar` の行末で押すと `foo/bar` を丸ごと消す
- 複数行の入力では、Ctrl+a・Ctrl+e はカーソルのある行の頭・終わりへ動き、もう一度押すと入力の頭・終わりへ動く。Ctrl+k・Ctrl+u は
  入力の終わり・頭まで消す (ほかの行も消える)
- Ctrl+k は、herdr-app・旧 herdr・tmux・zellij の中ではそれぞれの prefix に取られる。Ctrl+k を 2 回押すと PowerShell に届く
  (行の終わりまで消す。herdr-app は [herdr-app のキー](#herdr-app-のキー)の prefix → `Ctrl+K`)
- 消した字 (Ctrl+w・Alt+d・Ctrl+k・Ctrl+u) は、bash と同じく PSReadLine の kill ring に入る (続けて消すとつながる。クリップボードとは別)。
  ただし bash と違い、Vi モードには kill ring から貼るキー (bash の Ctrl+y の `yank`。PSReadLine の `Yank`) が無く、貼り戻せない
  (Ctrl+y は Vi の既定の `Redo` のまま)。コマンドモードの `p`・`P` が貼るのは Vi のレジスタ (コマンドモードの `x`・`dw`・`yw` などが
  入れた字) で、この 4 つで消した字ではない。消しすぎたら、挿入モードの Ctrl+z (`Undo`) かコマンドモードの `u` で戻す
- herdr-app の中の PowerShell では、Ctrl+←・Ctrl+→・Ctrl+Backspace にも Alt+b・Alt+f・Ctrl+w の割り当てが効く。herdr-app は既定の
  keys.json の `terminal` の節で Ctrl+← を `ESC b`、Ctrl+→ を `ESC f`、Ctrl+Backspace を `^W` として送り (readline では Alt+b・Alt+f・
  Ctrl+w に当たるバイト)、PowerShell にはそれが Alt+b・Alt+f・Ctrl+w として届く (`ESC` と字が一緒に届くので、Esc (コマンドモードに入る)
  にはならない)。この 3 つは herdr-app の既定のキーで、dotfiles の [`herdr-app/keys.json`](#herdr-app-のキー) は持っていない
  - Ctrl+→ は語の終わりへ移る。Windows のキーの形で送る端末 (Windows Terminal など) の Ctrl+←・Ctrl+→ は Vi の挿入モードの既定の
    `BackwardWord`・`NextWord` (次の語の頭へ) で、Ctrl+Backspace は `BackwardKillWord` (語の区切りの記号でも止まる)
- 語の区切りは空白と、PSReadLine の `WordDelimiters` の記号 (`/`・`-`・`.`・`;` など。字は `(Get-PSReadLineOption).WordDelimiters` で
  見られる。5.1 の PSReadLine 2.0.0 の既定には `!`・`?` が無い) で、英数字だけを語にする bash と違う。`_`・`$` などは語の中に入る
  (`echo $foo_bar` の行末から Alt+b で `$foo_bar` の頭へ。bash は `bar` の頭へ)。`WordDelimiters` はほかのキー (Ctrl+←→・
  Ctrl+Backspace・コマンドモードの `w`・`b` など) にも効くので替えない
- 今の割り当ては次で見られる (Windows PowerShell 5.1 の PSReadLine 2.0.0 の `Get-PSReadLineKeyHandler` には `-Chord` が無いので、
  `-Bound` から選ぶ。`-CIn` は大文字小文字を区別する。`Alt+F` は Alt+Shift+f で別のキー)。コマンドモードの割り当ては、キーが
  `<Ctrl+w>` のように `<>` で囲まれて出る

  ```powershell
  Get-PSReadLineKeyHandler -Bound | Where-Object Key -CIn 'Alt+f', 'Alt+b', 'Ctrl+w', 'Alt+d', 'Ctrl+a', 'Ctrl+e', 'Ctrl+k', 'Ctrl+u'
  ```

#### Windows モードから替わるキー

Vi モードにすると、挿入モードの次のキーが Windows モード (今までの既定) から替わる (主なもの。`dotfiles.ps1` が割り当てるキーは、上の表と
[略語を広げる](#略語を広げる-fish-の-abbr-に似せる)のとおり)。

| キー | Windows モード | Vi モード (挿入モード) |
| --- | --- | --- |
| Esc | `RevertLine` (入力行を消す) | `ViCommandMode` (コマンドモードに入る)。入力行を捨てるのは Ctrl+c (`CancelLine`) |
| Ctrl+a | `SelectAll` (全部を選ぶ) | `BeginningOfLine` (上の表) |
| Shift+←・Shift+→・Shift+Ctrl+←・Shift+Ctrl+→・Shift+Home・Shift+End | 字や語を選ぶ | 無い (挿入モードには字を選ぶ操作が無い) |
| Ctrl+c | `CopyOrCancelLine` (選んでいれば写し、いなければ入力行を捨てる) | `CancelLine` (入力行を捨てる) |
| Ctrl+x・Ctrl+Shift+c | `Cut`・`Copy` | 無い |
| Ctrl+v | `Paste` | `Paste` (同じ)。Shift+Insert の `Paste` は無い |
| Ctrl+d | 無い | `ViAcceptLineOrExit` (空の行では PowerShell を抜け、字があれば実行する) |
| Alt+. | `YankLastArg` (前の行の最後の引数を入れる) | 無い |
| Ctrl+h | `BackwardDeleteChar` | 無い |
| F8・Shift+F8 | `HistorySearchBackward`・`HistorySearchForward` (打った字で始まる履歴を探す) | 無い (↑・↓ の履歴はそのまま) |
| Ctrl+Enter・Ctrl+Shift+Enter | `InsertLineAbove`・`InsertLineBelow` | 無い |
| Tab・Shift+Tab | `TabCompleteNext`・`TabCompletePrevious` | `ViTabCompleteNext`・`ViTabCompletePrevious` (同じく候補を順に入れる) |
| Ctrl+Space | `MenuComplete` | `PossibleCompletions`。どちらも `dotfiles.ps1` の略語の割り当て (広げずに空白を入れる) が上書きする |
| Ctrl+r・Ctrl+s | `ReverseSearchHistory`・`ForwardSearchHistory` | 同じ。5.1 の PSReadLine 2.0.0 では別の関数 (`ViSearchHistoryBackward`・`SearchForward`) |

Ctrl+z (`Undo`)・Ctrl+y (`Redo`)・↑・↓ (履歴)・Home・End・Delete・Backspace は Windows モードと同じ。全部の割り当ては
`Get-PSReadLineKeyHandler` で見られる。

#### モードの印 (カーソルの形)

今のモードをカーソルの形で示す。挿入モードは縦棒、コマンドモードはブロック (どちらも点滅しない)。PSReadLine がモードを替えるたびに
`dotfiles.ps1` の handler (`Set-PSReadLineOption -ViModeIndicator Script -ViModeChangeHandler`) が呼ばれ、カーソルの形を替える列
(DECSCUSR。縦棒は `ESC [ 6 SP q`、ブロックは `ESC [ 2 SP q`。`Set-DotfilesViModeCursor` が書く) を端末へ書き、プロンプトを描き直す
(`InvokePrompt`)。`dotfiles.ps1` を読んだときにも縦棒にする (最初のプロンプトは挿入モードだが、PSReadLine はモードが替わるまで handler を
呼ばない)。

- 形が替わるのは、DECSCUSR を受ける端末。herdr-app・Windows Terminal と PowerShell の間の ConPTY は列を端末へ渡す (WSL から起こした
  PowerShell 7 と 5.1 の ConPTY で確かめた)
- starship のプロンプトは、描き直したときのモードで記号を替える (dotfiles の `starship.toml` は記号 (`character`) を替えていないので、starship の
  既定のまま挿入モードで `❯`、コマンドモードで `❮`)。
  形が替わらない端末でも、プロンプトの記号でモードが分かる。starship の init (`$PROFILE` で `dotfiles.ps1` より先に読む。runner の `starship-init` がその順に足す) もモードが替わるたびに
  描き直す handler を置くが、`dotfiles.ps1` はそれを包まずに置き換えて自分で描き直す (`. $PROFILE` で読み直しても、描き直しは 1 回)
- PSReadLine の `-ViModeIndicator Cursor` を使わないのは、5.1 の PSReadLine 2.0.0 の `Cursor` が Windows のコンソールの API でカーソルの
  大きさを替えるだけで列を書かず、ConPTY を通る端末では形が替わらないため (2.4.5 の `Cursor` は列も書くが、挿入モードは点滅する下線になる)
- 形を替えるのは handler と読んだときだけなので、プログラム (Vim など) がカーソルの形を替えて終わると、次のプロンプトはその形のままのことがある。
  Esc と `i` でモードを行き来すると直る。逆に、コマンドを流している間と、PowerShell を抜けた後も、カーソルは最後に書いた形 (多くは縦棒) の
  まま (端末の既定の形には戻さない)。戻すなら `[Console]::Write("$([char]27)[0 q")`
- プロンプトの色で示す形にも替えられる: `dotfiles.ps1` の handler の 2 つの命令を `Set-PSReadLineOption -ViModeIndicator Prompt` の 1 行に替える
  (コマンドモードの間、プロンプトを背景の色を替えて描き直す。starship の記号も替わる)。`dotfiles.Tests.ps1` のモードの印の試験
  (ViModeIndicator・handler・読んだときの縦棒) も直す。手元で試すだけなら、`$PROFILE` で `dotfiles.ps1` を読む行より後に同じ 1 行を置く
  (EditMode ではないので、割り当ては残る)

#### Windows モードに戻す

```powershell
# $PROFILE で、dotfiles.ps1 を読む行より後に置く
Set-PSReadLineOption -EditMode Windows
[Console]::Write("$([char]27)[0 q")   # dotfiles.ps1 が読んだときに縦棒にしたカーソルを、端末の既定の形に戻す
```

- EditMode を替えると、PSReadLine はそのモードの既定の割り当てに戻す。`dotfiles.ps1` の割り当て (略語を広げるキー・bash に似たキー) も
  無くなり、Windows モードの既定のキーになる (Ctrl+w は `BackwardKillWord`、Alt+f・Alt+b は割り当てが無いなど)。モードの印の handler は
  Vi モードでしか呼ばれない
- `dotfiles.ps1` を読む行より前に EditMode を替えても、`dotfiles.ps1` が Vi に替える
- 開いている PowerShell で試すだけなら、上の 2 行をそのまま打つ (`. $PROFILE` で Vi モードに戻る)

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
- PSReadLine の命令 (`Set-PSReadLineKeyHandler` など) は `if (Get-Module -Name PSReadLine)` の中に書く。`dotfiles.ps1` は
  PSReadLine を読み込まない PowerShell (script・`dotfiles.Tests.ps1`・CI) でも読まれ、そこで打つと PSReadLine を読み込んでしまう
- キーの割り当ては `Set-PSReadLineOption -EditMode Vi` より後に書く (EditMode を替えると、PSReadLine はそのモードの既定の割り当てに戻す)。
  EditMode が Vi の間は、`-ViMode` を付けない `Set-PSReadLineKeyHandler` が挿入モードに割り当てる (コマンドモードに割り当てるなら
  `-ViMode Command`)
- 5.1 の PSReadLine 2.0.0 に無い関数・引数を使うなら、有るかを見て分ける (Ctrl+u の `BackwardKillInput` のように。`-Function` に無い名前を
  渡すと落ちる)。`dotfiles.Tests.ps1` は 5.1 でも流す (Windows で `powershell.exe -NoProfile -ExecutionPolicy Bypass -File …\dotfiles.Tests.ps1`)
- `dotfiles` 関数の runner の流し方 (launcher を呼ぶ行と、launcher の無い clone の `cargo run …` の行) を直すときは、`Invoke-DotfilesSelfUpdate.ps1` の
  末尾の runner の行も同じに直す (`dotfiles --self-update` は進めた後に、その行で runner を流す。`Invoke-DotfilesSelfUpdate.Tests.ps1` が、同じものを
  同じ引数で打つかを突き合わせる)。launcher (`Invoke-DotfilesRunner.ps1`) も 5.1 で動かし、引数は `$args` で受ける (param ブロックを置くと、runner の
  `-h` などを PowerShell が自分の引数として読む。`Invoke-DotfilesRunner.Tests.ps1` が見る)。`Invoke-DotfilesSelfUpdate.ps1` も
  5.1 で動かす (同じ Tests が、7 にしか無い書き方を見る)
- 関数の引数をほかの script に渡すときは、配列を変数に入れてから `@変数` で広げる (`& $script @(…)` は配列を 1 つの引数で渡し、script の側で空白で
  つながった 1 つの字になる)

### Windows PowerShell 5.1 でも使うなら

5.1 は実行ポリシーの既定が Restricted で、`$PROFILE` を読まない。使うなら 5.1 で次の 2 つを打つ
(5.1 の実行ポリシーと `$PROFILE` は PowerShell 7 とは別):

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
Add-Content -Path $PROFILE -Value 'if (Test-Path "$HOME\.config\powershell\dotfiles.ps1") { . "$HOME\.config\powershell\dotfiles.ps1" }'
```

## starship

Windows の starship (プロンプト) を、Linux と同じ形に揃える (dotfiles-private の `docs/superpowers/specs/2026-11-25-win-starship-install-design.md`)。
入れるものは 3 つで、どれも Linux の home-manager (`nix/home/modules/starship.nix`) が入れるものに当たる:

| もの | Windows で入れる手順 | Linux では |
| --- | --- | --- |
| starship 本体 (`starship.exe`) | runner の `starship` (`starship/Install-Starship.ps1`。order 97。[後述](#starship-を入れる-winget)) | `programs.starship.enable` が nixpkgs の starship を入れる |
| init の 1 行 | runner の `starship-init` (`$PROFILE`。order 94。[後述](#profile-の-init-の-1-行)) | home-manager が fish・bash の init を書く |
| 設定 `starship.toml` | manifest の `base = "nix"` の表 (手順 `files`。[後述](#starshiptoml)) | home-manager が同じ `nix/files/starship.toml` を `~/.config/starship.toml` に置く |

本体と init の 1 行は Windows にしか無い手順 (WSL の setup には無い) で、minimum の基本の道具 (Linux もどのグループでも入れる) なので道具の switch を
持たない (どのホストでもいつも on。受け持ちが WSL のホストでも `dotfiles apply` が入れる)。

### starship を入れる (winget)

`starship/Install-Starship.ps1` は starship を winget で入れ、版を `-Version` の既定値の 1 か所で固定する。版は Linux の home-manager が入れる starship
(`nix/flake.lock` の nixpkgs) と同じにする。[winget の portable の道具](#winget-の-portable-の道具) の共通の枠で揃え、形は [ghq・fzf](#ghqfzf) の fzf と同じ
(zip の中の portable。管理者は要らない。常駐も UAC も無いので、版のずれも揃える)。

| winget の ID | 固定した版 (`-Version` の既定値) | 置き場所 (`%LOCALAPPDATA%\Microsoft\WinGet\Packages\` の下) |
| --- | --- | --- |
| `Starship.Starship` | `1.27.0` | `Starship.Starship_Microsoft.Winget.Source_8wekyb3d8bbwe\starship.exe` |

| 打つもの | すること |
| --- | --- |
| `Install-Starship -Check` (PowerShell) | 差を出すだけ。揃っていれば終了コード 0、差があれば 1、入っていなければ 3 (MSI の starship が入っている・昇格した PowerShell で winget を打てなければ 1) |
| `Install-Starship` (PowerShell) | 揃える (入れる・入れ替える (上げる・下げる)・pin を足す) |
| `dotfiles apply --steps starship` (PowerShell) | runner の手順で揃える (入っていなければ入れ、版か pin がずれていれば揃える。PATH のずれと MSI の starship は知らせるだけ) |
| `nix/scripts/check-winget-version.sh starship` (WSL・CI) | 固定した版を winget の版の一覧と比べる。GitHub Actions の `winget-versions` が週 1 回流し、新しい版が winget に載って 30 日たつと落ちて知らせる ([後述](#starship-の新しい版が出たとき)) |

揃えるときにすることは [ntn](#ntn) と同じ (取得を確かめてから外して入れ、pin を足し、読み直す)。違うところ:

- 入れる・取得を確かめるときは `--installer-type portable` で portable を名指しする。winget の `Starship.Starship` は portable の zip と
  machine スコープの MSI (`%ProgramFiles%\starship\bin`。UAC が要る) を並べ、名指ししないと winget は MSI を選ぶ
- MSI の starship (手で `winget install Starship.Starship` を打つと入る。x86 の MSI は `%ProgramFiles(x86)%\starship\bin`) が入っていると、portable と
  二重になり、winget の install と pin がどちらを指すかが決まらない (PATH ではマシンの MSI が先に引かれる)。そのため `Install-Starship` は何も入れずに
  止まり、`-Check` は 1 を返して外し方を出す (runner は知らせるだけ)。PowerShell で `winget uninstall --id Starship.Starship --exact --scope machine` を
  打って外し (UAC の確認が出る)、続けて `Install-Starship` か `dotfiles apply --steps starship` を打つ。外してから入れるまでの間に開いた PowerShell では、
  `Get-Command` で囲んでいない手書きの init の行がエラーを出すので、間を空けずに打つ
- 入れた後は、新しい PowerShell を開くと starship のプロンプトになる (winget がユーザーの PATH に足すのは、これから開く PowerShell の分。herdr-app の
  中の端末は herdr-app が起きたときの PATH を受け継ぐので、herdr-app を上げ直してから)
- 入れ替えるときに置き場所の starship.exe が動いている (描き終わらないプロンプトなど) と、置き換えられないので何も変えずに止まり、PID と
  コマンドラインを出す。終わらせてから打ち直す
- PATH で別の starship (scoop・`cargo install` のものなど) が先に引かれると、`-Check` の「PATH の starship」が ⚠ になる。揃える手順では直らないので、
  ※ の行の手順でその置き場所を外す
- 消すなら PowerShell で `winget pin remove --id Starship.Starship --exact` の後に `winget uninstall --id Starship.Starship --exact` を打つ (runner の手順は
  いつも on なので、次の `dotfiles apply` で入れ直す)

### $PROFILE の init の 1 行

runner の `starship-init` が、PowerShell 7 の `$PROFILE` (pwsh に聞く `CurrentUserCurrentHost`。[PowerShell](#powershell) と同じ) に次の 1 行を足す:

```powershell
if (Get-Command starship -CommandType Application -ErrorAction SilentlyContinue) { Invoke-Expression (&starship init powershell) }
```

- 置くのは `dotfiles.ps1` を読む行より前。starship の init は先に置かれた Vi モードの handler (`ViModeChangeHandler`) を包み、`dotfiles.ps1` は init の
  後に読まれる前提で、その handler を包まずに置き換える ([モードの印](#モードの印-カーソルの形))。逆の順だと、モードが替わるたびにプロンプトを 2 回描き直す
  - `dotfiles.ps1` を読む行があれば、そのすぐ前に差し込む。書き直す前の中身は `%LOCALAPPDATA%\dotfiles\state\starship-init\backup\` へ写す (10 回分)。
    書き直しは同じファイルへの上書き (OneDrive が同期するファイルを置き換えない)
  - 無ければ末尾に足す。新しい PC では、続く `powershell-profile` (order 95) がその後ろに `dotfiles.ps1` を読む行を足す
- `Get-Command` で囲むのは、starship の無い PC (入れる前・OneDrive の同期で `$PROFILE` だけが届いた PC) でも起動のたびにエラーを出さないため
  (`dotfiles.ps1` の行の `Test-Path` と同じ)。`-CommandType Application` は PATH の exe だけを引き、モジュールを探さない
- starship の init の行 (`starship` と `init powershell` を含む行。大文字小文字を問わず、頭に `#` を付けた行も) が既にあれば、足さずに記録だけする
  (手で書いた `Invoke-Expression (&starship init powershell)` と二重に init しない)。その行が `dotfiles.ps1` を読む行より後ろにあれば (どちらも頭に `#` の
  無い行のとき)、runner は動かさずに ⚠ で前へ移すよう知らせる
- 足した 1 行 (記録した手書きの行も) を消すと、次からは足し直さない (Windows 側で外したものとして扱う)。戻すなら `dotfiles apply --steps starship-init --force`。
  手書きの行を、`Get-Command` で囲んだこの 1 行に替えるときも、手書きの行を消してから同じく `--force` で流す
- 記録は PC ごと (`%LOCALAPPDATA%\dotfiles\state\starship-init.added.json`) なので、`$PROFILE` を OneDrive で同期している PC では、消した行を記録の
  無い別の PC の apply が足し直し、同期で戻ってくることがある。止めたいときは消さずに頭に `#` を付ける (`#` を付けた行は、どの PC でも足さない印になる)
- runner が見るのは `$PROFILE` (CurrentUserCurrentHost) だけ。starship の init を別のファイル (`$PROFILE.CurrentUserAllHosts` の `profile.ps1`・`$PROFILE` から
  読むファイル) に書いている PC では二重になるので、`$PROFILE` に頭に `#` を付けた `# starship init powershell` の 1 行を置く (足さなくなる)
- 差し込む所の前の行が行末の `` ` `` (次の行へ続く印) で終わるときと、`$PROFILE` が UTF-16 のときは書かずに、同じ 1 行を手で足す道を出す (UTF-16 でも、
  init の行があるかは読む)。pwsh が無いときも同じ

### starship.toml

starship の設定 `starship.toml` を、Linux と同じファイル (`nix/files/starship.toml`) から `%USERPROFILE%\.config\starship.toml` に配る。starship は環境変数
`STARSHIP_CONFIG` が無ければここを読む。配るのは manifest の `base = "nix"` の表 ([ファイルを足す](#ファイルを足す)) で、受け持ちを runner に切り替えた
ホストは `dotfiles apply` の手順 `files`、ほかは WSL の `~/dotfiles/setup --update` ([配る](#配る))。初めて配るときは、`dotfiles apply --dry-run` に
`[dry-run] コピー: …\.config\starship.toml`、`dotfiles check` に `無い (apply でコピーする): …\.config\starship.toml` と出る。

- starship はプロンプトのたびに設定を読むので、置いたら次のプロンプトから効く (読み直しは要らない)
- 置き先に手で書いた `starship.toml` があると、初めて配るときに「置いた記録が無く」の衝突になる ([衝突したら](#衝突したら))。Windows の中身を
  残すなら `nix/files/starship.toml` に取り込む (Linux の見た目も変わる)。`STARSHIP_CONFIG` で別のファイルを指している PC では、置いたファイルは読まれない
- 同じファイルを Linux (bash・fish) と Windows (PowerShell) の starship が読む。sh などの shell で判定・出力する custom module は `os = 'unix'` で
  Windows では出さない。Windows の starship は `shell` を PATH から引くので、sh を PATH に足した PC (Git for Windows の `usr\bin` など) ではプロンプトの
  たびに sh を起こし、bash は WSL の `bash.exe` (WindowsApps) に当たって WSL を起こす。`os = 'unix'` なら Windows では shell を探さずに飛ばし、Linux と
  macOS ではこれまでどおり判定する。runner の試験 (`runner/src/steps/files.rs` の `real_repo_starship_toml`) が、Unix の shell の custom module に
  `os` があるかを確かめる
- 今の custom module は `custom.pjp_ssh_client` (ssh で入った shell と herdr の pane で、`PJP_SSH_CLIENT` が届いていないことを出す。Linux の herdr と
  ssh-agent の仕組み) だけで、Windows では出ない
- ほかの module は Windows でもそのまま使える (`sudo` は starship の既定の `allow_windows = false` で、Windows では出ない)。罫線 (`┌`・`│`・`└`) と
  絵文字 (`🕙`・`🌏`・`⚠`) は Linux と同じ字で、字体に無い字が □ で出るなら端末の字体を見る

### starship の新しい版が出たとき

固定した版より新しい版が winget に載って 30 日たつと、GitHub Actions の `winget-versions` の `Windows の starship` の job が落ちて知らせる。出た日は
winget-pkgs に載った日 (GitHub にも release を出すが、winget に載らない版 (1.10.0・1.20.0 など) があるので、GitHub とは比べない)。固定した版より
新しい版の知らせ (runner の `pin-updates`。WSL の setup では、Windows の ghq に dotfiles の clone があるマシンだけ) にも出る。猶予・落ちる場合・
見送りの一覧は [winget の新しい版を確かめる](#winget-の新しい版を確かめる)。

上げるとき:

1. 上げる版は、Linux の home-manager が入れる starship と同じにする (`nix/flake.lock` を上げて nixpkgs の starship が上がったら、Windows も同じ版に
   上げる。今の nixpkgs の版は `nix eval --raw --inputs-from ./nix nixpkgs#starship.version`)。その版が winget に載っていない・猶予の中なら、載るまで待つ
2. release notes で、PowerShell の init (`src/init/starship.ps1`。先に置かれた `ViModeChangeHandler` を包む形。`dotfiles.ps1` の Vi モードが前提にする) と、
   設定の読み方 (`nix/files/starship.toml` が警告なしで読めるか) に触る変更が無いかを見る。winget の manifest にまだ portable の zip があるか
   (`winget show --id Starship.Starship --version <版> --installer-type portable`) も見る
3. `starship/Install-Starship.ps1` の `-Version` の既定値と、上の表の版を新しい版にし、`Install-Starship.Tests.ps1` を流して PR を出す (`winget-versions` が、
   書いた版が winget にあるかを確かめる)
4. merge したら、Windows で `dotfiles --self-update apply` (clone を進めてから流す。`--steps starship` で絞れる) を流す (runner が揃える)
5. `Install-Starship -Check` が「揃っている」になり、`starship --version` が新しい版を出すことを確かめる

見送るとき: `starship/skipped-versions.txt` に「版 理由」を 1 行足して commit する。版を戻すときは `-Version` を前の版にすれば、runner が下げる。

### Install-Starship.ps1 を書くときの注意

- `dotfiles.ps1` と同じく **BOM 付きの UTF-8** で保存する
- 入口は道具の表 (`Get-StarshipTool`) だけを持ち、流れは共通の枠 ([WingetPortable.ps1 を書くときの注意](#wingetportableps1-を書くときの注意))
- 表の値 (版の拾い方・exe の置き場所・MSI) と、表を渡した流れは `starship/Install-Starship.Tests.ps1` で確かめる (Linux の pwsh):

  ```sh
  nix shell nixpkgs#powershell -c pwsh -NoProfile -File win/starship/Install-Starship.Tests.ps1
  ```

- runner の `runner/src/steps/ps1.rs` は、終了コードと、状態の表の見出し (`starship (winget の Starship.Starship`) と、締めの行の文言
  (`→ Install-Starship で入れる`・`→ Install-Starship で揃える`・`→ ※ の手順で直す`・`MSI の starship (machine スコープ) が入っている`・
  `昇格した PowerShell では winget が starship を入れない`) で分かれる。字は共通の枠が組む。変えるときは向こうも直す (WSL の wrapper は無いので、runner の
  試験が入口と枠の字を突き合わせる)
- winget やプロセスに触る本物の部分は、実機で `-Check` と本番を打って確かめる

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
- herdr-app (herdr の desktop app) でも同じ手で操れるよう、キーを寄せている ([herdr-app のキー](#herdr-app-のキー))。
  ここの `[keys]` を変えたら、herdr-app の `herdr-app/keys.json` と prefix の mod (`herdr-app/mods/pjp-prefix/`) もそろえるかを決める
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
| `Install-Herdr -Check` (PowerShell) | 差を出すだけ。揃っていれば終了コード 0、差があれば 1 (`Herdr.Herdr.Preview` が残っている・昇格した PowerShell で winget を打てないときも)、入っていなければ 3 |
| `Install-Herdr` (PowerShell) | 揃える (入れる・入れ替える・pin を足す)。`Herdr.Herdr.Preview` は外さない |
| `nix/scripts/bootstrap-windows-herdr.sh` (WSL) | `setup --update` でも毎回走る。入っていなければ入れ、差があれば ⚠ で囲んで知らせる (入れ替えはしない)。`Herdr.Herdr.Preview` が残っていれば、外す手順を ⚠ で囲んで知らせる |
| `nix/scripts/bootstrap-windows-herdr.sh --apply` (WSL) | WSL から揃える |
| `nix/scripts/check-winget-version.sh herdr` (WSL・CI) | 固定した版を winget の版の一覧と比べる。GitHub Actions の `winget-versions` が週 1 回流し、新しい安定版が GitHub に出て 30 日たつと落ちて知らせる ([後述](#herdr-の新しい版が出たとき)) |

揃えるときにすること ([winget の portable の道具](#winget-の-portable-の道具) の共通の枠。昇格した PowerShell では入れない):

1. 入っている版 (winget の置き場所の `herdr.exe --version`) と固定した版を比べる。違えば、先に
   `winget download` で固定した版の取得とハッシュを確かめ (落ちたら何も変えずに止まる)、
   `winget uninstall` してから `winget install --version` で入れる。portable の置き場所は版によらず
   同じで、`%APPDATA%\herdr` の設定やセッションは消えない
2. 入れ替えの前に pin を外し、入れた後に `winget pin add` で `winget upgrade --all` から外す
3. 読み直して、版・pin・PATH で引かれる herdr を確かめる。PATH で引かれる herdr は、置き場所のもの (winget が置き場所をユーザーの PATH に足した形。
   `Herdr.Herdr` の manifest は `ArchiveBinariesDependOnPath: true` で、winget は開発者モードでも `WinGet\Links` に symlink を作らずにこの形にする) と、
   `%LOCALAPPDATA%\Microsoft\WinGet\Links\herdr.exe` (前に symlink ができた PC・手で置いたもの。指す先が `Herdr.Herdr` の置き場所のとき) のどちらも
   winget のものとして読む

- 入れ替えるときに herdr が動いていると (server・`herdr --remote`・conpty の OpenConsole.exe)、
  herdr.exe を置き換えられないので、何も変えずに止まる。herdr の外の PowerShell
  (Windows Terminal など) で `hsvstop` を打ち、`--remote` の窓も閉じてから打ち直す。
  スクリプトが server を止めないのは、herdr の pane の中で打つと自分ごと消えるため
- 前の `Herdr.Herdr.Preview` が残っている間も、入れ替えずに止まる (下の「[Herdr.Herdr.Preview から移る](#herdrherdrpreview-から移る)」)
- `herdr update` は打たない。herdr 自身の installer が
  `%USERPROFILE%\.herdr\packages\standalone\releases\<版>-<target>` に別に入れ、そのディレクトリを
  ユーザーの PATH の先頭に足すので、winget の herdr が引かれなくなる。新しい版の通知は
  `herdr/config.toml` の `[update] version_check = false` で止めてある。打ってしまったら
  (`-Check` の「PATH の herdr」が ⚠ になり、外すディレクトリが ※ の行に出る。締めの行は「→ ※ の手順で直す」で、setup も runner も
  揃えずに知らせる)、そのディレクトリをユーザーの PATH から外し、`%USERPROFILE%\.herdr\packages` と `%LOCALAPPDATA%\Programs\Herdr` を消す。
  `Install-Herdr` は PATH を直さない
- 入れ替えの途中で `winget install` が落ちると、herdr が入っていない状態で止まることがある
  (取得は先に確かめてあるので稀)。そのときは `Install-Herdr` を打ち直す (`dotfiles apply`・`setup --update` でも入る)
- 版を変える・新しい版を見送るときは、次の「herdr の新しい版が出たとき」の手順で。新しい安定版が出たかは、
  `winget-versions` の notice か、`-Check` の ※ の行で分かる
- 新しいマシンでは `setup --update` が入れる。依存の VCRedist が無いマシンでは、winget が入れるときに
  Windows に UAC が出る。`Install-Herdr` は `--installer-type` を名指ししない (manifest の依存 `Microsoft.VCRedist.2015+.x64` のインストーラーは burn
  しか無く、winget は `--installer-type` を依存の解決にも効かせるので、名指しすると VCRedist の無い PC で `0x8A150104` で落ちる)
- setup が入れて揃えるのは `dotfiles.wsl.windowsFiles.herdr.enable = true` のマシン (herdr-app と herdr-core も同じ値)。既定は設定
  グループで決まり、グループ all の win/ を配るマシンで true (minimum では使うホストが書く。[`nix/README.md` の「設定グループ」](../nix/README.md#設定グループ))。
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
- `WinGet\Links\herdr.exe` が Preview を指す symlink のままの PC (前に symlink ができた・手で置いた) では、`-Check` は symlink の
  指す先を読み、「PATH の herdr」に `<Links のパス> → <Preview の herdr.exe> (Herdr.Herdr.Preview のもの)` と出して、同じく「Preview を外せば直る」と
  添える (winget の portable のもの (`WinGet\Links` の symlink) とは読まない)
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
- 入口は道具の表 (`Get-HerdrTool`) と、前の `Herdr.Herdr.Preview` を見る custom の関数を持ち、流れは共通の枠
  ([WingetPortable.ps1 を書くときの注意](#wingetportableps1-を書くときの注意))
- 表の値・custom の関数 (Preview の置き場所・PATH の Preview の見分け・止める理由・表と締めの行に足す行) と、表を渡した流れは
  `herdr/Install-Herdr.Tests.ps1` で確かめる。Linux の pwsh で流すので Windows には触らない
  (このファイルは manifest に無いので配られない):

  ```sh
  nix shell nixpkgs#powershell -c pwsh -NoProfile -File win/herdr/Install-Herdr.Tests.ps1
  ```

- 締めの行の文言 (`→ Install-Herdr で入れる`・`→ Install-Herdr で揃える`・`→ ※ の手順で直す`・`Herdr.Herdr.Preview が残っている`・
  `昇格した PowerShell では winget が herdr を入れない`) は `bootstrap-windows-herdr.sh` と runner が読む。変えるときは向こうも直す
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

固定した版は `nix/pkgs/herdr-core/releases.json` (今は app 0.1.16・core 0.1.21) の 1 か所で決める。app の版と windows-x86_64 の sha256、
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
- 設定 (`~/.config/herdr-app`。テレメトリは既定で有効で、Settings → Privacy で変える) は dotfiles では配らない。自作の mod (`~/.config/herdr-app/mods/`
  の下) は runner の `herdr-app-mods` の手順が配り、`keys.json` には runner の `herdr-app-keys` の手順が dotfiles のキーだけを書き足す。claude-skills の
  mod `pjp-spaces` と、それを使う自分の layout `pjp-main` は runner の `herdr-app-pjp-spaces` の手順が置く
  ([herdr-app の mod](#herdr-app-の-mod)・[herdr-app のキー](#herdr-app-のキー)・[herdr-app の印 (pjp-spaces)](#herdr-app-の印-pjp-spaces))

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
3. app を上げるときは、既定のキーが増えた・変わったかも、上げる版までの app の CHANGELOG で見る。dotfiles がキーを書き足した keys.json には、
   herdr-app を上げても新しい既定のキーが足されない ([herdr-app のキー](#herdr-app-のキー))。app の CHANGELOG は、herdr-app の更新ノート
   (Settings → Updates の What's new) と同じ中身で、足すキーを「if you edited keys.json, add …」のように keys.json に触れて書く
   (setup の新しい版の知らせも、app に新しい版があればこの注意を添える)
   - Windows で効くキー (macOS だけの `cmd-` のキーと、Linux だけの項は除く) を、repo の `win/herdr-app/keys.json` の同じ section に足す。
     merge の後、Windows の runner の `herdr-app-keys` が各 PC の keys.json に書き足す (新しい PC は、herdr-app が新しい版の既定で keys.json を
     書くので、そのままでも入る。足すのは、keys.json を書き足し済みの PC のため)
   - 増えた・変わった既定のキーが、dotfiles のキー (`win/herdr-app/keys.json`) と同じ section の同じキーなら、keys.json には足さず (dotfiles の
     値のまま)、その既定の値を `win/herdr-app/keys.defaults.json` に書く (今ある行なら新しい既定の値に替える)。書かないと、新しい PC で runner が
     そのキーを衝突として ⚠ で残す。細かい section (`terminal` など) に dotfiles のキーと同じキーが増えたときは、端末に focus がある間は
     dotfiles のキーが効かなくなるので、PR の本文に書いて扱いを決める
   - 足さないと決めたキーと、Windows で効くキーが無かったことは、PR の本文に書く
4. `nix/pkgs/herdr-core/releases.json` の版と sha256 (app は windows-x86_64、core は linux-aarch64・linux-x86_64・windows-x86_64 の 3 つと
   generation) と、「[herdr-app を入れる](#herdr-app-を入れる)」の「今は」を新しい版にする。Windows と Linux は、この 1 つの PR で一緒に上がる。
   core は app の core_min 以上にする。core の generation が固定と違うと出たら、app を、その generation の core と話せる版と一緒に上げる
   (`update --from` は generation を見ないので、core だけを上げると app と話せない core が入る)。`Install-HerdrApp.Tests.ps1` と
   `nix build ./nix#checks.x86_64-linux.herdr-core-test` (Linux の build と `hc --version`) を流して PR を出す (CI の `version` の job が、書いた版の
   成果物と manifest が合うかを target ごとに確かめる)
5. merge したら、各マシンで `setup --update` を流す。Windows ではフィードが新しい版に書き換わり、`-IfMissing` が app と core を上げる (署名と
   sha256 を確かめてから。動いている app は置き場所の rename で入れ替わり、再起動で新しい版になる)。開いている app も、1 時間以内にフィードの版へ
   上がる。Linux のホストでは、home-manager の switch が新しい版の herdr-core を入れる (動いている core は、次に起動したときから新しい版)。
   machine としてつなぐホストは続けて上げる (版が混ざると、つなぐときに写し直しを聞かれる)。3 で keys.json にキーを足したなら、Windows で
   clone (`%USERPROFILE%\ghq\github.com\pollenjp\dotfiles`) を pull し、`dotfiles apply --steps herdr-app-keys` を流す (受け持ちが WSL のホストでも
   流す。[herdr-app のキー](#herdr-app-のキー))
6. `-Check` が「揃っている」になり、app が起動することを確かめる

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

固定した版に入れ替えるのは、道具の switch `windowsOpenssh` が on のホストだけ (Windows の runner はホストの値の `[tools] windowsOpenssh = true`、
WSL の setup は Nix の `wsl.windowsFiles.openssh.enable = true`)。グループ `all` では on、`minimum` では off。Windows には OpenSSH (Windows の機能。
`C:\Windows\System32\OpenSSH`) が初めから入っていて、WSL の `ssh` の wrapper (`ssh.exe` を PATH で引く) も runner の `git-config` が書く
`core.sshCommand` も、固定した版が無ければそれを使う。版を上げるのは minimum の役目にしない (入れるときに UAC の確認が出て、Windows Installer の
不調な PC では落ちる)。off のホストでは、runner の手順 `openssh`・WSL の `bootstrap-windows-openssh.sh` は流れず (↷)、`pin-updates` も OpenSSH の
新しい版を確かめない。`Install-OpenSSH.ps1` は off のホストにも配る (手で `Install-OpenSSH -Check` を打てる)。off に戻しても、入れた版は消さない
(外すなら `winget pin remove --id Microsoft.OpenSSH.Preview` の後に `winget uninstall --id Microsoft.OpenSSH.Preview`。sshd を入れたホストでは先に
[sshd を止める・外す](#sshd-を止める外す))。sshd ([sshd](#sshd)) は固定した版の MSI に Server を足すので、`windowsSshd` を on にするホストは
`windowsOpenssh` も on にする。

| 打つもの | すること |
| --- | --- |
| `Install-OpenSSH -Check` (PowerShell) | 差を出すだけ。管理者は要らない。揃っていれば終了コード 0、入っていなければ 3、ほかの差があれば 1 |
| `Install-OpenSSH -IfMissing` (PowerShell) | 入っていなければ固定した版を入れる (UAC が 1 回出る)。ssh-agent を止めて無効にし、pin も足す。入っていれば `-Check` と同じ。入れたあとは、1Password の鍵が見えなくても成功にする (新しい PC ではまだ 1Password を入れていない) |
| `Install-OpenSSH` (PowerShell) | 揃える。直すことがあるときだけ UAC が 1 回出る |
| `-NoOnePassword` を足す (PowerShell) | 1Password の SSH agent を使わないホスト向け。入れた・揃えた後に `ssh-add -l` で 1Password の鍵を見ず、1Password の案内も出さない (引数なしの「揃った」も鍵で決めない)。runner の手順 `openssh` は、ホストの値の道具の switch `onePassword` が off なら `-Check` にも `-IfMissing` にも付け、直し方のコマンドにも添える |
| `nix/scripts/bootstrap-windows-openssh.sh` (WSL) | `setup --update` でも毎回走る (order 96)。`-Check` を流し、入っていなければ `-IfMissing` で入れ (UAC が出る。待つのは 600 秒まで)、差があれば ⚠ で囲んで知らせる (揃えはしない) |
| `nix/scripts/bootstrap-windows-openssh.sh --apply` (WSL) | WSL から揃える。UAC は Windows のデスクトップに出る |
| `nix/scripts/check-winget-version.sh openssh` (WSL・CI) | 固定した版を winget の版の一覧と比べる。GitHub Actions の `winget-versions` が週 1 回流し、新しい版が GitHub に出て 30 日たつと落ちて知らせる ([後述](#openssh-の新しい版が出たとき)) |

- UAC で管理者に昇格し直すのは、今の pwsh (`Install-Sshd` も同じ)。ただし今の pwsh が MSIX なら MSI の pwsh で昇格し直し、MSI の pwsh も無く
  普段のアカウントが管理者でなければ、UAC を出さずに止めて bootstrap を流し直すよう ※ で出す (UAC の確認で別の管理者のアカウントの資格情報を
  入れると、昇格した側で MSIX の pwsh を起こせない)。昇格した側で winget が見つからなければ、そのアカウントと登録の手を ※ で書いて止まる
  ([PowerShell 7 の MSIX の限り](#powershell-7-の-msix-の限り))

揃えるときにすること:

1. 入っている版 (`ssh.exe` の FileVersion) と固定した版を比べ、`winget upgrade` か `install` に
   `--version` を付けて揃える。upgrade には `--include-pinned` も付け、3 で足した pin を越える (付けないと、版を名指しした upgrade は
   pin に止められる。[winget の pin](#winget-の-pin))。下げるときは MSI が「新しい版が入っている」で止めるので、先に `uninstall` する。
   どれにも `--custom ADDLOCAL=Client` を付け、sshd は入れない。ただし `Install-Sshd.ps1` が Server を足したマシン (`sshd.exe` がある) では
   `ADDLOCAL=Client,Server` にして Server を残す (ADDLOCAL を渡すと MSI は前の版の機能を引き継がないので、Client だけで上げると sshd が消える)。
   上げ直した MSI は 22 番の受信の許可を有効に戻すので、終わったら `Install-Sshd` で揃える ([sshd](#sshd))
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
- `Invoke-Winget` は、コンソールの文字コードが UTF-8 でなければ、winget を打つ間だけ UTF-8 にして読む (winget は管へ UTF-8 で書く)。UAC で昇格し直した
  子 (`-LogPath`) の窓と手で打った窓は CP932 で、そのまま読むと進み具合の帯 (█▒) が「笆遺毎」に化けて除けず、昇格した側の行 (`[管理者]`) に残った。
  runner と WSL の wrapper は UTF-8 にしてから流すので替えない。winget を打つほかの ps1 (`Install-Sshd.ps1`・`Install-Tailscale.ps1` と、winget の portable の
  道具の共通の枠 `win/winget/WingetPortable.ps1` など 8 本) の `Invoke-Winget` も同じ本文にそろえてあり、`Install-OpenSSH.Tests.ps1` が突き合わせ、持つ
  ps1 の数 (bootstrap と合わせて 9 本) も数える (直すときは全部を直す。winget を打つ ps1 を足したら、この本文を写して試験の数を直す。winget の
  portable の道具は写さずに枠を使う)。昇格した側で winget が見つからないときの `Format-WingetMissingNote` も、
  bootstrap・`Install-OpenSSH.ps1`・`Install-Sshd.ps1` で同じ本文にそろえてあり、同じ試験が突き合わせる
- `-Check` の終了コードと締めの文 (`Get-OpenSshExitCode`・`Get-OpenSshCheckMessage`) は、96 が読む。変えるときは
  `nix/scripts/bootstrap-windows-openssh.sh` とそのテストも直す
- winget やサービスに触る部分は、実機で `-Check` と本番を打って確かめる

## ssh の設定

1Password を使う WSL のマシンでは、WSL の `ssh` は Windows の `ssh.exe` を呼ぶ ([OpenSSH](#openssh))。
`ssh.exe` が読むのは Windows 側の `%USERPROFILE%\.ssh\config` なので、そこにも WSL と同じ形を置く
(経緯は [ADR 016](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/016_ssh_config_from_dotfiles_private_20261012T131912JST/README.md))。
`manifest.toml` では配らず、`nix/scripts/bootstrap-windows-ssh-config.sh` (order 91) が
`setup --update` のたびにコピーする。受け持ちを runner に切り替えたホストでは、runner の `ssh-config` (同じ order) が
同じ中身・判定・記録の形で置く ([runner の手順](#runner-の手順)。記録は `%LOCALAPPDATA%\dotfiles\state\windows-ssh-config.deployed.json`)。

| Windows 側 | 中身 | 出所 |
| --- | --- | --- |
| `%USERPROFILE%\.ssh\config` | `Include config.d/*.ssh_config` の 1 行、その後ろの `Host *` の `SetEnv PJP_SSH_CLIENT=%u@%L`、説明のコメント | script が置く |
| `%USERPROFILE%\.ssh\config.d\<名前>.ssh_config` | 接続先 | private な dotfiles-private の `ssh/` からコピー |
| `%USERPROFILE%\.ssh\config.d\00-op-reason-ssh-relay.ssh_config` | どの接続先にも効く `IdentityAgent \\\\.\pipe\op-reason-ssh-agent` (op-reason の SSH の中継)。ホストの値の `opReasonSshRelay` が on のホストだけ | runner の `ssh-config` が置く ([SSH の中継](#ssh-の中継)) |
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
- SSH の中継を使うホスト (受け持ちを runner に切り替え、ホストの値の `opReasonSshRelay` が on) では、runner の `ssh-config` が `config.d` の最初に読まれる
  `00-op-reason-ssh-relay.ssh_config` に中継の `IdentityAgent` を書く (接続先ごとの `IdentityAgent` より先に効く。dotfiles-private の `ssh/` には同じ名前を
  置かない)。`config` は変えない (WSL の script と同じ字のまま)。置く前に中継が答えるかを見て、初めてで答えなければ置かずに ⚠、前に置いたものがあれば
  消さずに ⚠ を出す (細部は [SSH の中継](#ssh-の中継))。switch を切れば、記録どおりに消す。WSL の script はこのファイルを置かない
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

判定だけ見るなら `--dry-run` を付ける。受け持ちを runner に切り替えたホストでは、Windows の PowerShell で `dotfiles apply --steps ssh-config --force`
(判定だけなら `dotfiles check --steps ssh-config`)。runner の退避の名前の日時は UTC (末尾に `Z`。`config.dotfiles-bak-20261120-003512Z` など)。

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
| `%USERPROFILE%\.config\port-forward\hosts.json` | 共有の組 (正本を JSON にしたもの) | `setup --update` の `bootstrap-windows-port-forward.sh` (order 99。受け持ちを runner に切り替えたホストは runner の `port-forward`)。pf は書かない |
| `%USERPROFILE%\.config\port-forward\local.json` | その PC で足した・直した・隠した組と、前回つないだ port・最近つないだ Host | pf |

- 共有の組を足す・直すときは、dotfiles-private の `ssh/port-forward.toml` を直して `--check` で確かめ、commit・push して、
  各 Windows の PC の WSL で `~/dotfiles/setup --update` を流す (受け持ちを runner に切り替えた PC は、`dotfiles --self-update apply` で dotfiles-private の
  clone を進めてから `dotfiles apply`)。Host 名は ssh の設定と同じ綴りで書き、`.` を含むときは
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
- 受け持ちを runner に切り替えたホストでは、runner の `port-forward` が同じ確かめ・中身 (バイト列まで)・判定・記録の形で置く (Windows の PowerShell で
  `dotfiles apply --steps port-forward`。`--dry-run`・`--force` も同じ。正本の書き方は `dotfiles check --steps port-forward` でも確かめられる (Windows の
  側も見る))。runner は正本を Nix ではなく Rust の TOML の読み手で読む (Nix が止める `\e` などの書き方も通す)。runner の退避の名前の日時は UTC (末尾に `Z`)
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

受け持ちを runner に切り替えたホストでは、runner の手順 `powertoys` (order 91) が同じことを同じ順にする (`dotfiles apply --steps powertoys`。
`--force` は変わっていなくても読み直させる)。入っているかは clone の `win/powertoys/Install-PowerToys.ps1 -Check` で見る。止める・起動する・待つ・
イベントを送る PowerShell の本文は WSL と同じで、Windows PowerShell に `-EncodedCommand` で渡す。記録と印は `%LOCALAPPDATA%\dotfiles\state\`
(`powertoys-keyboard-manager.reloaded`・`powertoys-enable.pending`)。`dotfiles check` と `apply --dry-run` は全体の設定・Keyboard Manager の
`settings.json`・記録を読むだけで、PowerToys を止めない・起こさない・イベントを送らない・winget を打たない。

- SSH の会話の中 (`SSH_CONNECTION` がある) の `dotfiles apply` は、PowerToys に触らず (入れる・止める・起こす・読み直させるをせず)、確かめた結果と ⚠ を
  出す。SSH の会話 (セッション 0) からは、デスクトップの会話の PowerToys のプロセスも Keyboard Manager のイベントも見えず、止める・起こすと別の
  PowerToys を起こし、読み直させないまま記録してしまうため。PC のデスクトップの PowerShell で流す
- 管理者の PowerShell から流さない。起動し直した PowerToys も管理者で動き、次にふつうの PowerShell から止められなくなる

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

受け持ちを runner に切り替えたホストでは、runner の手順 `fancyzones` (order 92) が同じことをする (同じ判定・PowerToys の形のバイト列)。打つものは
`dotfiles apply --steps fancyzones` (`--dry-run`・`--force`)・`dotfiles import fancyzones <名前>…` (`--import <名前>` の代わり)。ディスプレイと
仮想デスクトップは WSL と同じ PowerShell の本文を Windows PowerShell の `-EncodedCommand` で聞く (`dotfiles check` と `apply --dry-run` も聞く。
読むだけ)。記録は `%LOCALAPPDATA%\dotfiles\state\windows-fancyzones.{applied,assigned}.json`、退避は
`%LOCALAPPDATA%\dotfiles\state\windows-fancyzones\backup\<UTC の時刻>-<pid>\` (10 回分)。

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
Windows 側の `config1.db` は protobuf のバイナリで、保存のたびに時刻が入るので、テキストから組み立てて配る。受け持ちが
WSL のホストでは `nix/scripts/bootstrap-windows-google-ime.sh` (order 98) が、受け持ちを runner に切り替えたホストでは runner の手順
`google-ime` (同じ order。[runner の手順](#runner-の手順)) が、同じ判定・同じバイト列・同じ形の記録で配る
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
| `dotfiles apply --steps google-ime` (runner) | 組み立てて配る (受け持ちを runner に切り替えたホスト) |
| `dotfiles check --steps google-ime` (runner) | 判定だけ見る (`apply --dry-run` も同じ。受け持ちによらず流せる) |
| `dotfiles check --steps google-ime --show-words` (runner) | 辞書の衝突でも語の diff を出す。自分の端末で打つ (Claude などのログに残る場所では流さない) |
| `dotfiles import google-ime` (runner) | 画面で変えた分を、テキストへ取り込む (受け持ちが runner のホストだけ) |
| `dotfiles apply --steps google-ime --force` (runner) | 衝突でも repo の中身で置き直す |

runner に `--check` は無い。runner の check と apply は、置き先がある (Google 日本語入力を使っている) PC ではテキストを組み立ててから
判定するので、テキストの誤りはその行に出る (入っていない・まだ使っていない PC と、apply で設定画面が開いている・`tasklist` で確かめられない
ときは、組み立てる前に止まる)。CI では `win/runner` の試験が repo のテキストを組み立てる (WSL の `--check` は、WSL の script を残す間は nix の
CI の lint で流れ続ける)。

- 辞書の名前は、Windows のファイル名にできるものにする (runner は `<>:"|?*`・制御文字・`CON`・`NUL`・`COM1` などの名前と、大文字小文字だけが違う
  2 つの名前を止める。画面で名前を変える)。画面で辞書の名前の大文字小文字だけを変えて取り込むと、runner は TSV の名前を替える
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
  印がある回の衝突は、古い設定が書き戻されたものかもしれない (repo 側を残すなら `--force`)。runner は ⚠ の行にし、印は
  `%LOCALAPPDATA%\dotfiles\state\google-japanese-input\restart-pending` (次の `dotfiles apply` が落とし直す。check と dry-run は落とし直すと出すだけ)
- runner は SSH の会話 (Windows のセッション 0) からもデスクトップと同じに流す。`tasklist` は全部のセッションのプロセスを数え、`taskkill` は同じ
  ユーザーの別のセッションの変換サーバーも止められる見込み (実機では確かめていない。止められなければ上の印が残り、次の apply が落とし直す)
- 直接入力モードのキー (F13 → IMEOn など) を変えたときは、アプリを起動し直すと効く
- 設定画面か辞書ツール (`GoogleIMEJaTool.exe`) が開いていると、閉じるよう出して止まる (exit 1)。
  interop が落ちていると置かない (exit 0。落とし直しの印は残る)。`--import` と `--dry-run` は一緒に
  使えない (exit 2)。runner は `tasklist` で見て、開いていれば ⚠ (何も置かない)、`tasklist` が無い・落ちたときも置かずに ⚠ にする
- Google 日本語入力は入っているが置き先 (`%USERPROFILE%\AppData\LocalLow\Google\Google Japanese Input`) がまだ無い
  (入れただけで一度も使っていない) ときは、一度使ってから流し直すよう出して飛ばす (exit 0)。置き先は Google 日本語入力が
  初めて起動したときに作るので、先に作って置くことはしない (作るときの権限と揃わないおそれがある)。新しいマシンの流れは
  [Google 日本語入力を入れる](#google-日本語入力を入れる-winget)
- 置き換える前のファイルは `~/.local/state/dotfiles/google-japanese-input/backup/<UTC の時刻>-<pid>/` に
  退避する (新しい方から 10 回分。runner は `%LOCALAPPDATA%\dotfiles\state\google-japanese-input\backup\<UTC の時刻>-<pid>\`)。退避から戻すときは:
  1. 設定画面と辞書ツールを閉じる
  2. 退避したファイルを IME のディレクトリ (`%USERPROFILE%\AppData\LocalLow\Google\Google Japanese Input`。
     WSL からは `/mnt/c/Users/<名前>/AppData/LocalLow/Google/Google Japanese Input`) へ `cp` する
  3. `taskkill.exe /F /IM GoogleIMEJaConverter.exe` で変換サーバーを落とす (次のキー入力で起き直して読む)

  戻すと repo のテキストと違うので、次の `setup --update` は衝突になる (戻した中身を残すなら `--import`。runner は `dotfiles import google-ime`)
- 画面で変えたら、次の `setup --update` がこの手順 (order 98) で衝突として止まる。98 より前の bootstrap は
  済んでいるが、後ろの [日付と時刻の形式](#日付と時刻の形式)・[port forwarding の組](#port-forwarding-pf)・[Windows Terminal](#windows-terminal) の手順 (どれも order 99) と wsl-mtu-guard・exe-exec-trace、最後の「残りの手作業」は、解いて流し直すまで走らない。衝突で
  出すのは、設定は diff、辞書は辞書ごとの行の数 (「Windows 側にだけある行 N・repo 側にだけある行 M」
  など) だけで、辞書の語は setup の出力に出さない。語の diff は、自分の端末で `--dry-run --show-words`。runner は ⚠ の行を出して
  ほかの手順を流し続け、語の diff は自分の端末で `dotfiles check --steps google-ime --show-words`
- `--import` (runner は `dotfiles import google-ime`) で取り込み、最後の行に出た repo (テキストが変わった側。dotfiles・dotfiles-private・両方) で `git diff` を見て commit する (dotfiles-private の diff には辞書の語が出るので、自分の端末で見る)。どちらも変わらなければ「取り込みの分で commit するものはありません」と出る
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

新しいマシンでは、98 の置き先がまだ無ければ setup を 2 回流す (受け持ちが runner のホストでは `dotfiles apply` を 2 回。置き先は、Google 日本語入力が初めて起動したときにできる。
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
home-manager が PATH に入れる。Windows には触らない。受け持ちを runner に切り替えたホストでは PATH に入らない (runner の `google-ime` は
同じバイト列を Rust で組み立てる)。そのホストで使うなら、dotfiles の root で `nix run ./nix#pjp-google-ime -- <引数>`。

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
- 受け持ちを runner に切り替えたホストでは、runner の手順 `terminal` (order 99) が同じことをする (同じ判定・同じバイト列)。打つものは
  `dotfiles apply --steps terminal` (`--dry-run`・`--force`)・`dotfiles import terminal` (`--import` の代わり)。記録は
  `%LOCALAPPDATA%\dotfiles\state\windows-terminal.applied.json`、退避は `%LOCALAPPDATA%\dotfiles\state\windows-terminal\backup\<UTC の時刻>-<pid>\`
  (10 回分)。`settings.json` が無い・JSON として読めないときは ⚠ (manual) で、書かずに進む

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

受け持ちを runner に切り替えたホストでは、PowerShell で `dotfiles import terminal` (1) か `dotfiles apply --steps terminal --force` (2)。

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
- 受け持ちを runner に切り替えたホストでは、runner の手順 `international` (order 99) が同じことをする (同じ判定・同じ PowerShell の本文を `pwsh` に
  `-EncodedCommand` で渡す)。打つものは `dotfiles apply --steps international` (`--dry-run`・`--force`)・`dotfiles import international` (`--import` の
  代わり)。記録は `%LOCALAPPDATA%\dotfiles\state\windows-international.applied.json`。`dotfiles check` と `apply --dry-run` は読むだけで、書かず、
  WM_SETTINGCHANGE も送らない。`pwsh` が無いときと読めないときは ⚠ で、書かずに進む (グループポリシーで止められた値も ⚠。runner には setup を
  止めることが無いので、警告の代わりに ⚠ の行で毎回知らせる)
- SSH の会話 (`SSH_CONNECTION`・`SSH_CLIENT` がある) の runner の apply は、書く値があれば書かずに ⚠ を出す (`apply --dry-run` はそう予告する)。Win32-OpenSSH の会話はセッション 0 で、WM_SETTINGCHANGE が
  デスクトップの会話のアプリ (タスクバーの時計など) に届かないため。PC のデスクトップの PowerShell で `dotfiles apply --steps international` を流す

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

受け持ちを runner に切り替えたホストでは、PowerShell で `dotfiles import international` (1) か `dotfiles apply --steps international --force` (2)。

### 形式の値を足す

持てる名前は script の表 (`table`) にあるものだけ (今は上の 3 つ)。長い日付 (`sLongDate`) などを持つときは:

1. `nix/scripts/bootstrap-windows-international.sh` の `table` に、名前と LCType (winnls.h の `LOCALE_*` の値) を 1 行足す。
   書く順も表の順。runner の `runner/src/steps/international.rs` の `TABLE` にも同じ順で足す (試験が WSL の script の表と突き合わせる)
2. `managed.json` に同じ名前で値を書き、`--check` で検証して `--dry-run` で判定を見る
3. commit して `~/dotfiles/setup --update`

## type-clipboard

`type-clipboard/Install-TypeClipboard.ps1` は、自作の Windows のアプリ type-clipboard
([pollenjp/type-clipboard](https://github.com/pollenjp/type-clipboard)) を、GitHub の Release から固定した版で入れる。
type-clipboard はクリップボードの文字を、選んだ窓へキー入力として 1 文字ずつ打ち込む (Hyper-V の VMConnect や RDP の
サインイン画面など、貼り付けが効かない所にパスワードを入れるため)。単一の exe で、インストーラも署名も無く、winget にも無い。

- setup が入れるのは `dotfiles.wsl.windowsFiles.typeClipboard.enable = true` のマシンだけ (既定は設定グループで決まり、グループ all の win/ を
  配るマシンで true。minimum では入れるホストが書く)。値は dotfiles-private に登録したホストのファイルか、`~/dotfiles/flake.nix` に
  足したホストの `wsl` に書く:

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
(呼び出しの取り決め (payload の版) が変わった版どうしでは断られる。0.1.0 から 0.9.0 まで同じ取り決め)。

- setup が入れて揃えるのは、WSL の op の wrapper を入れるマシン (`dotfiles.wsl.enable` と `dotfiles.onePassword.enable` が両方 true。
  home-manager が書く `~/.local/state/dotfiles/claude-op-reason.json` の `enable`) のうち、win/ を配るマシン。option は無い。
  win/ を配らないマシンでは setup がそう 1 行出す。受け持ちを runner に切り替えたホストでは runner が入れる (次の箇条)。ほかは
  op-reason の README の「Windows で」の手順で手で入れる (置き場所を下の既定にすれば、WSL の op の既定の `OPREASON_EXE` のまま使える)
- Windows 側の runner の手順 `op-reason` ([runner の手順](#runner-の手順)) も、同じ判断で入れて揃える (同じ `Install-OpReason.ps1` を clone から呼ぶ。
  on/off はホストの値の `onePassword` で、WSL の記録 `claude-op-reason.json` は読まない)。受け持ちが WSL のホストでは `dotfiles check` で確かめる
  だけで、受け持ちを runner に切り替えたホストでは `dotfiles apply` が揃える (WSL の setup は Windows に配らないので揃えない)
- 置き場所は `%LOCALAPPDATA%\Programs\op-reason`。WSL の op は、ここの `op-reason.exe` を `OPREASON_EXE`
  (`/mnt/c/Users/<windowsUserName>/AppData/Local/Programs/op-reason/op-reason.exe`。`home/modules/op-reason.nix` が包みに入れる既定)
  で見つけ、`launcher.ps1` はその隣から探す。Windows の PATH には足さない (WSL が Windows の PATH を読み直す `wsl --shutdown` も
  待たずに済む)
- 版は `Install-OpReason.ps1` の `-Version` の既定値 (今は `0.9.0`) の 1 か所で、その版の zip の SHA-256 (`Zip`) と、展開した
  中身の値 (`Tree`) を同じファイルの表 (`Get-OpReasonReleases`) で固定する。`Zip` は Release に置いた `op-reason-windows.zip.sha256`
  の中身と同じ。WSL の実行ファイルの版 (`nix/pkgs/op-reason/default.nix` の `version`) と同じにする (テストが突き合わせる)
- 自作のアプリの Release なので、type-clipboard と同じく依存の公開からの猶予 (7 日) は置かない。中身は SHA-256 で固定する
- WSL の実行ファイルは switch で上がるので、Windows の部品も setup のたびに揃える (type-clipboard と違い、版がずれていれば
  入れ替えまでする)。`op-reason.exe` は op の呼び出しの間しか動かない
- 0.4.0 からの `op-reason.exe` は SSH の中継 (`op-reason.exe --ssh-agent`。1Password の SSH agent の前に立ち、鍵を使うたびに呼び手と
  理由を窓に出す) にもなる。中継を使うホスト (受け持ちを runner に切り替え、ホストの値の `opReasonSshRelay` が on) では、runner が
  op-reason 自身の task (0.7.0 から。op-reason の CLI で揃える) で中継を常に動かし、Windows と WSL の ssh を中継へ向ける。そのホストでは
  上の「op の呼び出しの間しか動かない」が崩れるので、入れ替えるときは中継を止めて入れ替え、起こし直す ([SSH の中継](#ssh-の中継))。中継を使わないホストでは、
  dotfiles は中継を起こさず、ssh をそこへ向けもしない (WSL の側の入口 `op-reason-ssh` は名前を PATH に置くだけ)
- `op-reason.exe` には署名が無い。Smart App Control に止められると、WSL からの呼び出しはひとりでに `launcher.ps1` に回り、
  そのたびに stderr に 1 行出る (止められる間は、窓が launcher の窓になる)。毎回の試しをやめるなら、そのホストの WSL の環境に
  `OPREASON_RUNNER=launcher` を置く (nix/README.md)。`Install-OpReason.ps1` は、中継を使わないホスト (`-SshRelay` を渡さないか `off` で、
  中継の task が無い) では exe を起こさないので、止められても入れて揃えられる (中継を使うホストでは `op-reason.exe --settings` を打つ。
  中継そのものが exe を動かすので、止められるホストでは中継を使えない)
- Windows から直に呼ぶ (Windows の Claude Code など) ときは、op-reason の README の「Windows で」のとおり置き場所を Windows の
  PATH に足す。Smart App Control に止められるマシンでは、`<置き場所>\powershell-entry` を置き場所より前に足す。dotfiles はどちらも
  足さない

| 打つもの | すること |
| --- | --- |
| `Install-OpReason -Check` (PowerShell) | 差を出すだけ (ネットワークも使わない)。揃っていれば終了コード 0、差があれば 1、入っていなければ 3 (`-SshRelay` で中継を確かめられなければ 2) |
| `Install-OpReason` (PowerShell) | 揃える (入れる・入れ替える) |
| `Install-OpReason [-Check] -SshRelay per-call\|show-only\|off` (PowerShell) | SSH の中継も揃える (モードなら op-reason の CLI で op-reason 自身の task と中継を揃え、`off` なら残った task を消す。0.6.0 までの task は 1 回だけ移す。[SSH の中継](#ssh-の中継))。`-SshRelay` を渡さなければ task を置きも消しもしない |
| `nix/scripts/bootstrap-windows-op-reason.sh` (WSL) | `setup --update` でも毎回走る (order 90)。WSL の op を入れて win/ を配るマシンだけ、入っていなければ入れ、差があれば入れ替える。揃えられなければ ⚠ で囲んで知らせる |
| `nix/scripts/bootstrap-windows-op-reason.sh --apply` (WSL) | WSL から揃える (確かめずに流す) |
| `dotfiles check --steps op-reason` (PowerShell。runner) | `-Check` だけを流し、締めの表に揃っている・入っていない (apply で入れる)・揃っていない (apply で揃える) を出す (何も変えない) |
| `dotfiles apply --steps op-reason` (PowerShell。runner) | 受け持ちを runner に切り替えたホストで、WSL の setup と同じ判断で入れる・入れ替える (揃えられなければ締めの表の ⚠ に直し方を出す)。`-SshRelay` にホストの値の中継のモードか `off` を渡すので、中継の task も揃える |

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
  しれない)。動いているのが SSH の中継の task の中継だけなら、lock を取れたときだけ止めて入れ替え、起こし直す ([SSH の中継](#ssh-の中継))
- 止められた実行 (setup の時間切れなど) が隣に残した途中の物 (`op-reason.download-*`・`op-reason.new-*`・`op-reason.old-*`) は、
  次に入れるときに 10 分より古ければ消す
- Invoke-WebRequest で落とすので、展開した物に Mark of the Web (`Zone.Identifier`) は付かない。`powershell-entry` の `.ps1` も
  `Unblock-File` せずに RemoteSigned で動く (中身は SHA-256 で確かめてある)
- 記録などの置き場 (`%LOCALAPPDATA%\op-reason`。記録の `log.jsonl`・窓で選んだ言語の `settings.json`・0.3.0 からは窓のリンクに使う
  アカウントの ID の `account.json`・0.4.0 からは中継の記録の `ssh-log.jsonl` など) は op-reason が置く別の場所で、触らない
- PowerShell 7 でも Windows PowerShell 5.1 でも動く。SHA-256 と展開は .NET で行う (PowerShell 7 から起こした 5.1 は PSModulePath を
  継ぎ、`Get-FileHash`・`Expand-Archive` が見つからないことがある)
- 入れるのをやめる (WSL の op を入れないマシンにする) ときも、setup は消さない。消すなら op の呼び出しが無いときに
  `%LOCALAPPDATA%\Programs\op-reason` を消す (記録の `%LOCALAPPDATA%\op-reason` も要らなければ消す)

### SSH の中継

0.4.0 からの `op-reason.exe` は SSH の中継 (`op-reason.exe --ssh-agent`) にもなる。1Password の SSH agent (`\\.\pipe\openssh-ssh-agent`)
の前に立ち、鍵を使う呼び出しごとに、呼び手と理由を op-reason の窓に出す (op-reason の README の「SSH keys: the relay」)。dotfiles は、
受け持ちを runner に切り替えたホストでだけ、中継を op-reason 自身の task (logon と 1 分ごと) で起こし、Windows と WSL の ssh を中継へ向ける
(dotfiles-private の ADR 089・ADR 098)。

- per-call (既定) では、鍵を使ってよいかを決めるのが 1Password の画面から op-reason の窓に移る。1Password は中継 (op-reason) を
  1 回承認するだけになり、呼び出しごとの許可は op-reason の窓が受け持つ。show-only では決めるのは 1Password の画面のままで、
  op-reason の窓は誰が・何のためにを並べるだけ (1Password を「リクエストごと」にする人向け)
- 中継が動いていなければ、Windows と WSL の ssh は鍵を使えない (黙って 1Password に直に回らない)

#### 入れ方

switch は 2 つ。どちらも既定は off で、同じ PC で両方を on にする (片方だけだと、WSL の ssh だけが中継に向く・中継を通らないのに
窓の知らせが出るなど食い違う)。

| 側 | 書く所 (dotfiles-private) | 効くもの |
| --- | --- | --- |
| Windows | `win/hosts/<user>@<pc>.toml` の `[tools]` に `opReasonSshRelay = true` (`onePassword = true` も要る)。モードは `[opReason] sshRelayMode` (`per-call`・`show-only`。書かなければ per-call) | runner の手順 `op-reason` が op-reason の CLI で op-reason 自身の task を作って中継を起こし、手順 `ssh-config` が中継を指す `IdentityAgent` のファイルを置く |
| WSL | `nix/hosts/<user>@<hostname>.nix` の `modules` に `{ dotfiles.opReason.sshRelay.enable = true; }` (モードは `.mode`。Windows と同じ値にする) | WSL の `ssh` の wrapper が `op-reason-ssh` を起こす・Claude の hook (ssh-agent-notice) の知らせ ([`nix/README.md`「SSH の中継を使う」](../nix/README.md#ssh-の中継を使う)) |

- 使えるのは、受け持ちを runner に切り替えたホストだけ (WSL の option は `wsl.windowsFiles.enable = false` のホストでだけ on にでき、
  ほかでは評価で止まる。WSL の setup は中継に触らない)
- dotfiles の変更が main に入ってから dotfiles-private で on にする (先に on にすると、runner は知らないキーで、setup は評価で止まる)。
  当てるのは Windows の `dotfiles apply` (task・中継・`IdentityAgent`) が先で、WSL の `setup --update` (wrapper) が後

#### op-reason の task

0.7.0 から、中継の task は op-reason 自身が持つ (root のフォルダの `\op-reason-ssh-relay-<SID>`。`<SID>` はユーザーの SID)。
`Install-OpReason.ps1 -SshRelay <モード>` は task を自分で置かず、op-reason の CLI で比べて揃える (dotfiles-private の ADR 098。op-reason の
設計の §18)。runner は switch が on ならモード、off なら `off` をいつも渡す (WSL の setup と、手で打つ `Install-OpReason` は渡さない。
渡さなければ task を作りも消しもしない)。

- モード: `op-reason.exe --settings check relay.autostart=on relay.mode=<モード> relay.running=on --json` で比べ (0 同じ・1 違う・2 読めない)、
  違えば同じ値の `set` で揃える。op-reason が task を作り、`settings.json` に `relay.mode` を書き、中継を起こして答えるのを 15 秒待つ。中継の
  モードは task の引数でなく `settings.json` から読む (task の動作は `op-reason.exe --ssh-agent --task <名前>`)。モードを替えると op-reason が
  中継を起こし直す。止めた中継 (`relay stop` で task が無効) も起こす
- `off`: op-reason の task があれば `set relay.autostart=off` (op-reason が中継を止めて task を消す)。どちらの task も無ければ `op-reason.exe`
  を起こさない (中継を使わないホストで Smart App Control に当たらないように。task の有る無しは `Get-ScheduledTask` で読む)
- task の形 (logon と 1 分ごとの trigger・2 つ目を起こさない・隠す・優先度 5・失敗したら起こし直す設定は無い) は op-reason が決める
  (op-reason の README の「起こし方」)。0.6.0 までの dotfiles の task と同じ形
- 確かめられない (`check` が 2・`op-reason.exe` を起こせない・JSON を読めない) ときは、`-Check` も揃える流れも終了コード 2 で何も変えない
- `--settings` は 0.7.0 からの `op-reason.exe` にだけ渡す (入れ替えが要れば、入れ替えた後の exe で打つ)。`-SshRelay` は 0.7.0 より前の
  `-Version` には渡せない
- 置き場所が既定 (`%LOCALAPPDATA%\Programs\op-reason`) でなければ、`-SshRelay` を渡しても task にも中継にも触らない (一時の置き場所で
  試すときに、本物の task をその置き場所の exe に向けない。op-reason の `set` は打った exe を task の動作にする)

#### 前の task からの移し (1 回だけ)

0.6.0 までの dotfiles は task `\pjp\op-reason-ssh-relay` を自分で置いていた。`-SshRelay` を渡されてそれが残っていれば、op-reason の設計の
§18 の順で 1 回だけ移す:

1. 前の task の中継を、op-reason の lock を取ってから止める (task を無効にし、0.7.0 の中継には stop event で止まるよう頼み、残っていれば
   `Stop-ScheduledTask`)。lock を取れなければ (窓が開いている) 何も変えずに止まる。前の task が一瞬だけ動いて見えても、答えている中継が
   op-reason の task のものなら止めない (どの中継かは op-reason に聞く)。ほかで起こした中継が答えていれば、lock を取ってから前の task だけを止める
2. 入れ替えが要れば入れ替え、lock を放して `set relay.autostart=on …` (op-reason が自分の task を作って中継を起こす)
3. `set` が通ったら前の task を消す。通らなくても op-reason の task ができていれば消し (task を 2 つ残さない)、できていなければ前の task を
   有効に戻して中継を起こし直す (次の apply がまた移す)

逆の順 (前の中継が動いている間に `set`) だと、op-reason は自分の task を無効で作る。`-SshRelay off` なら 1 の後に前の task を消すだけ。
入れ替えが落ちたときは、前の task を有効に戻して中継を起こし直す (0.6.0 の exe では op-reason の task を作れない)。

#### 版上げ

- 置き場所を入れ替えるときに、動いている `op-reason.exe` が中継だけなら、止めて入れ替え、起こし直す。どの中継かは op-reason に聞く
  (`op-reason.exe --settings get relay.running --json` の `ours`・`by`。0.6.0 の exe なら `--ssh-agent --status` と前の task の様子)
  - op-reason の task の中継: 入れ替える前に `op-reason.exe --settings relay stop` (op-reason が task を無効にし、lock を取って止める)、
    入れ替えた後に新しい exe で `set …` (モードのとき) か `relay start` (`-SshRelay` なし)。何も動いていなくても op-reason の task が有効
    なら止めておく (1 分ごとの trigger が入れ替えの途中に古い exe を起こさないように)。ただし、ほかで起こした中継が答えていれば `relay stop` を
    打たない (持ち主の違う中継には、op-reason の task を無効にしてから断る)。`relay stop` で止めていた中継 (task が無効) は、`-SshRelay` なしでは
    起こさない
  - 前の task の中継: lock を取ってから task を無効にして止め、入れ替えてから、移す (`-SshRelay` つき) か、有効に戻して起こし直す (なし)
- lock を取れない・`relay stop` が断る (中継が窓を開いている・1Password の確認を待っている)・ほかの `op-reason.exe` (op の呼び出し・task の
  外で起こした中継) も動いているときは、今までどおり何も変えずに止まる。答えてから `dotfiles apply` を打ち直す
- 入れ替えが落ちて前の中身に戻したら、止めた中継を前の exe で起こし直す
- op-reason の task がある間は、0.7.0 より前の版に入れ替えない (その版は task の動作の `--task` を知らない)。下げるなら先に
  `op-reason.exe --settings set relay.autostart=off`
- 起こし直した中継の最初の署名では、1Password の承認がもう一度要る (下の「1Password の承認」)

#### IdentityAgent のファイル

- runner の手順 `ssh-config` が `%USERPROFILE%\.ssh\config.d\00-op-reason-ssh-relay.ssh_config` に `IdentityAgent \\\\.\pipe\op-reason-ssh-agent`
  (OpenSSH は設定の `\\` を 1 つの `\` と読むので、頭の 2 つを重ねる) を書く。名前の頭の `00-` で `config.d` の最初に読まれ、接続先ごとの
  `IdentityAgent` より先に効く。`config` は変えない ([ssh の設定](#ssh-の設定))
- 置く前に中継が `--status` に答えるかを見る。初めてで答えなければ置かずに ⚠ (ssh は今までどおり 1Password に直に行く)。前に置いた
  ものがあれば消さずに ⚠ (鍵は使えない)。`op-reason.exe` が無いのも答えないとみなす
- dotfiles-private の `ssh/` には同じ名前のファイルを置かない (置くと、中継のファイルを置かずに ⚠)
- dotfiles-private の `ssh/` が空・読めないときは、ほかのファイルと同じく中継のファイルも置かず消さない。switch が on なのに無い・off なのに
  残っているときは ⚠ を出す (off なのに残ると、中継が止まったときに鍵を使えない)

#### 確かめ方

| 打つもの (Windows の PowerShell) | 見るもの |
| --- | --- |
| `Install-OpReason -Check -SshRelay per-call` | 版と中継の行 (task・前の task・`relay.autostart`・`relay.mode`・`relay.running`)。揃っていれば終了コード 0、確かめられなければ 2 |
| `& "$env:LOCALAPPDATA\Programs\op-reason\op-reason.exe" --settings list` | op-reason の設定の全部 (中継の task・答えている中継とその持ち主・ほかに中継を起こす task) |
| `& "$env:LOCALAPPDATA\Programs\op-reason\op-reason.exe" --ssh-agent --status` | 中継が答えれば `(pid N)` と終了コード 0 |
| `Get-ScheduledTask -TaskName 'op-reason-ssh-relay*'` | op-reason の task (`\` の `op-reason-ssh-relay-<SID>`) の有る無しと状態 (`Running`)。前の task (`\pjp\`) が残っていないこと |
| `dotfiles check --steps op-reason,ssh-config` | runner の判定 (中継だけが違えば「SSH の中継が揃っていない」、確かめられなければ ⚠ の「確かめられなかった (終了コード 2)」) |

#### 中継が止まったとき

- 鍵は使えない (ssh が失敗する)。op-reason の task が 1 分のうちに起こし直す。中継を止めた (通知領域の鍵のアイコンの「止める」・
  `relay stop`) ときは task が無効になっているので起き直らない。`op-reason --settings relay start` (WSL でも打てる。Windows では置き場所の
  `op-reason.exe`) で起こす (答えるかは `op-reason.exe --ssh-agent --status`)
- task の最後の結果 (`Get-ScheduledTaskInfo -TaskPath '\' -TaskName "op-reason-ssh-relay-<SID>"` の `LastTaskResult`。10 進で出る) は、
  中継が動いている間は `0x800710E0` (2147946720。1 分ごとの起動を、動いている中継があるので「新しいインスタンスを開始しない」で
  退けた。「要求を拒否した」と読めるが失敗ではない) か `0x00041301` (267009。task が起こした中継が動いている)。中継が終わった直後は、
  ほかの値 (中継の終了コード) のことがある (task の動作が終わると、その終了コードが入る見込み。次の 1 分ごとの起動で中継が起き直れば
  `0x00041301` に戻る)。1 分を過ぎてもほかの値のままなら、task が中継を起こせていない (Smart App Control など。`Install-OpReason` の
  「SSH の中継が答えない」の案内が見るのもこの値)
- 1 回だけ 1Password に直につなぐ: `ssh -o 'IdentityAgent=\\\\.\pipe\openssh-ssh-agent' <接続先>` (WSL でも PowerShell でも `\` を
  4 つ。`-o` は設定より先に効く)
- 手で中継を起こして試すときは、先に `op-reason --settings relay stop` で止める (task も無効になる。終わったら `relay start` で戻す)。中継は 1 つのログオンに 1 つで、task の外で中継が動いていると、1 分ごとの trigger が
  毎分 `op-reason.exe` を起こしては「もう動いている」で終わらせる

#### 1Password の承認

- 1Password が承認するのは中継の process (画面の名前も op-reason)。要るのは、中継が起き直った後 (logon・版上げ・落ちた後の 1 分ごとの
  trigger) と、1Password をロックした後の最初の署名。その後は、ロックするか中継が起き直るまで 1Password の画面は出ない
- 1Password は、求めの出どころのアプリか窓が前面にないと画面を伏せ、アイコンに点を付ける
  ([1Password の文書](https://www.1password.dev/ssh/agent/authorization))。op-reason は 0.6.0 から、許可を押すと 1Password が答えるまで
  中継の窓を前に出すので、1Password の画面はすぐ出る。それでも出なければ、
  タスクバーの 1Password のアイコンから「SSHリクエストを待機中……」(英語の表示では "SSH request waiting") を開いて、約 60 秒のうちに
  承認する (過ぎると 1Password が依頼を閉じ、ssh は断られる)
- 1Password の画面の「すべてのアプリケーションで承認」には印を付けない (付けると、中継を通らずに 1Password に直につなぐ道 (上の 1 回
  だけの書き方など) も、ロックするまで黙って通る)

#### 毎日の見え方

- WSL の ssh・git push・pf のたびに、op-reason の窓で許可を押す。端末で打った ssh の仲間のコマンドは「この端末を 60 分」も選べる
- herdr-app の example-laptop へのつなぎは、herdr-app を起こしたときと、許可から 60 分たってつなぎ直すときに窓が出る。example-laptop から転送された
  署名 (agent の転送) は 1 つずつ窓が出る
- Claude の git は gh の HTTPS なので、窓は出ない。Claude が打つ ssh には、hook (ssh-agent-notice) が理由 (`OPREASON_SSH_REASON`) を
  付けさせる

#### やめ方

2 つの switch を外す (ホストの値の `opReasonSshRelay` と、WSL の `dotfiles.opReason.sshRelay.enable`)。Windows で `dotfiles apply` を
流すと op-reason の task を消し (`set relay.autostart=off`。op-reason が中継を止める)、`IdentityAgent` のファイルを消す。WSL で `setup --update` を流すと、wrapper が `ssh.exe` に戻る。

#### 中継を通らないもの

commit の署名 (`op-ssh-sign-wsl.exe`。1Password と直に話す)・`ssh-add` (鍵の一覧。`ssh-add.exe` のまま)・Git for Windows の同梱の ssh
(MSYS2)・WSL の Linux の ssh (`USE_LINUX_SSH=1`)・`scp`・`sftp` (WSL では `/usr/bin/ssh` を起こす)。

Git for Windows の同梱の ssh は、中継にも 1Password の pipe にも届かない (MSYS2 の ssh は Windows の named pipe の agent を使えない)。Windows の
git は、`git-config` の手順が書く `core.sshCommand` で Windows の OpenSSH の ssh を使うので、中継を通る ([git の設定](#git-の設定))。

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
   途中で止まったら、終わってから `Install-OpReason` か `bootstrap-windows-op-reason.sh --apply` で揃える。WSL の側で入るものが新しい
   版の窓に頼る版 (0.3.0。`pjp-op-env` が理由から読む参照を外した。0.5.0〜0.9.0 は頼らない) では、Windows の部品を先に揃えてから switch する
   ([`nix/README.md`「op-reason の新しい版を出したとき」](../nix/README.md#op-reason-の新しい版を出したとき)の 5.)。setup が揃えない
   ホスト (win/ を配らない・受け持ちを runner に切り替えた) では、switch の前に Windows で揃える (受け持ちを runner に切り替えたホストは `dotfiles apply`、ほかは `Install-OpReason`)

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

- `bootstrap-windows-op-reason.sh` と runner の `runner/src/steps/ps1.rs` は、終了コード (0・1・3) と、状態の表の見出し (`op-reason (GitHub の Release`)
  で分かれる (締めの行は見ない。runner は、版は揃っていて SSH の中継だけが違うときの「⚠️ SSH の中継が揃っていない」を、行の字を替えるのに
  だけ見る)。変えるときは向こうも直す (runner の試験が本物の ps1 の `-Check` を流して確かめる)
- SSH の中継の流れ (前の task からの移し・版上げで止めて起こし直す・off) は、偽の task と偽の lock と、op-reason の CLI (check・set・
  relay stop/start・get の終了コードと JSON) を真似る偽物で `Install-OpReason.Tests.ps1` が確かめる。本物の op-reason の CLI と Task Scheduler
  では、実機で `Install-OpReason -Check -SshRelay per-call` が 0 を返すことで見る ([SSH の中継](#ssh-の中継)。手順は dotfiles-private の ADR 098 の §7)
- 一時の置き場所 (`-InstallDir`) では `-SshRelay` は効かない (task と中継に触らない)

## ntn

`ntn/Install-Ntn.ps1` は、Notion の CLI の ntn を winget の `Notion.ntn` (zip の中の portable。管理者は要らない。x64 だけ) で入れ、
版を `-Version` の既定値 (今は `0.23.30`) の 1 か所で固定する ([ADR 055](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/055_win_ntn_claude_code_pin_updates_20261114T185136JST/README.md))。公式の手順も、Windows では winget だけ
(install script は Windows に対応しない)。WSL・Linux の ntn は別に `nix/pkgs/ntn` が入れる
([`nix/README.md`「ntn (Notion CLI) を Nix で入れる」](../nix/README.md#ntn-notion-cli-を-nix-で入れる))。

- setup が入れて揃えるのは `dotfiles.wsl.windowsFiles.ntn.enable = true` のマシン。既定は設定グループで決まり、グループ all の win/ を
  配るマシンで true (minimum では使うホストが書く。[`nix/README.md` の「設定グループ」](../nix/README.md#設定グループ))。
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
| `Install-Ntn -Check` (PowerShell) | 差を出すだけ。揃っていれば終了コード 0、差があれば 1、入っていなければ 3 (昇格した PowerShell で winget を打てなければ 1) |
| `Install-Ntn` (PowerShell) | 揃える (入れる・入れ替える (上げる・下げる)・pin を足す) |
| `nix/scripts/bootstrap-windows-ntn.sh` (WSL) | `setup --update` でも毎回走る (order 97)。入っていなければ入れ、版か pin がずれていれば揃える。揃わなければ ⚠ で囲んで知らせる (setup は止めない) |
| `nix/scripts/bootstrap-windows-ntn.sh --apply` (WSL) | WSL から揃える (確かめずに流す) |
| `nix/scripts/check-winget-version.sh ntn` (WSL・CI) | 固定した版を winget の版の一覧と比べる。GitHub Actions の `winget-versions` が週 1 回流し、新しい版が winget に載って 30 日たつと落ちて知らせる ([後述](#ntn-の新しい版が出たとき)) |

揃えるときにすること ([winget の portable の道具](#winget-の-portable-の道具) の共通の枠。ghq・fzf・starship も同じ):

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
- winget が置き場所をユーザーの PATH に足すマシン (example-host) と、`%LOCALAPPDATA%\Microsoft\WinGet\Links` に symlink を置くマシン
  (開発者モードなど) がある。どちらも winget のものとして読む
- 入れ替えの途中で `winget install` が落ちると、ntn が入っていない状態で止まることがある (取得は先に確かめてあるので稀)。そのときは
  `Install-Ntn` を打ち直す (`dotfiles apply`・`setup --update` でも入る)
- 昇格した会話 (管理者として実行した端末と、そこから開いた WSL) では、winget を打たずに止まる ([昇格した PowerShell では入れない](#昇格した-powershell-では入れない))。
  setup は ⚠ で知らせるので、昇格していない端末から開いた WSL で流し直す

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
- 入口は道具の表 (`Get-NtnTool`) だけを持ち、流れは共通の枠 ([WingetPortable.ps1 を書くときの注意](#wingetportableps1-を書くときの注意))
- 表の値 (版の読み方・exe の置き場所) と、表を渡した流れ (打つ winget・動いていると止まる・install が落ちたときの行) は `ntn/Install-Ntn.Tests.ps1` で
  確かめる。Linux の pwsh で流すので Windows には触らない (このファイルは manifest に無いので配られない):

  ```sh
  nix shell nixpkgs#powershell -c pwsh -NoProfile -File win/ntn/Install-Ntn.Tests.ps1
  ```

- 締めの行 (`→ Install-Ntn で入れる`・`→ Install-Ntn で揃える`・`→ ※ の手順で直す`・`昇格した PowerShell では winget が ntn を入れない`) の文言は
  `bootstrap-windows-ntn.sh` と runner が読む。字は共通の枠が組む。変えるときは向こうも直す
- winget やプロセスに触る本物の部分は、実機で `-Check` と本番を打って確かめる

## Claude Code

`claude-code/Install-ClaudeCode.ps1` は、Claude Code を winget の `Anthropic.ClaudeCode` (portable の `claude.exe` 1 つ。管理者は要らない。
x64 と arm64) で入れ、版を `-Version` の既定値 (今は `2.1.330`) の 1 か所で固定する ([ADR 055](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/055_win_ntn_claude_code_pin_updates_20261114T185136JST/README.md))。PowerShell の `c` が
起動する `claude.exe` はこれ ([PowerShell](#powershell))。WSL の claude は mise の `claude@latest` (猶予 1 日) で、別のもの。

- winget で入れた Claude Code は自分では上がらない (公式。`claude update` は何もしない)。版は dotfiles が決める
- `CLAUDE_CODE_PACKAGE_MANAGER_AUTO_UPDATE` (Claude Code に `winget upgrade` を打たせる) は設定しない。ユーザー・マシンの環境変数か
  `%USERPROFILE%\.claude\settings.json` の `env` で有効になっていれば、`-Check` が ※ の行で知らせる (固定した版から外れうるので消す)
- Git for Windows は入れない。無ければ Claude Code は Bash tool の代わりに PowerShell tool で動く (公式)
- Claude Code の設定 (`%USERPROFILE%\.claude`) とログインは dotfiles では扱わない
- setup が入れて揃えるのは `dotfiles.wsl.windowsFiles.claudeCode.enable = true` のマシン。既定は設定グループで決まり、グループ all の
  win/ を配るマシンで true (minimum では使うホストが書く。[`nix/README.md` の「設定グループ」](../nix/README.md#設定グループ))。
  既定と違う値にするなら `wsl` に `windowsFiles.claudeCode.enable = false;` (か `true`) を書く ([ntn](#ntn) と同じ)。false に戻しても
  setup は消さない。消すなら PowerShell で
  `winget pin remove --id Anthropic.ClaudeCode --exact` の後に `winget uninstall --id Anthropic.ClaudeCode --exact`
- 置き場所は `%LOCALAPPDATA%\Microsoft\WinGet\Packages\Anthropic.ClaudeCode_Microsoft.Winget.Source_8wekyb3d8bbwe\claude.exe`

| 打つもの | すること |
| --- | --- |
| `Install-ClaudeCode -Check` (PowerShell) | 差を出すだけ。揃っていれば終了コード 0、差があれば 1、入っていなければ 3 (昇格した PowerShell で winget を打てなければ 1) |
| `Install-ClaudeCode` (PowerShell) | 揃える (入れる・入れ替える (上げる・下げる)・pin を足す) |
| `nix/scripts/bootstrap-windows-claude-code.sh` (WSL) | `setup --update` でも毎回走る (order 97)。入っていなければ入れ、版か pin がずれていれば揃える。揃わなければ ⚠ で囲んで知らせる (setup は止めない) |
| `nix/scripts/bootstrap-windows-claude-code.sh --apply` (WSL) | WSL から揃える (確かめずに流す) |
| `nix/scripts/check-winget-version.sh claude-code` (WSL・CI) | 固定した版を winget の版の一覧と比べる。GitHub Actions の `winget-versions` が週 1 回流し、新しい版が GitHub に出て 30 日たつと落ちて知らせる ([後述](#claude-code-の新しい版が出たとき)) |

揃えるときにすることは [ntn](#ntn) と同じ ([winget の portable の道具](#winget-の-portable-の道具) の共通の枠。取得を確かめてから外して入れ、
pin を足し、読み直す。昇格した PowerShell では入れない)。違うところ:

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
- 入口は道具の表 (`Get-ClaudeCodeTool`) と、自動更新の変数を見る custom の関数 (`Read-ClaudeCodeState`・`Format-ClaudeCodeNotes`) を持ち、流れは
  共通の枠 ([WingetPortable.ps1 を書くときの注意](#wingetportableps1-を書くときの注意))
- 表の値・custom の関数と、表を渡した流れは `claude-code/Install-ClaudeCode.Tests.ps1` で確かめる (Linux の pwsh):

  ```sh
  nix shell nixpkgs#powershell -c pwsh -NoProfile -File win/claude-code/Install-ClaudeCode.Tests.ps1
  ```

- 締めの行の文言 (`→ Install-ClaudeCode で入れる`・`→ Install-ClaudeCode で揃える`・`→ ※ の手順で直す`・`昇格した PowerShell では winget が Claude Code を入れない`)
  は `bootstrap-windows-claude-code.sh` と runner が読む。字は共通の枠が組む。変えるときは向こうも直す
- winget やプロセスに触る本物の部分は、実機で `-Check` と本番を打って確かめる

## ghq・fzf

`ghq/Install-Ghq.ps1` と `fzf/Install-Fzf.ps1` は、PowerShell の [cdrepo](#cdrepo-ghq-の-repo-を選んで移る) が使う ghq (repo の clone を決まった木に
並べる CLI) と fzf (行を絞り込んで選ぶ CLI) を winget で入れ、版を `-Version` の既定値の 1 か所で固定する (dotfiles-private の ADR 092
(`docs/adr/092_win_cdrepo_ghq_fzf_*`))。どちらも [winget の portable の道具](#winget-の-portable-の道具) の共通の枠で揃える (zip の中の portable。管理者は
要らない。常駐も UAC も無いので、版のずれも揃える)。
WSL・Linux の ghq と fzf は別に home-manager (`nix/home/modules/packages.nix`) が入れる。

| 道具 | winget の ID | 固定した版 (`-Version` の既定値) | 置き場所 (`%LOCALAPPDATA%\Microsoft\WinGet\Packages\` の下) |
| --- | --- | --- | --- |
| ghq | `x-motemen.ghq` | `1.12.0` | `x-motemen.ghq_Microsoft.Winget.Source_8wekyb3d8bbwe\ghq_windows_amd64\ghq.exe` (zip の中のディレクトリの下) |
| fzf | `junegunn.fzf` | `0.75.0` | `junegunn.fzf_Microsoft.Winget.Source_8wekyb3d8bbwe\fzf.exe` |

- 入れて揃えるのは Windows の runner の手順 `ghq`・`fzf` (order 97。Windows にしか無い手順で、WSL の setup には無い)。minimum の基本の道具の CLI で、
  Linux もどのグループでも入れるので、道具の switch は持たない (どのホストでもいつも on)。受け持ちが WSL のホストでも `dotfiles apply` が入れる
- ghq の設定 (git config の `ghq.*`) と fzf の設定 (環境変数 `FZF_DEFAULT_OPTS` など) は dotfiles では扱わない。ghq の root は既定の
  `%USERPROFILE%\ghq` で、bootstrap が clone する所と同じ
- 入れた後は、新しい PowerShell を開くと使える (winget がユーザーの PATH に足すのは、これから開く PowerShell の分)
- 消すなら PowerShell で `winget pin remove --id <ID> --exact` の後に `winget uninstall --id <ID> --exact` を打つ (runner の手順はいつも on なので、
  次の `dotfiles apply` で入れ直す)

| 打つもの | すること |
| --- | --- |
| `Install-Ghq -Check`・`Install-Fzf -Check` (PowerShell) | 差を出すだけ。揃っていれば終了コード 0、差があれば 1、入っていなければ 3 (fzf は、MSI の fzf が入っていれば 1。どちらも、昇格した PowerShell で winget を打てなければ 1) |
| `Install-Ghq`・`Install-Fzf` (PowerShell) | 揃える (入れる・入れ替える (上げる・下げる)・pin を足す) |
| `dotfiles apply --steps ghq,fzf` (PowerShell) | runner の手順で揃える (入っていなければ入れ、版か pin がずれていれば揃える。PATH のずれと MSI の fzf は知らせるだけ) |
| `nix/scripts/check-winget-version.sh ghq`・`fzf` (WSL・CI) | 固定した版を winget の版の一覧と比べる。GitHub Actions の `winget-versions` が週 1 回流し、新しい版が winget に載って 30 日たつと落ちて知らせる ([後述](#ghqfzf-の新しい版が出たとき)) |

揃えるときにすることは [ntn](#ntn) と同じ (取得を確かめてから外して入れ、pin を足し、読み直す)。違うところ:

- 入れる・取得を確かめるときは `--installer-type portable` で portable を名指しする。winget の `junegunn.fzf` は 0.75.0 から portable の zip と
  machine スコープの MSI (`%ProgramFiles%\fzf\bin`。UAC が要る) を並べ、名指ししないと winget は MSI を選ぶ。ghq の manifest は今は portable
  だけだが、MSI が足されても portable のままにするため同じく付ける
- MSI の fzf (手で `winget install junegunn.fzf` を打つと入る) が入っていると、portable と二重になり、winget の install と pin がどちらを指すかが
  決まらない。そのため `Install-Fzf` は何も入れずに止まり、`-Check` は 1 を返して外し方を出す (runner は知らせるだけ)。PowerShell で
  `winget uninstall --id junegunn.fzf --exact --scope machine` を打って外し (UAC の確認が出る)、`Install-Fzf` か `dotfiles apply --steps fzf` を
  打ち直す
- 入れ替えるときに置き場所の exe が動いている (別の端末の cdrepo の選ぶ画面・`ghq get` など) と、置き換えられないので何も変えずに止まり、
  PID とコマンドラインを出す。終わらせてから打ち直す
- PATH で別の ghq・fzf (scoop・`go install` のものなど) が先に引かれると、`-Check` の「PATH の ghq」「PATH の fzf」が ⚠ になる。揃える手順では
  直らないので、※ の行の手順でその置き場所を外す
- winget が portable の置き場所をユーザーの PATH に足すマシンと、`%LOCALAPPDATA%\Microsoft\WinGet\Links` に symlink を置くマシン (開発者
  モードなど) がある (ntn と同じく、どちらも winget のものとして読む)。fzf の 0.75.0 の release notes によると、Links の symlink は管理者の SSH の
  会話からは辿れない (PATH に足すマシンでは当たらない)

### ghq・fzf の新しい版が出たとき

固定した版より新しい版が winget に載って 30 日たつと、GitHub Actions の `winget-versions` の `Windows の ghq`・`Windows の fzf` の job が落ちて
知らせる。出た日は winget-pkgs に載った日 (どちらも GitHub に release を出すが、winget に載らない版がある (ghq は 1.9.x・1.10.0・1.11.x、fzf は
0.65.2・0.66.1) ので、GitHub とは比べない)。固定した版より新しい版の知らせ (runner の `pin-updates`。WSL の setup では、Windows の ghq に
dotfiles の clone があるマシンだけ) にも出る。猶予・落ちる場合・見送りの一覧は [winget の新しい版を確かめる](#winget-の新しい版を確かめる)。

上げるとき:

1. release notes で、cdrepo が使うもの (`ghq list`・`ghq root` の出力、fzf の `-1`・`+m` と選ぶ画面) と Windows に触る変更が無いかを見る。fzf は
   winget の manifest にまだ portable の zip があるか (`winget show --id junegunn.fzf --version <版> --installer-type portable`) も見る
2. `ghq/Install-Ghq.ps1`・`fzf/Install-Fzf.ps1` の `-Version` の既定値と、上の道具の表の版を新しい版にし、`Install-Ghq.Tests.ps1`・
   `Install-Fzf.Tests.ps1` を流して PR を出す (`winget-versions` が、書いた版が winget にあるかを確かめる)
3. merge したら、Windows で `dotfiles --self-update apply` (clone を進めてから流す。`--steps ghq,fzf` で絞れる) を流す (runner が揃える)。exe が動いていて止まったら、
   終わらせてから `Install-Ghq`・`Install-Fzf`
4. `-Check` が「揃っている」になり、`ghq --version`・`fzf --version` が新しい版を出すことを確かめる

見送るとき: `ghq/skipped-versions.txt`・`fzf/skipped-versions.txt` に「版 理由」を 1 行足して commit する。版を戻すときは `-Version` を前の版に
すれば、runner が下げる。

### Install-Ghq.ps1・Install-Fzf.ps1 を書くときの注意

- `dotfiles.ps1` と同じく **BOM 付きの UTF-8** で保存する
- 入口は道具の表 (`Get-GhqTool`・`Get-FzfTool`) だけを持ち、流れは共通の枠 ([WingetPortable.ps1 を書くときの注意](#wingetportableps1-を書くときの注意))
- 表の値 (版の拾い方・exe の置き場所・fzf の MSI) と、表を渡した流れは `ghq/Install-Ghq.Tests.ps1`・`fzf/Install-Fzf.Tests.ps1` で確かめる (Linux の pwsh):

  ```sh
  nix shell nixpkgs#powershell -c pwsh -NoProfile -File win/ghq/Install-Ghq.Tests.ps1
  nix shell nixpkgs#powershell -c pwsh -NoProfile -File win/fzf/Install-Fzf.Tests.ps1
  ```

- runner の `runner/src/steps/ps1.rs` は、終了コードと、状態の表の見出し (`ghq (winget の x-motemen.ghq`・`fzf (winget の junegunn.fzf`) と、
  締めの行の文言 (`→ Install-Ghq で入れる`・`→ Install-Ghq で揃える`・`→ ※ の手順で直す`・`昇格した PowerShell では winget が ghq を入れない`。fzf は
  `MSI の fzf (machine スコープ) が入っている` も) で分かれる。字は共通の枠が組む。変えるときは向こうも直す (WSL の wrapper は無いので、runner の試験が
  入口と枠の字を突き合わせる)
- winget やプロセスに触る本物の部分は、実機で `-Check` と本番を打って確かめる

## Tailscale

`tailscale/Install-Tailscale.ps1` は、Tailscale (VPN。Windows を tailnet に参加させる) を winget の `Tailscale.Tailscale` (machine スコープの
MSI。入れる・上げるときは Windows のデスクトップに UAC の確認と、進み具合の小さな窓が出る) で入れ、版を `-Version` の既定値 (今は `1.104.7`)
の 1 か所で固定する (dotfiles-private の ADR 069 (`docs/adr/069_win_tailscale_*`))。固定した版は新しく入れるときの版で、入れた後の更新は
Tailscale の自動更新に任せる ([Tailscale を入れる](#tailscale-を入れる-winget))。

- setup が入れるのは `dotfiles.wsl.windowsFiles.tailscale.enable = true` のマシンだけ。tailnet にログインして使う VPN の道具で、既定は
  グループ all の win/ を配るマシンだけ true (minimum では入れるホストが書く。[`nix/README.md` の「設定グループ」](../nix/README.md#設定グループ))。入れるホストは、
  dotfiles-private に登録したホストのファイルか、`~/dotfiles/flake.nix` に足したホストの `wsl` に書く:

  ```nix
  wsl = {
    windowsFiles.enable = true;
    windowsFiles.tailscale.enable = true;
  };
  ```

  Windows の runner では、ホストの値の `[tools]` に `windowsTailscale = true` を書く ([ホストの値](#ホストの値))
- false に戻しても setup は消さない (見なくなるだけ)。消すなら PowerShell で `winget pin remove --id Tailscale.Tailscale --exact` の後に
  `winget uninstall --id Tailscale.Tailscale --exact` を打つ (UAC の確認が出る)
- tailnet へのログイン (タスクトレイの Tailscale のアイコンからの Log in・`tailscale up`・auth key) と Tailscale の設定は dotfiles では扱わない。
  入れた後に、ユーザーが手でログインする
- 置き場所は `C:\Program Files\Tailscale\` (`tailscale.exe`・`tailscaled.exe`・`tailscale-ipn.exe`)。版は `tailscale.exe version` の 1 行目で読む
  (別の置き場所に入れていても、PATH で引ければ読む)

### Tailscale を入れる (winget)

| 打つもの | すること |
| --- | --- |
| `Install-Tailscale -Check` (PowerShell) | 差を出すだけ。揃っていれば (入っている版の方が新しいときも) 終了コード 0、差があれば 1、入っていなければ 3 |
| `Install-Tailscale` (PowerShell) | 揃える (入れる・古ければ上げる・pin を足す)。入っている版の方が新しければ下げない。入れる・上げるときは UAC の確認が出る |
| `nix/scripts/bootstrap-windows-tailscale.sh` (WSL) | `setup --update` でも毎回走る (order 96。`windowsFiles.tailscale.enable = true` のマシンだけ)。入っていなければ入れ (UAC の確認が出る)、古ければ ⚠ で囲んで知らせる (上げはしない) |
| `nix/scripts/bootstrap-windows-tailscale.sh --apply` (WSL) | WSL から揃える (確かめずに流す)。UAC の確認は Windows のデスクトップに出る |
| `nix/scripts/check-winget-version.sh tailscale` (WSL・CI) | 固定した版を winget の版の一覧と比べる。GitHub Actions の `winget-versions` が週 1 回流し、新しい版が winget に載って 30 日たつと落ちて知らせる ([後述](#tailscale-の新しい版が出たとき)) |

- winget の manifest は burn (exe の束) と wix (MSI) の 2 つの installer を並べるので、入れるときは `--installer-type wix` で MSI を名指しする
  (Tailscale の自動更新も MSI で上げる)
- `--silent` は付けない (winget の既定の `/passive` で、進み具合の小さな窓が出る)。per-machine の MSI は、管理者でない PowerShell から quiet
  (`--silent` → `/quiet`) で流すと UAC が出ずに落ちる ([bootstrap がすること](#bootstrap-がすること) の GitHub CLI と同じ)
- MSI は入れ終えると Tailscale の GUI を起こす (タスクトレイにアイコンが出る)。そこからログインする
- 入れた後に `winget pin add` で `winget upgrade --all` から外す。Tailscale の自動更新は止めない (pin は winget の中の印で、Tailscale の
  自動更新は自分で MSI を落として入れる)
- Tailscale は Windows で自分を更新する。既定は tailnet の管理画面の Settings → Device management の「Auto-update new devices」で決まり
  (2024-02 より後に作った tailnet は既定で on)、端末ごとには Tailscale のタスクトレイの Preferences → Automatically install updates で変えられる。
  自動更新はリリースのおよそ 1 週間後に届く。そのため、入っている版の方が新しいときは下げず、`-Check` は揃っている扱い (終了コード 0) にして
  ※ で添えるだけにする (setup も ⚠ を出さない)
- 古いとき (自動更新を切っている・repo の版を上げた) は ⚠ で知らせるが、setup は上げない (上げる間、Tailscale の接続が少しの間切れる。
  Tailscale 越しにこの PC へつないでいる接続も切れる)。自動更新を待つか、`Install-Tailscale` で上げる (upgrade は installer を名指しせず
  入っている形で上げ、`--include-pinned` を付ける。[winget の pin](#winget-の-pin))
- 入っていなくても、固定した版が winget に無い (`-Version` の書き間違いか、winget から消えた) ときは、setup は入れにいかず (UAC も出さず)、
  repo の版 (`-Version` の既定値) の直し方を出す。入っている版が読めないときは、確かめ方 (`winget list --id Tailscale.Tailscale`) を出す
- setup が待つ上限は、`-Check` が 120 秒、入れる `-IfMissing` が 600 秒。時間切れになったらそう出して先へ進む (setup は止めない)。
  入れるときに UAC の確認を押さないまま 600 秒たった場合は、⚠ で囲んで、手で打つコマンドも出す

### Tailscale の新しい版が出たとき

固定した版より新しい版が winget に載って 30 日たつと、GitHub Actions の `winget-versions` の `Windows の Tailscale` の job が落ちて知らせる。
出た日は winget-pkgs に載った日 (Tailscale は GitHub (`tailscale/tailscale`) に release を出すが、Windows の MSI を出さない版 (1.98.5・1.102.5) は
winget に載らないので、GitHub とは比べない)。猶予・落ちる場合・見送りの一覧は [winget の新しい版を確かめる](#winget-の新しい版を確かめる)。

固定した版は新しく入れるときの版なので、上げ遅れて困るのは新しいマシンだけ (入っている Tailscale は自動更新で上がる)。

上げるとき:

1. changelog (`https://tailscale.com/changelog`) で、Windows の installer・自動更新・ログインに触る変更が無いかを見る
2. `tailscale/Install-Tailscale.ps1` の `-Version` の既定値と、上の「今は」を新しい版にし、`Install-Tailscale.Tests.ps1` を流して PR を出す
   (`winget-versions` が、書いた版が winget にあるかを確かめる)
3. merge したら、各マシンで `setup --update` を流す。入っているマシンでは何も変わらない (古ければ ⚠ が出るので、自動更新を待つか
   `Install-Tailscale` で上げる)

見送るとき: `tailscale/skipped-versions.txt` に「版 理由」を 1 行足して commit する。

### Install-Tailscale.ps1 を書くときの注意

- `dotfiles.ps1` と同じく **BOM 付きの UTF-8** で保存する
- 副作用の無い関数 (版の読み方・探す場所・plan・winget の引数・状態の表) と、winget を偽物に差し替えた流れ (打つ winget の順・入れられない
  とき) は `tailscale/Install-Tailscale.Tests.ps1` で確かめる。Linux の pwsh で流すので Windows には触らない (このファイルは manifest に無いので
  配られない):

  ```sh
  nix shell nixpkgs#powershell -c pwsh -NoProfile -File win/tailscale/Install-Tailscale.Tests.ps1
  ```

- winget の引数 (`Get-WingetCommands`) の install には `--installer-type wix` を付け、`--silent` と `--include-pinned` は付けない。upgrade には
  `--include-pinned` を付ける ([winget の pin](#winget-の-pin))
- `bootstrap-windows-tailscale.sh` と runner の `runner/src/steps/ps1.rs` は、終了コードと、状態の表の見出し
  (`Tailscale (winget の Tailscale.Tailscale)`) と印 (`winget show --versions に無い`・`比べられない`) で分かれる。変えるときは向こうも直す。
  締めの行 (`⚠️ ` で始まる行) は、WSL の wrapper が枠に入れるときに落とす (下に出す揃えるコマンドと重なるので)
- tailnet へのログインの案内は、入れ終えたときに ps1 が 1 行出す (wrapper と runner は重ねて出さない)
- winget やファイルに触る本物の部分は、実機で `-Check` と本番を打って確かめる

## T3 Code

`t3-code/Install-T3Code.ps1` は、T3 Code (pingdotgg/t3code の desktop app。Claude Code などの会話を別の UI と端末から使う) を winget の
`T3Tools.T3Code` (user スコープの nullsoft。`%LOCALAPPDATA%\Programs\t3code`) で入れる。版は `Install-T3Code.ps1` の `-Version` の既定値 (今は 0.1.11) と、
Linux の `nix/pkgs/t3-code` の `version` の 2 か所で、同じ版にする。固定した版は新しく入れるときの版で、入れた後の更新は T3 Code の自動更新に任せる
(dotfiles-private の ADR 091 (`docs/adr/091_t3_code_opt_in_*`))。

- 入れるのは Windows の runner だけ (手順 `t3-code` と `t3-code-settings`。WSL の setup には無い)。minimum では既定で入れず、入れるホストは
  dotfiles-private のホストの値 (`win/hosts/<ユーザー>@<PC>.toml`) に書く:

  ```toml
  [tools]
  windowsT3Code = true
  windowsClaudeCode = true      # T3 Code の会話だけの Claude の設定を置く手順 claude-t3 の switch (minimum では既定で off)

  [t3Code]
  clearClaudeEntrypoint = true   # クレジットを使う間だけ (下の「CLAUDE_CODE_ENTRYPOINT」)
  ```

- `t3-code-settings` が合わせるもの (T3 Code も書くので、決めたキーだけ。値は repo の `nix/files/t3-code/managed-settings.json` の 1 か所で、Linux の setup と共有。
  `launchArgs` だけは Windows だけで、値はこの PC の置き先で決まる):

  | 所 | 値 |
  | --- | --- |
  | ユーザー環境変数 `T3CODE_TELEMETRY_ENABLED` | `false` (テレメトリを切る。ブラウザ版・モバイル版の relay tracing と T3 Connect の Publish agent activity は、これでは止まらない) |
  | `providerInstances.claudeAgent` の `driver`・`config.homePath` | `claudeAgent`・`~/.claude-t3` (T3 の Claude は `CLAUDE_CONFIG_DIR=~/.claude-t3` で動く。`config` のほかのキーは残す) |
  | `providerInstances.claudeAgent.config.launchArgs` (Launch arguments) | `claude-t3` が出す文 ([T3 Code の会話だけの設定](#t3-code-の会話だけの設定))。`claude-t3` の置き先に 2 つのファイルがそろっているときだけ書く (そろっていなければ今の値を残し、※ で知らせる)。書いた後、`settings.json` は T3 の会話を開き直すと、`CLAUDE.t3.md` は新しい会話から効く (同じ節) |
  | `providerInstances.claudeAgent.environment` の `CLAUDE_CODE_ENTRYPOINT` | `[t3Code] clearClaudeEntrypoint = true` なら空の値の要素 (ほかの要素は残す)。false なら外す |
  | `defaultModelSelection` | Claude の Opus 5.5 (`claude-opus-5-5`)・effort high |
  | `defaultThreadEnvMode` | `worktree` (新しいスレッドを新しい worktree で始める) |

  UI で変えても、次の `dotfiles apply` で戻る (dotfiles が持つキー)。書いたら T3 Code を開き直す (タスクトレイからも終える)

### T3 Code を入れる

| コマンド | すること |
| --- | --- |
| `dotfiles apply --steps t3-code,t3-code-settings` | 入っていなければ入れ (UAC は出ない)、環境変数と settings.json を合わせる。入っていれば上げない (古ければ知らせる)。Launch arguments は `claude-t3` が置いたファイルがあるときだけ書く (無ければ `--steps` に `claude-t3` も足す) |
| `Install-T3Code -Check` (PowerShell) | 固定した版との差を出すだけ |
| `Install-T3Code` (PowerShell) | 固定した版に揃える (上げるときは T3 Code を閉じてから。pin も足す) |

入れた後に手でするもの (dotfiles は扱わない。`dotfiles check` の `t3-code-settings` の行が、claude-t3 のログインが無ければ ※ で知らせる):

1. Claude のログイン: T3 の Settings → Providers → Claude からログインする (資格情報は `%USERPROFILE%\.claude-t3\` に入る)
2. T3 Connect: T3 の Settings から T3 のアカウントでサインインする (Linux のマシンの T3 とつなぐのに使う。Linux 側は
   nix/README.md の「T3 Code」の `t3 connect`)

- **Linux のマシンに、この app から ssh でつながない**。ssh 側が `t3 serve --host 127.0.0.1 --port 3773` を起こして Linux の `~/.t3/userdata` を
  握り、Linux の service (`t3code.service`) が `ServerAlreadyRunningError` で起きなくなる (T3 Connect は `Environment link: pending server startup` の
  まま)。Linux の T3 には T3 Connect でつなぐ。ssh でつないでしまったら、Linux で `t3 serve` を止めて `systemctl --user restart t3code`

### CLAUDE_CODE_ENTRYPOINT

T3 は Claude に `CLAUDE_CODE_ENTRYPOINT=t3-code` を渡す。claude-t3 のアカウントでクレジットを使う間は、これだと `Credit balance is too low` で止まる
(ターミナルの `claude-t3` は動く)。空にすると Claude からは `sdk-cli` に見えて通るので、`[t3Code] clearClaudeEntrypoint = true` で空の値を渡す。
クレジットの期限 (2026-11-25) の後は、ホストの値から外す (次の `dotfiles apply` が settings.json から要素を外す)。

### T3 Code の新しい版が出たとき

新しい版の知らせ (`pin-updates`・`winget-versions`) にはまだ載せていない。上げるときは、winget に載った版を `winget show --id T3Tools.T3Code --versions`
で見て、`Install-T3Code.ps1` の `-Version` の既定値と、Linux の `nix/pkgs/t3-code` の `version` と sha256 (GitHub の release の asset の digest) を同じ PR で
変える。`Install-T3Code.Tests.ps1` を流す:

```sh
nix shell nixpkgs#powershell -c pwsh -NoProfile -File win/t3-code/Install-T3Code.Tests.ps1
```

- `Install-T3Code.ps1` は副作用の無い関数 (版の読み方・Uninstall キーの選び方・plan・winget の引数・状態の表) を `Install-T3Code.Tests.ps1` で確かめる。
  入っている版は、winget の manifest の ProductCode (`e9197887-efb3-55e0-985e-d6d3b5dd594a`) の HKCU の Uninstall キーの `DisplayVersion` で読む
- runner の `runner/src/steps/ps1.rs` は、終了コードと、状態の表の見出し (`T3 Code (winget の T3Tools.T3Code)`) と印 (`winget show --versions に無い`・
  `比べられない`) で分かれる。変えるときは向こうも直す

## Claude Desktop

`claude-desktop/Install-ClaudeDesktop.ps1` は、Claude Desktop (Claude のデスクトップ版。Cowork (VM の中で動くエージェント) も使う) を winget の
`Anthropic.Claude` の MSIX で入れる。版は `-Version` の既定値 (今は `5.11492.5`) の 1 か所で固定する。固定した版は新しく入れるときの版で、入れた後の
更新は Claude Desktop の自動更新 (約 4 時間ごと) に任せる (dotfiles-private の ADR 099 (`docs/adr/099_win_claude_desktop_msix_*`))。

- 入れるのは Windows の runner だけ (手順 `claude-desktop`。WSL の setup には無い)。既定はグループ all だけ on (入れるときに UAC の確認が
  出る手順)。minimum のホストで入れるなら、dotfiles-private のホストの値 (`win/hosts/<ユーザー>@<PC>.toml`)
  に書く ([ホストの値](#ホストの値)):

  ```toml
  [tools]
  windowsClaudeDesktop = true
  ```

- winget の manifest は MSIX (x64・arm64) と旧来の exe (Squirrel。user スコープで `%LOCALAPPDATA%\AnthropicClaude` に入る) を並べ、winget は名指し
  しないと exe を選ぶ。Cowork は MSIX でしか動かないので、`--installer-type msix` で名指しする
- MSIX は Cowork の常駐 (`CoworkVMService`。localSystem で動く Windows のサービス) を持ち、Windows はそれを管理者の権限で入れたときだけ登録する
  (管理者の権限の無い登録は `0x80073D28` で断られる)。そこで ps1 は、winget を昇格した Windows PowerShell (System32 のもの) で流す。UAC の確認は入れる・
  上げるときの 1 回だけ (pin を足すだけなら出ない。昇格した会話から打てば出ない)。昇格した側の出力は受け取れないので、昇格した側が winget の出力を
  一時ファイル (`%TEMP%\dotfiles-claude-desktop-*.log`) に書いて winget の終了コードで終わり、ps1 がそのファイルを読んで出して消す
- MSIX は打ったユーザーに入る (UAC で昇格しても同じユーザー)。UAC の確認で別の管理者の資格情報を入れると、そのユーザーに入る (ps1 は入れた後に
  このユーザーの `Get-AppxPackage` に出なければ、そう ※ で知らせる)。この入れ方 (そのユーザーのまま昇格して入れる) で Cowork まで使うには、Claude を
  使うユーザーが管理者 (UAC で自分を昇格できる) であることが要る
- 入っている版は `Get-AppxPackage -Name Claude` の `Version` で読む (PackageFamilyName が `Claude_pzs8sxrjxfjjc` のもの)。MSIX の版は `5.11492.5.0` の
  4 つ組で、winget の版の末尾に `.0` を足したものなので、4 つ組にそろえて比べる。PowerShell 7 の Appx は読めないことがあるので、PowerShell 7 から打った
  ときは Windows PowerShell 5.1 に読ませる
- 入れた後に `winget pin add` で `winget upgrade --all` から外す (版は Claude Desktop の自動更新と `Install-ClaudeDesktop` で動かし、管理者の権限の無い
  `winget upgrade --all` に MSIX を上げさせない)。Claude Desktop の自動更新は止めない (`disableAutoUpdates` は書かない)
- `-Check` は Cowork の常駐の有無と状態 (`Get-Service CoworkVMService`)、仮想マシン プラットフォームの on・off (`Win32_OptionalFeature` の `InstallState`。
  管理者の権限は要らない) も出す。どちらも知らせるだけで、終了コードには数えない
- `-Check` は Claude の設定の「システムトレイ」と「スタートアップ時に実行」も見張り、on なら ⚠ と直し方を出して終了コードを 1 にする (設定は書き換え
  ない。[システムトレイとスタートアップ時に実行](#システムトレイとスタートアップ時に実行))
- false に戻しても runner は消さない (見なくなるだけ)。消すなら Claude を終えてから (☰ > File > Exit)、PowerShell で
  `winget pin remove --id Anthropic.Claude --exact` の後に `winget uninstall --id Anthropic.Claude --exact` を打つ

### Claude Desktop を入れる

| 打つもの | すること |
| --- | --- |
| `dotfiles apply --steps claude-desktop` | 入っていなければ MSIX を入れる (UAC の確認が 1 回出る。SSH の会話では出せないので、デスクトップの端末で流す)。入っていれば上げない (古ければ知らせる)。旧来の exe の Claude が残っていれば、入れずに外し方を出す。システムトレイ・スタートアップ時に実行が on なら ⚠ で知らせる (書き換えない) |
| `Install-ClaudeDesktop -Check` (PowerShell) | 固定した版との差を出すだけ。揃っていれば (入っている版の方が新しいときも) 終了コード 0、差があれば 1、入っていなければ 3。旧来の exe の Claude が残っていれば、入っていなくても 1。システムトレイかスタートアップ時に実行が on なら、版が揃っていても 1 |
| `Install-ClaudeDesktop` (PowerShell) | 揃える (入れる・古ければ上げる・pin を足す)。入れる・上げるときは UAC の確認が 1 回出る (上げるときは先に Claude を終える) |

入れた後に手でするもの (dotfiles は扱わない): スタートメニューの Claude を開いてサインインし、設定 > デスクトップアプリ の「システムトレイ」を off に
する (既定で on。off にするまで、`Install-ClaudeDesktop -Check` は終了コード 1 で、runner は入った扱いにして ⚠ の行を出す)。Cowork は Claude の中で
始める (初めて使うときに、Cowork の workspace (VM) を落とす)。

#### 旧来の exe の Claude

`claude.com/download` の `Claude Setup.exe` は、管理者の承認が無いと旧来の exe (Squirrel) で入れる。旧来の exe の Claude を開くと Cowork が無い。
ps1 は旧来の exe (`%LOCALAPPDATA%\AnthropicClaude\Update.exe` か、HKCU の Uninstall の `AnthropicClaude`) を見つけたら ⚠ の行と外し方を出し、終了コードを
1 にする (MSIX が入っていなくても 3 にしない)。外すのは人で、外すまで MSIX は入れない・上げない: winget は旧来の exe も manifest の ProductCode
(`AnthropicClaude`) で `Anthropic.Claude` と数え、入れる手を上げる手に切り替えるので、MSIX が入らないまま落ちる見込み (winget のソースを読んだ見立て。
実機では確かめていない)。runner は「旧来の exe の Claude が残っている」の行にし、UAC も出さない。外したら `dotfiles apply` (か `Install-ClaudeDesktop`) で
MSIX を入れる。外し方 (Anthropic の案内のとおり、管理者でない会話で):

1. Claude を終える (☰ > File > Exit)
2. 管理者でない PowerShell で `& "$env:LOCALAPPDATA\AnthropicClaude\Update.exe" --uninstall -s` を打つ
3. 終わったら `%LOCALAPPDATA%\AnthropicClaude` と、スタートメニューの `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Claude.lnk` を消す

MSIX を入れた後に旧来の exe を入れた PC などで、両方が入っていると、`winget pin add` が相手を決められないことがある。そのときは旧来の exe を外してから
`Install-ClaudeDesktop` を打ち直す。

#### 仮想マシン プラットフォーム

Cowork には Windows の仮想マシン プラットフォーム (`VirtualMachinePlatform`) も要る。on にするには Windows の再起動が要るので、runner は on にしない。
off なら ps1 が ※ の行で、runner が `·` の行 (終了コードに数えない) で知らせる。on にするには、管理者の PowerShell で
`Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -All` を打ち、Windows を再起動する (シャットダウンでなく再起動。高速
スタートアップでは仮想化の機能が起きないことがある)。

#### システムトレイとスタートアップ時に実行

Claude の設定 > デスクトップアプリ の「システムトレイ」(Claude をシステムトレイで実行し続ける) と「スタートアップ時に実行」(Windows にサインイン
したときに Claude を起こす) は off にしておく。システムトレイが on だと、窓を閉じても Claude は終わらずにトレイで動き続ける (開いていないつもりでも、
リモートから操作できるまま)。ps1 は MSIX が入っているときにこの 2 つを読み、on なら ⚠ の行と直し方 (その切り替えを off にする) を出して、版と pin が
揃っていても終了コードを 1 にする。runner も直すことがある行 (⚠) で知らせ、何も打たない。

- dotfiles は設定を書き換えない (システムトレイの値は、開いている Claude が自分で書き直すファイルにある)
- システムトレイ: `%LOCALAPPDATA%\Claude-Data\<PackageFamilyName の小文字>\claude_desktop_config.json` (`claude_pzs8sxrjxfjjc`) の
  `preferences.menuBarEnabled`。値もファイルも無ければ、Claude の既定の on として ⚠ にする (入れた直後は、Claude を開いてから off にする)。同じ folder の
  `config.json` (サインインの token を持つ) は読まない
- スタートアップ時に実行: MSIX の startup task `ClaudeStartup` の状態。
  `HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData\Claude_pzs8sxrjxfjjc\ClaudeStartup` の `State`
  (`StartupTaskState` と同じ数で、2 と 4 が on)。鍵か値が無ければ、manifest の既定の off
- 読めないとき (JSON が壊れている・知らない値・鍵が読めない) は「不明」と出して ⚠ にしない (runner は `·` の行で知らせる。Claude の設定画面で確かめる)
- 置き場 (設定のファイルの場所・startup task の TaskId と既定の off) は 5.11492.5 と 6.28899.6 の MSIX の manifest で、システムトレイの既定の on は
  6.28899.6 で確かめた。off にしたのに ⚠ が消えなければ、Claude の更新で置き場が変わったかもしれない (`-Check` の表の行を見る)

### Claude Desktop の新しい版が出たとき

新しい版の知らせ (`pin-updates`・`winget-versions`) には載せていない (T3 Code と同じ)。Claude Desktop は入れた後に自分で上がり (約 4 時間ごと)、
版がよく出る (公開 (winget の manifest の `ReleaseDate`) が 2026-10-23〜11-20 の版が 13) ので、固定した版が上げ遅れて困るのは新しく入れるマシンだけで、
それも入れた後すぐ自動更新で上がる。上げるときは、`winget show --id Anthropic.Claude --versions` に載った版のうち、公開から 7 日を過ぎた版を選び
(公開日は `winget show --id Anthropic.Claude --version <版>` の `Release Date`)、
`Install-ClaudeDesktop.ps1` の `-Version` の既定値と上の「今は」を変えて、`Install-ClaudeDesktop.Tests.ps1` を流す:

```sh
nix shell nixpkgs#powershell -c pwsh -NoProfile -File win/claude-desktop/Install-ClaudeDesktop.Tests.ps1
```

固定した版が winget から消えると、新しいマシンでは入れられない。そのときは ps1 が ⚠ の行と直し方を出し、runner も打たずに知らせる。

### Install-ClaudeDesktop.ps1 を書くときの注意

- `dotfiles.ps1` と同じく **BOM 付きの UTF-8** で保存する
- 副作用の無い関数 (版の読み方・`Get-AppxPackage` の行の読み方と選び方・plan・winget の引数・システムトレイとスタートアップ時に実行の読み方・状態の表・
  締めの行・昇格した側に渡す本文) は `Install-ClaudeDesktop.Tests.ps1` で確かめる。昇格した側に渡す本文は、偽の winget を置いて今の PowerShell で実際に流し、出力と終了コードを読めるかを
  確かめる (昇格はしない)。入れる流れ (`Invoke-InstallClaudeDesktop`) は、Windows に触る関数を同じ名前の偽物に差し替えて流し、打つ winget・昇格・締めの行・
  終了コードを確かめる。Linux の pwsh で流すので Windows には触らない (このファイルは manifest に無いので配られない)
- runner の `runner/src/steps/ps1.rs` は、終了コードと、状態の表の見出し (`Claude Desktop (winget の Anthropic.Claude`) と印 (`winget show --versions に無い`・
  `比べられない`・`UAC の確認を断った`・`旧来の exe の Claude が残っている`・`仮想マシン プラットフォーム (VirtualMachinePlatform) が off`・
  `Claude Desktop のシステムトレイが on`・`Claude Desktop のスタートアップ時に実行が on`・
  `システムトレイの設定 (claude_desktop_config.json の preferences.menuBarEnabled) が読めない`・
  `スタートアップ時に実行の状態 (startup task ClaudeStartup の State) が読めない`) で分かれる。変えるときは向こうも直す (runner の試験が、ps1 の
  コメントでない行にこれらの印があるかを突き合わせる)
- winget・Appx・サービス・レジストリ・UAC に触る本物の部分は、実機で `-Check` と本番を打って確かめる

## Codex CLI

`codex/Install-Codex.ps1` は、OpenAI の Codex CLI (コーディング エージェントの CLI) を winget の `OpenAI.Codex` (zip の中の portable。管理者無しで
`%LOCALAPPDATA%\Microsoft\WinGet\Packages` の下に入る) で入れ、版を `-Version` の既定値の 1 か所で固定する (dotfiles-private の ADR 118
(`docs/adr/118_codex_cli_*`))。Linux の Codex CLI は home-manager が nixpkgs の `codex` を入れる (`dotfiles.codex.enable`。版は nixpkgs の pin に従い、
Windows の版とは揃えない)。

| 道具 | winget の ID | 固定した版 (`-Version` の既定値) | 置き場所 (`%LOCALAPPDATA%\Microsoft\WinGet\` の下) |
| --- | --- | --- | --- |
| Codex CLI | `OpenAI.Codex` | `0.170.0` | 本体は `Packages\OpenAI.Codex_Microsoft.Winget.Source_8wekyb3d8bbwe\codex-x86_64-pc-windows-msvc.exe` (arm64 は `codex-aarch64-pc-windows-msvc.exe`。同じ所に helper の `codex-command-runner.exe`・`codex-windows-sandbox-setup.exe` と `codex-resources\`・`codex-path\rg.exe`)。`codex` の名前は `Links\codex.exe` (本体への symlink) か、置き場所の `codex.exe` (本体の hardlink。winget 1.30 から)。どちらも winget が置く ([次の節](#codex-と打てる形-winget-の-symlink-か-hardlink)) |

- 入れて揃えるのは Windows の runner の手順 `codex` (order 97。Windows にしか無い手順で、WSL の setup には無い)。minimum では既定で入れず、入れるホストは
  dotfiles-private のホストの値 (`win/hosts/<ユーザー>@<PC>.toml`) に書く (受け持ちが WSL のホストは、WSL の Nix の値にも `wsl.windowsFiles.codex.enable = true`
  を書く。新しい版の知らせが、それで決まる):

  ```toml
  [tools]
  windowsCodex = true
  ```

- ログイン (codex を起こして手でする) と設定 (`%USERPROFILE%\.codex`) は dotfiles では扱わない
- 入れた後は、新しい PowerShell を開くと `codex` と打てる (winget がユーザーの PATH に足すのは、これから開く PowerShell の分。herdr-app の中の端末なら
  herdr-app を上げ直してから)
- 消すなら PowerShell で、先にユーザーの環境変数 `Path` から `...\OpenAI.Codex_Microsoft.Winget.Source_8wekyb3d8bbwe\codex-path` の行
  (hardlink の形で `Install-Codex` が足したもの。[次の節](#codex-と打てる形-winget-の-symlink-か-hardlink)) を外し、`winget pin remove --id OpenAI.Codex --exact` の後に
  `winget uninstall --id OpenAI.Codex --exact` を打つ (昇格は要らない)。`codex-path` の行を残したまま uninstall すると、winget が置き場所の部分だけを
  抜いて `\codex-path` の行が残る (ドライブの直下を指すので、それも外す)。switch を off にしても runner は消さない

| 打つもの | すること |
| --- | --- |
| `Install-Codex -Check` (PowerShell) | 差を出すだけ。揃っていれば終了コード 0、差があれば 1、入っていなければ 3 (winget を打てない会話・入れても `codex` と打てない PC では、入っていなくても 1) |
| `Install-Codex` (PowerShell。昇格していないもの) | 揃える (入れる・入れ替える (上げる・下げる)・`codex` と打てる形の無い形を入れ直す・pin を足す・hardlink の形なら同梱の rg の置き場所を PATH に足す) |
| `dotfiles apply --steps codex` (PowerShell) | runner の手順で揃える (`windowsCodex` が on のホストだけ。入っていなければ入れ、版か pin か `codex` と打てる形か同梱の rg の PATH がずれていれば揃える。PATH のずれは知らせるだけ) |
| `nix/scripts/check-winget-version.sh codex` (WSL・CI) | 固定した版を winget の版の一覧と比べる。GitHub Actions の `winget-versions` が週 1 回流し、新しい版が winget に載って 30 日たつと落ちて知らせる ([後述](#codex-cli-の新しい版が出たとき)) |

揃えるときにすることは [ghq・fzf](#ghqfzf) と同じ ([winget の portable の道具](#winget-の-portable-の道具) の共通の枠。取得を確かめてから外して入れ、
pin を足し、読み直す。昇格した PowerShell では入れない)。違うのは、`codex` と打てる形と同梱の rg を見ること (次の節)。

### codex と打てる形 (winget の symlink か hardlink)

winget の portable は、`codex` という名前 (manifest の `PortableCommandAlias`) を次のどちらかの形で付ける (winget の `PortableFlow.cpp`・
`PortableInstaller.cpp`)。`Install-Codex` はどちらでも揃ったとみなす (dotfiles-private の ADR 120 (`docs/adr/120_codex_cli_without_uac_*`))。

| 形 | いつ | `codex` と打つと引かれるもの |
| --- | --- | --- |
| symlink | winget が symlink を作れるとき (開発者モードが on か、昇格した winget) | `WinGet\Links\codex.exe` (置き場所の本体への symlink) |
| hardlink | winget 1.30 から、symlink を作れないとき (昇格していない winget で、開発者モードが off)。winget は `Links` の代わりに置き場所をユーザーの PATH に足す | 置き場所の `codex.exe` (本体の hardlink。winget 1.30 は symlink を作れるときも置く) |

- winget は昇格せずに打つ (UAC の確認は出ない)。会社の PC (管理者のアカウント・開発者モードが off) では hardlink の形で入る。新しい PowerShell の
  `Get-Command codex` の Source は `%LOCALAPPDATA%\Microsoft\WinGet\Packages\OpenAI.Codex_Microsoft.Winget.Source_8wekyb3d8bbwe\codex.exe` になる
- winget 1.30 は、昇格した会話 (UAC で昇格した PowerShell・管理者として実行した端末) から user スコープの portable を入れる・外すのを
  `0x8A15007D` (「ユーザー スコープ内にインストールされたパッケージの管理者コンテキストからは許可されていません」) で断る。`Install-Codex` は
  昇格した会話で winget が 1.30 以降なら winget を打たずに止まり、昇格していない PowerShell で打ち直す手を出す (runner は知らせるだけ)
- winget 1.29 以前は hardlink を作らず、symlink を作れないと置き場所を PATH に足すだけにする (それでも「Command line alias added: codex」と出す)。
  置き場所の exe の名前は `codex-x86_64-pc-windows-msvc.exe` なので、その形では `codex` と打っても見つからない。昇格していない会話で開発者モードが
  off で winget が 1.29 以前なら、`Install-Codex` は入れずに止まり、`Install-WinGet` で winget を固定した版 (1.30 以降。[winget](#winget)) に上げるか
  開発者モードを on にする手を出す (runner は知らせるだけ。runner の `winget` は `codex` より先に流れるので、apply では先に上がる)。winget の版は `winget --version` で見る
- `codex` と打てる形の無い形で入っていれば (winget 1.29 以前で入れたなど)、`-Check` が「codex と打てない」と出し、`Install-Codex` が同じ版を外してから
  入れ直す。`WinGet\Links\codex.exe` がほかを指していても入れ直す (winget が消してから作り直す)
- 同梱の rg: codex は自分の置き場所の判定 (同梱の `codex-path\rg.exe` と `codex-resources` を使うか) を、実体の exe の名前が置き場所の
  `codex-package.json` の `entrypoint` と同じかで行う (codex の `codex-rs/install-context`)。symlink は実体へたどるので当たるが、hardlink の `codex.exe` は
  名前が違うので外れ、codex は rg を PATH から探す (`codex doctor` の search provider が bundled でなく system になる)。そこで PATH の `codex` が
  置き場所の `codex.exe` なら、`Install-Codex` が置き場所の `codex-path` をユーザーの PATH の末尾に足す (`-Check` の「同梱の rg」の行)。codex が
  子のシェルに渡す PATH にも入るので、codex の中の `rg` もそれを引く。`codex-resources` の中の voice は hardlink の形では使えない見込み
- `winget uninstall` は置き場所を PATH の文字列から部分一致で抜くので、`codex-path` の行を残したまま外すと、置き場所の部分だけが抜けて
  `\codex-path` (ドライブの直下。普通のユーザーもフォルダを作れるので、別のユーザーが置いた exe を引きうる) に化けて残る (テスト用の VM で見た)。
  `Install-Codex` は外す・入れ直す (入れ替え・relink) 前に自分の `codex-path` の行を外し、入れた後に足し直す。化けた行が残っていれば、`-Check` の
  「化けた PATH の行」が ⚠ になり、`Install-Codex` (runner の手順 `codex`) が取り除く
- sandbox の helper (`codex-command-runner.exe`・`codex-windows-sandbox-setup.exe`) と `codex-code-mode-host.exe` は、codex が exe の隣で探す。
  置き場所の直下にあるので、どちらの形でも見つかる
- 名前を替えた写しや `.cmd` の shim は自分では作らない (`.cmd` の shim は Ctrl+C で「バッチ ジョブを終了しますか」が出て、引数の引用符も崩れる)
- winget の manifest の依存 (`BurntSushi.ripgrep.MSVC`・`Microsoft.VCRedist.2015+.x64`) は入れない (`--skip-dependencies`)。codex の exe は VC++ の
  ランタイムを使わず (CRT を静的に持つ)、rg は同梱のもの (`codex-path\rg.exe`) を使う。VCRedist は machine に入るので、入れると開発者モードの PC でも
  UAC の確認が出る
- PATH で別の codex (npm の `@openai/codex` の `codex.cmd`・公式の install.ps1 の `%LOCALAPPDATA%\Programs\OpenAI\Codex\bin\codex.exe` など) が先に
  引かれると、`-Check` の「PATH の codex」が ⚠ になる。揃える手順では直らないので、※ の行の手順でその置き場所を外す
- 入れ替えるときに codex が動いている (別の端末の会話など) と、置き換えられないので何も変えずに止まり、PID とコマンドラインを出す。終わらせてから
  打ち直す
- fzf の 0.75.0 の release notes によると、`WinGet\Links` の symlink は管理者の SSH の会話からは辿れない (Codex CLI では確かめていない)

### Codex CLI の新しい版が出たとき

固定した版より新しい版が winget に載って 30 日たつと、GitHub Actions の `winget-versions` の `Windows の Codex CLI` の job が落ちて知らせる。出た日は
winget-pkgs に載った日 (GitHub の release には winget に載らない版 (0.35.0・0.43.0 など) があるので、GitHub とは比べない)。固定した版より新しい版の
知らせ (runner の `pin-updates`・WSL の setup では、`windowsFiles.codex.enable` のマシンだけ) にも出る。codex は数日おきに版を出すので、知らせはよく出る。
猶予・落ちる場合・見送りの一覧は [winget の新しい版を確かめる](#winget-の新しい版を確かめる)。

上げるとき:

1. release notes で、Windows に触る変更 (sandbox・helper・置き場所の形) が無いかを見る。winget-pkgs の manifest
   (`manifests/o/OpenAI/Codex/<版>/OpenAI.Codex.installer.yaml`) の x64 の `NestedInstallerFiles` に、`codex-x86_64-pc-windows-msvc.exe` の
   `PortableCommandAlias: codex` と helper の 2 つが残っているかも見る
2. `codex/Install-Codex.ps1` の `-Version` の既定値と、上の道具の表の版を新しい版 (公開から 7 日たったもの) にし、`Install-Codex.Tests.ps1` を流して PR を
   出す (`winget-versions` が、書いた版が winget にあるかを確かめる)
3. merge したら、Windows で `dotfiles --self-update apply --steps codex` (clone を進めてから流す) を流す。外してから入れ直す (UAC の確認は出ない。
   昇格していない PowerShell で流す)。codex が動いていて止まったら、終わらせてから `Install-Codex`
4. `-Check` が「揃っている」になり、新しい PowerShell で `codex --version` が新しい版を出し、`codex doctor` の search provider が bundled のままかを確かめる

見送るとき: `codex/skipped-versions.txt` に「版 理由」を 1 行足して commit する。版を戻すときは `-Version` を前の版にすれば、runner が下げる。

### Install-Codex.ps1 を書くときの注意

- `dotfiles.ps1` と同じく **BOM 付きの UTF-8** で保存する
- 入口は道具の表 (`Get-CodexTool`。置き場所の exe は CPU の名前で並べる) と、custom の関数 (`codex` と打てる形・同梱の rg・化けた `codex-path` の行・
  1.29 以前の winget の見張り・winget の前後で `codex-path` の行を外す・足す) を持ち、流れは共通の枠
  ([WingetPortable.ps1 を書くときの注意](#wingetportableps1-を書くときの注意))
- 表の値・custom の関数 (symlink と hardlink の見分け・入れ直すかの決め方・古い winget の見張り・同梱の rg の PATH・化けた行・表と締めの行に足す行) と、
  winget・PATH・プロセスを偽物に差し替えた流れは `codex/Install-Codex.Tests.ps1` で確かめる。昇格して winget を打つ道を足さない (試験が `RunAs` の
  無いことを確かめる)。Linux の pwsh で流す:

  ```sh
  nix shell nixpkgs#powershell -c pwsh -NoProfile -File win/codex/Install-Codex.Tests.ps1
  ```

- runner の `runner/src/steps/ps1.rs` は、終了コードと、状態の表の見出し (`Codex CLI (winget の OpenAI.Codex`) と、締めの行の文言
  (`→ Install-Codex で入れる`・`→ Install-Codex で揃える`・`→ ※ の手順で直す`) と印 (`昇格した PowerShell では winget が Codex CLI を入れない`・`winget が古く、codex と打てる形を作れない`) で分かれる。変えるときは
  向こうも直す (runner の試験が、入口と共通の枠の字を突き合わせる)
- winget・token (昇格の見分け)・PATH・プロセスに触る本物の部分は、実機で `-Check` と本番を打って確かめる

## sshd

`openssh/Install-Sshd.ps1` は、Windows に sshd (OpenSSH Server) を入れ、Tailscale (tailnet) と localhost からだけ、鍵でだけ SSH で入れるように
する (dotfiles-private の ADR 078 (`docs/adr/078_win_sshd_tailscale_*`))。iPhone の Herdr のアプリや hc (`hc machine add`) が、この PC の herdr-core に
SSH で直につなぐのに使う (Herdr のアプリは各マシンの herdr-core に SSH でつなぎ、Tailscale SSH のサーバーに Windows はなれない)。

- setup が入れるのは `dotfiles.wsl.windowsFiles.sshd.enable = true` のマシンだけ。PC に外から入る口を開ける。既定は
  グループ all の win/ を配るマシンだけ true (minimum では入れるホストが書く。[`nix/README.md` の「設定グループ」](../nix/README.md#設定グループ))。入る経路の Tailscale も入れる
  ([Tailscale](#tailscale))。sshd は dotfiles が固定した OpenSSH の MSI に足すので、OpenSSH を固定した版に入れ替える switch
  (`windowsFiles.openssh.enable`・runner の `windowsOpenssh`) も on にする ([OpenSSH](#openssh))。入れるホストは、dotfiles-private に登録したホストのファイルか、`~/dotfiles/flake.nix` に足したホストの `wsl` に書く
  (鍵の例は作り物。実機の鍵と IP は dotfiles-private に書く):

  ```nix
  wsl = {
    windowsFiles.enable = true;
    windowsFiles.openssh.enable = true;
    windowsFiles.tailscale.enable = true;
    windowsFiles.sshd.enable = true;
    # 入れる端末の公開鍵。authorized_keys の 1 行を 1 つの文字列で書く (null なら dotfiles は鍵を置かない。空の list なら 0 本で、誰も入れない)
    windowsFiles.sshd.authorizedKeys = [
      "from=\"100.64.0.1,fd7a:115c:a1e0::1\" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... phone (Herdr)"
    ];
  };
  ```

  Windows の runner では、ホストの値の `[tools]` に `windowsSshd = true` (と `windowsOpenssh = true`) を書き、受け持ちを runner に切り替えたホストでは鍵を `[sshd] authorizedKeys` に
  書く ([ホストの値](#ホストの値))
- sshd は、dotfiles が winget で固定した OpenSSH (`Install-OpenSSH.ps1` が入れる `C:\Program Files\OpenSSH`。[OpenSSH](#openssh)) の MSI に、Server の
  機能を足して入れる。Windows の機能 (System32) の OpenSSH Server とは二重にしない (入っていれば揃えずに止まり、外し方を出す)
- false に戻しても setup は消さない (見なくなるだけ)。止め方・消し方は[後述](#sshd-を止める外す)

### sshd で揃えるもの

| もの | 揃える形 |
| --- | --- |
| server | OpenSSH の MSI の Server の機能。入っている版と同じ版の MSI を `winget download` で取り直し (winget が manifest の sha256 と照らす)、`msiexec /i <MSI> ADDLOCAL=Client,Server` で足す (同じ ProductCode なので保守の install)。保守の install は、入れたときに登録した MSI の名前 (`HKLM:\SOFTWARE\Classes\Installer\Products\<詰めた ProductCode>\SourceList` の `PackageName`。winget で入れた版なら `OpenSSH-Win64-v<版>.msi`) で原本を探すので、`winget download` が別の名前で保存した MSI をその名前に写してから渡す (違う名前のままだと 1603 で落ちる)。落とした MSI の製品がこの PC に入っていない・`PackageName` が読めない・PackageCode が入れたときと違う (同じ版を作り直した MSI) ときは、msiexec を流さずに止まる。Windows Installer の手元の写しは cab が抜かれているので、ProductCode だけでは足せない。MSI は管理者と SYSTEM だけが読み書きできるディレクトリ (`C:\ProgramData\dotfiles-sshd-msi-<毎回新しい GUID>`) に落とし、msiexec の後に消す (利用者の権限で動くものが、msiexec の前に差し替えられない。名前を毎回新しくし、在る名前には作らないので、利用者が前もって置いたディレクトリやジャンクションも使わない) |
| `C:\ProgramData\ssh\sshd_config` | dotfiles が書く中身 (下の表)。違えば (先頭に BOM が付いているときも) `sshd_config.dotfiles-bak-<日時>` に退避し、一時ファイルから差し替える (書けずに消えたままにならない)。MSI は Server を足した時点で sshd を起こし、sshd は sshd_config が無ければ既定 (パスワードでも入れる) を写すので、server を足す前に書いておく |
| Windows Firewall | 拒否の規則を 3 つ置き (グループ `dotfiles (sshd)`。下の表)、22 番を許す受信の規則 (MSI が作る `OpenSSH SSH Server Preview (sshd)` など) を無効にする |
| `C:\ProgramData\ssh\administrators_authorized_keys` | 管理者のユーザーの鍵の置き場 (Win32-OpenSSH は管理者の鍵をユーザーの `.ssh` から読まない)。鍵の写し (下の「鍵の置き方」) があれば、その中身どおりに書く (写しに無い鍵は消す。元は `.dotfiles-bak-<日時>` に退避する)。写しが無ければ中身に触らず、ファイルが無ければ空で作る。どちらも、読み書きできるのを管理者と SYSTEM だけにする (Microsoft の文書の `icacls` と同じ形を、表示の言語によらない SID で書く) |
| サービス `sshd` | 自動で起こし、動かす。sshd_config を書き直したら起こし直す (つないでいる SSH が切れることがある) |

sshd_config の中身 (`Install-Sshd.ps1` の `Get-SshdConfigText`):

| 設定 | わけ |
| --- | --- |
| `PubkeyAuthentication yes`・`PasswordAuthentication no`・`KbdInteractiveAuthentication no`・`AuthenticationMethods publickey` | 鍵だけで入れる |
| `AllowUsers <ユーザー>` | 入れるのはホストの値の `[sshd] allowUsers` のユーザー (書いていなければ、スクリプトを流したユーザー (小文字)) だけ。接続元はここに書かず、下の `Match Address` で絞る (下の注)。最初の `Match` より前に書く (後ろに書くと Match の中に入る)。`allowUsers = []` なら代わりに `DenyUsers *` (引数の無い `AllowUsers` は sshd が起動しない) |
| `Match Address *,!100.64.0.0/10,!fd7a:115c:a1e0::/48,!127.0.0.1,!::1` の `DenyUsers *` | 入ってよい送り元 (ホストの値の `[sshd] allowFrom`。書いていなければ tailnet と localhost。左は既定の形) の外から来たら、誰も入れない。sshd はログインのたびに Match を当ててから AllowUsers・DenyUsers を見る。`Match Group administrators` より前に置く。`allowFrom = []` なら `Match Address *` (どこから来ても入れない) |
| `ListenAddress` は書かない | Tailscale の IP に縛ると、起動のときに Tailscale の IP がまだ無いと sshd が落ちる。入れる元は Match Address の DenyUsers と拒否の規則で絞る |
| `Match Group administrators` の `AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys` | Win32-OpenSSH の既定のまま (管理者の鍵は ProgramData から読む) |
| `Subsystem sftp sftp-server.exe` | 既定のまま (`hc machine add` が hc を入れるときの scp が使う) |

sshd が読むファイル (sshd_config・administrators_authorized_keys) のコメントは ASCII にする (sshd は設定を byte のまま読む。BOM も付けない)。

AllowUsers に `<ユーザー>@<CIDR>` を書かない: Win32-OpenSSH は sshd_config を読んだ後、`AllowUsers`・`DenyUsers`・`AllowGroups`・`DenyGroups` の語ごとに、
最初の `/` を `\` に替える (`domain/user` を `domain\user` と読むため。`PowerShell/openssh-portable` の `servconf.c` の `parse_server_config` の
`WINDOWS` の分岐)。`<ユーザー>@100.64.0.0/10` は `<ユーザー>@100.64.0.0\10` になって CIDR として読めず、文字のパターンとしても当たらないので、tailnet
からのログインを全部断る (Windows の `sshd -T` に `\10`・`\48` で出る。OpenSSH の Operational のログには `not allowed because not listed in AllowUsers`。
`/` の無い `127.0.0.1`・`::1` は当たる)。Linux の sshd は CIDR をそのまま読むので、Linux の `sshd -G` では見つからない。`Match Address` の CIDR は
この読み替えを通らないので、接続元はそこで絞る。鍵の行の `from="…"` も読み替えを通らない (sshd が鍵の行から直に読む)

拒否の規則 (どれも受信・拒否・すべてのプロファイル。block は allow より強いので、Tailscale が入れる許可 `Tailscale-In` (Tailscale の IP 宛てを
全ポートで許す) や、MSI が有効に戻す 22 番の許可があっても効く):

| 名前 (`Name`) | 拒否するもの | わけ |
| --- | --- | --- |
| `dotfiles-sshd-tailnet-tcp` | 宛先が tailnet のアドレス (100.64.0.0/10・fd7a:115c:a1e0::/48) の TCP のうち 22 番以外 | tailnet の ACL を誤っても (既定の allow all のままでも)、tailnet からは 22 番にしか届かない。Taildrop でこの PC へ送るのも止まる |
| `dotfiles-sshd-tailnet-udp` | 宛先が tailnet のアドレスの UDP (全ポート) | 同じ |
| `dotfiles-sshd-outside-tcp22` | 接続元が tailnet と localhost の外 (LAN・WSL・Hyper-V など) の TCP の 22 番 | MSI の許可は Private のネットワークの全部から 22 番を許し (家の Wi-Fi を Private にしていると LAN からも開く)、OpenSSH の修復や上げ直しのたびに有効へ戻る。拒否の規則なら作り直されても効く |

- 規則はアドレスで絞る (インターフェイスで絞らない)。Tailscale-In と同じく宛先のアドレスで決まり、Tailscale を入れる前から置ける
- tailnet から来る ICMP (ping) は止めない。この PC から出ていく通信の戻り (MagicDNS の答えなど) は、受信の規則に当たらない
- 規則が揃っているかは、アドレスを数の区間にそろえて比べる (Windows は 100.64.0.0/10 を 100.64.0.0/255.192.0.0 と返し、範囲をサブネットの形で返す
  こともある)。program・サービス・インターフェイスで絞られた規則は、sshd に効かないことがあるので揃っていない扱い
- 22 番を許す受信の規則のうち、無効にするのは sshd.exe の規則とポートが 22 番だけの規則。22 番とほかのポートを並べた手の規則は、ほかのポートまで
  閉じないよう残し、※ で添える (22 番は拒否の規則が止める)
- Windows Firewall を読めないときは「無い」と読まず、その行を ⚠ で「読めない (<落ちたコマンド>: <理由>)」にする。拒否の規則 (`Get-NetFirewallProfile`・
  `Get-NetFirewallRule`) と 22 番の許可 (COM の `HNetCfg.FwPolicy2`) は別に読むので、片方が落ちても、もう片方の行は出る
- 拒否の規則が効くのは Windows Firewall が有効なときだけ。3 つのプロファイルのどれかが無効か、グループ ポリシーがローカルの規則を止めている
  (`AllowLocalFirewallRules` が False) と、`Install-Sshd` は揃えずに止まる (有効にするのは人)

### 鍵の置き方

鍵の足し引きは、dotfiles-private のホストの値でする。端末の足し引きが dotfiles-private の PR に残る。書く所は Windows の受け持ちで違う:

| 受け持ち | 書く所 | 写しを置くもの |
| --- | --- | --- |
| WSL の setup | Nix の値の `dotfiles.wsl.windowsFiles.sshd.authorizedKeys` | WSL の `bootstrap-windows-sshd.sh` (`setup --update`) |
| runner | Windows のホストの値 (`win/hosts/<ユーザー>@<PC>.toml`) の `[sshd] authorizedKeys` ([ホストの値](#ホストの値)) | runner の手順 `sshd` (`dotfiles apply`) |

1. 端末で鍵を作る (iPhone の Herdr のアプリは、アプリの中で鍵を作って公開鍵を出す)
2. 公開鍵の行の先頭に `from="<端末の Tailscale の IP (IPv4 と IPv6 を , でつなぐ)>"` を付け、上の list に足して PR を出す (鍵が漏れても、
   その端末の IP からしか使えない。IP は Tailscale の管理画面か `tailscale status` で見る。CIDR の `/` は使わない)
3. merge したら、受け持ちが WSL なら `~/dotfiles/setup --update`、runner なら Windows で `dotfiles --self-update apply` (dotfiles-private の clone を進めてから
   流す。鍵だけなら `dotfiles --self-update apply --steps sshd`) を流す。Windows の `%LOCALAPPDATA%\dotfiles\sshd\authorized_keys` に写しが置かれ (中身が同じなら書かない)、
   `Install-Sshd -Check` が写しとの差を ⚠ で出す。写しの鍵は全部、※ の行にコメントと鍵の種類と指紋 (`ssh-keygen -l` と同じ `SHA256:…`) で出る
   (setup・runner の `-Check` は管理者でなく、今の鍵のファイルを読めないので、足す鍵と消す鍵には分けない。管理者の PowerShell の `-Check` は分けて出す)
4. ※ の行に覚えのない鍵が無いのを見てから、PowerShell の `Install-Sshd` (受け持ちが WSL なら `bootstrap-windows-sshd.sh --apply` でもよい) で揃える
   (UAC の確認が 1 回出る)。端末を失くしたら、その行を消して同じ手順を流し、Tailscale の管理画面からも端末を消す

- `dotfiles check` は、写しがホストの値と違えば `sshd` の手順に「鍵の写しが … → apply で置く」の行を出す (その下の sshd の行は、写しの今の中身で
  確かめた結果)。`dotfiles apply` は写しを置いてから `-Check` を流すので、鍵を足した後は「揃っていない → Install-Sshd」を出す (runner は揃えない)
- 写しの頭には、どちらが書いたかの行がある。runner は `# dotfiles-keys-from: runner` を書き、`Install-Sshd` はそれ (か runner が渡す `-KeysFrom`) で、
  鍵が 0 本・写しが無い・読めない行の案内を TOML の値と `dotfiles apply` にする (印の無い写しは Nix の値と setup。写しが無く `-KeysFrom` も無ければ両方を出す)

- 写しは利用者が書けるファイル (administrators_authorized_keys は管理者でないと書けないので、間に挟む)。sshd は写しを読まない
- `authorizedKeys` が null (既定。TOML では書かない) のホストでは写しを置かず (前に置いた写しは消す)、`Install-Sshd` は鍵の中身に触らない (鍵は管理者のメモ帳などで
  `administrators_authorized_keys` に手で書く。権限だけ揃える)
- 管理者でない PowerShell (setup・runner) の `-Check` は administrators_authorized_keys を読めないので、揃えたときに書いた中身の sha256 の記録
  (`%LOCALAPPDATA%\dotfiles\sshd\deployed.json`) と比べる。管理者の PowerShell で `Install-Sshd -Check` を打つと、中身そのものと比べる
- 鍵が 0 本でも揃っている扱い (※ で、誰も入れないと添える)。from= の無い鍵は ※ で本数を添える

### ユーザーと送り元

sshd_config の `AllowUsers` に書くユーザーと、入ってよい送り元 (`Match Address` の否定に並べる相手のアドレス) は、受け持ちが runner のホストでは
Windows のホストの値の `[sshd] allowUsers`・`allowFrom` に書く ([ホストの値](#ホストの値))。ホストごとの値なので、ユーザー名と端末の IP は
dotfiles-private にだけ置く。

| ホストの値 | `allowUsers` | `allowFrom` |
| --- | --- | --- |
| 書かない (null) | 既定: `Install-Sshd` を流したユーザー (小文字) | 既定: tailnet (`100.64.0.0/10`・`fd7a:115c:a1e0::/48`) と localhost (`127.0.0.1`・`::1`) |
| `[]` | 誰も入れない (`AllowUsers` の代わりに `DenyUsers *`) | どこからも入れない (`Match Address *`) |
| list | そのユーザーだけ (英小文字・数字・`. _ -` の名前) | そのアドレスからだけ (IPv4・IPv6 のアドレスか CIDR。CIDR は範囲の頭のアドレスで書く。長さは 32 と 128 まで) |

1. 値を書いて (鍵と同じく dotfiles-private の PR)、merge したら Windows で `dotfiles --self-update apply --steps sshd` (dotfiles-private の clone を進めてから流す) を流す。
   runner の手順 `sshd` が、鍵の写しの後に `%LOCALAPPDATA%\dotfiles\sshd\allow.json` へ写しを置き (中身が同じなら書かない。どちらも書かなければ
   消す)、`Install-Sshd -Check` が、写しの値で作る sshd_config との差を ⚠ で出す
2. `Install-Sshd -Check` は、使う値をいつも ※ の行に出す (`※ AllowUsers: alice (ホストの値)`・`※ 送り元: … (ホストの値に書いていない。既定: tailnet と
   localhost)`)。覚えのない値が無いかを見てから、PowerShell の `Install-Sshd` で揃える (UAC の確認が 1 回出る。sshd を起こし直す)。管理者で起動し直した
   子にも写しの場所を渡し、子は書いたユーザーと送り元をログに出す

- 写しは JSON (`version`・`note`・`allowUsers`・`allowFrom`。書かない欄は null)。runner だけが書き、`Install-Sshd` は手で打たれたときも既定で読む
  (引数で値を渡すだけにすると、手で打つ `Install-Sshd` が値を知らず、既定に書き戻す)。写しを手で書き換えて読めない値があると、`Install-Sshd` は揃えずに
  1 で止まり、読めない値と、ホストの値を直して `dotfiles apply` を流し直す締めの行を出す
- 既定と同じ値 (ユーザー 1 人と、既定の送り元を同じ並びで) を書いたときの sshd_config は、書かないときと 1 バイトも違わない (揃えたときの記録も同じ)。
  値を書かないホストから同じ値に移しても、`Install-Sshd` を流し直さずに済む
- 送り元の値は sshd_config の `Match Address` にだけ効き、拒否の規則 ([sshd で揃えるもの](#sshd-で揃えるもの) の表) には混ぜない。拒否の規則の `LocalAddress` は、この PC の側の tailnet の
  アドレス (送り元とは別の意味) で、`dotfiles-sshd-outside-tcp22` は tailnet と localhost の外から来る 22 番を止めたまま。送り元の値で絞れるのは
  tailnet と localhost の中で、外を含む値には ※ で「拒否の規則が止めるので、sshd に届かない」と添える
- 受け持ちが WSL の setup のホストは、ユーザーと送り元をホストの値で持たない (Nix の値には無い。`Install-Sshd` は既定で書く)。受け持ちを runner から
  WSL に戻したときは、WSL の `bootstrap-windows-sshd.sh` が残った写しを消す

### sshd を入れる・揃える

| 打つもの | すること |
| --- | --- |
| `Install-Sshd -Check` (PowerShell) | 差を出すだけ。揃っていれば終了コード 0、sshd が入っていなければ 3、ほかの差があれば (先に直すことがあって揃えられないときも) 1 |
| `Install-Sshd -IfMissing` (PowerShell) | sshd が入っていなければ入れて揃える (UAC の確認が 1 回出る)。入っていれば `-Check` と同じ |
| `Install-Sshd` (PowerShell) | 揃える (直すことがあるときだけ UAC の確認が 1 回出る) |
| `nix/scripts/bootstrap-windows-sshd.sh` (WSL) | `setup --update` でも毎回走る (order 96。`windowsFiles.sshd.enable = true` のマシンだけ)。鍵の写しを置き、受け持ちが runner だったときのユーザーと送り元の写しが残っていれば消してから `-Check` を流し、sshd が入っていなければ `-IfMissing` で入れて揃える (UAC の確認が出る。待つのは 600 秒まで)。入っていてずれていれば ⚠ で囲んで知らせる (揃えはしない) |
| `nix/scripts/bootstrap-windows-sshd.sh --apply` (WSL) | 鍵の写しを置いてから揃える。UAC の確認は Windows のデスクトップに出る |

- setup はずれを揃えない。揃えるには UAC の確認が要り (外の端末から setup を流すと、押す人がいないまま待つ)、sshd を起こし直すと、つないでいる SSH が
  切れることがあるため (runner も同じ)
- 揃える順は、拒否の規則 → sshd_config → 鍵 → server → 22 番の許可を無効にする → ssh-agent → サービス。MSI は Server を足した時点で sshd を起こし、
  22 番の許可も作るので、その前に拒否の規則と sshd_config と鍵を置く (sshd は最初から dotfiles の設定で起き、LAN からの 22 番は拒否の規則が止める)
- sshd_config は、書き換える前に作った中身を `sshd -t` で試す (`Invoke-SshdConfigTest`)。書くのと同じ中身の一時のファイルと、使い捨てのホストの鍵 (ed25519。
  `-h` で渡すので、sshd は既定のホストの鍵を読まず、ホストの鍵がまだ無い・読めないことを設定の誤りと取り違えない) を、管理者だけが書ける
  `%ProgramData%\ssh` に置き、試した後に消す (利用者が書ける TEMP などに置くと、試してから書くまでの間に差し替えられる)。断られたら書き換えず・起こし直さずに
  1 で止まり、`[管理者]` の行に sshd -t の出力を出す (今の sshd_config と sshd はそのまま)。sshd.exe がまだ無い (server を足す前) ときは試せないと出して書く。
  中身が今と同じなら試さない
- MSI を流すと ssh-agent のサービスが自動・実行中に戻りうるので、`Install-OpenSSH` と同じく停止・無効に戻す (1Password の agent と pipe を取り合う)
- 揃える前に人が直すこと (OpenSSH が無い・Windows の機能の OpenSSH Server がある・ユーザーと送り元の写しの読めない値・AllowUsers に書けない
  ユーザー名・鍵の写しの読めない行・拒否の規則が効かない Windows Firewall のプロファイル・サービスの無い `sshd.exe`) があれば、揃えずに 1 で止まり、
  締めの行と ※ で直し方を出す (setup と runner もその直し方を出す)
- SSH の会話の中 (`SSH_CONNECTION` がある) で揃えるときは、sshd を起こし直さない (起こし直すと会話ごと切れ、止めてから起こす間に落ちると sshd が
  止まったままになる)。書き直した sshd_config を効かせるには、PC の管理者の PowerShell で `Restart-Service sshd` を打つ
- 管理者で起動し直した子の思わぬ失敗も、親が `[管理者]` の行で出す (子の窓はすぐ閉じる)
- OpenSSH を上げる・下げるとき (`Install-OpenSSH`) は Server も一緒に入れ直す。上げ直した MSI は 22 番の受信の許可を有効に戻し、サービスを作り直す
  ので、終わったら `Install-Sshd` で揃える (その間も、LAN からの 22 番は拒否の規則が止める)。入れ替えると SSH の会話が切れるので、`Install-OpenSSH` は
  `sshd-session` (sshd の会話) も動いているものに数え、閉じるよう出して止まる (`-Force` で進む)

守れないこと (dotfiles-private の ADR 078):

- 配った `Install-Sshd.ps1` と鍵の写しは、利用者が書けるファイル。同じユーザーの権限で動く悪いコードは、UAC の確認より前にそれらを書き換えられる
  (repo のほかの `Install-*.ps1` と同じ形。UAC は守りの境ではない)。揃える前の ※ の行 (写しの鍵の全部) に、覚えのない鍵が無いかを見る
- 送り元のアドレスで絞っているので、100.64.0.0/10 を使う LAN (ISP の CGNAT の内側など) からは、拒否の規則と Match Address を通る。残る壁は鍵と `from=`

### Herdr のアプリと hc からつなぐ

- Windows の管理者のユーザーで SSH で入ると、その会話は昇格する (UAC の確認なしに管理者になる)。昇格した SSH の会話から herdr-core を起こすと、
  同じユーザーのデスクトップの会話をふさぎうるので、herdr-core は SSH からは起こさない。つなぐ前に、この PC で Herdr (herdr-app) を開いたままにして
  おく (か、ふつうのデスクトップの端末で `hc server start`)。スリープしているとつながらない
- 既定の shell (cmd.exe) のままでつながる。hc は Windows の相手に `cmd /d /c "if exist .\AppData\Local\Programs\herdr-core\herdr-core.exe (…)"` の形で、
  ホームからの相対パスで herdr-core を呼び、`hc connect` は sh・cmd・PowerShell で同じに読める形にしてある (`DefaultShell` を変えない)
- OpenSSH 10.4.0.0 は、SSH の会話の PATH にユーザーの PATH (HKCU) が入らない (Win32-OpenSSH の既知の不具合)。hc は PATH を使わないので当たらない。
  Herdr のアプリが `hc` を名前で呼んで見つからないと言うときは、これを疑う
- つなぐ先は、この PC の Tailscale の IP (か MagicDNS の名前) と Windows のユーザー名 (小文字)。Herdr のアプリは Tailscale の端末を候補に出す
- tailnet の ACL・古い端末の整理・端末の承認 (device approval) は Tailscale の管理画面でする (dotfiles では扱わない)

### sshd を止める・外す

- 止める: 管理者の PowerShell で `Stop-Service sshd` と `Set-Service sshd -StartupType Disabled` (switch を false にしてから。true のままだと
  `Install-Sshd -Check` が ⚠ を出す)
- 外す: 同じ版の MSI を `winget download --id Microsoft.OpenSSH.Preview --version <ssh.exe の版> --download-directory <場所>` で取り、管理者の
  PowerShell で `msiexec /i <MSI> REMOVE=Server /qn` を打つ。拒否の規則は `Remove-NetFirewallRule -Group 'dotfiles (sshd)'` で消す。
  `C:\ProgramData\ssh` (sshd_config・host の鍵・administrators_authorized_keys) は MSI の外なので残る

### Install-Sshd.ps1 を書くときの注意

- `dotfiles.ps1` と同じく **BOM 付きの UTF-8** で保存する
- 副作用の無い関数 (sshd_config の中身 (ユーザーと送り元を渡した形と、既定の値で前の中身と 1 バイトも違わないこと)・送り元の検め・ユーザーと送り元の
  写しの読み方と使う値の決め方・鍵の行の読み方と指紋・administrators_authorized_keys の中身・Windows Firewall のアドレスの区間と規則の比べ方・
  外のアドレスが tailnet と localhost のちょうど補集合か・効かないプロファイル・22 番を許す受信の規則の選び方・例外を 1 行にする形・鍵のファイルの権限・
  winget download と msiexec の引数・判定と状態の表) と、
  BOM の見分けと一時ファイルからの差し替えは `openssh/Install-Sshd.Tests.ps1` で確かめる。Linux の pwsh で流すので
  Windows には触らない。PATH に sshd があれば、作る sshd_config を `sshd -G` で読ませ、Match Address の CIDR の書き方の誤り (sshd が起動しなくなる) を
  ここで見つけ、使い捨ての host 鍵で `sshd -T -C` を流して、どこから来たときに `DenyUsers *` が付くかを見る (Match Address の照らし方は Windows の
  sshd も同じ)。書き換える前の試し (`Invoke-SshdConfigTest`) も本物の sshd で流し、作った中身が通り、改行で割れた中身が断られることを見る。Win32-OpenSSH が AllowUsers の `/` を `\` に替えることは Linux の sshd で再現しないので、AllowUsers などの語に `/` が無いことを別に
  見る (CI は `nixpkgs#openssh` を足して流す):

  ```sh
  nix shell nixpkgs#powershell nixpkgs#openssh -c pwsh -NoProfile -File win/openssh/Install-Sshd.Tests.ps1
  ```

- 外から読んだ値 (ユーザーと送り元の写しの JSON・レジストリ・MSI) を検める正規表現は、`$` でなく `\z` で終える (.NET の `$` は末尾の改行の前でも
  当たる。写しの JSON に `"alice\n"` と書くと `$` で終える検めは通し、sshd_config の行が割れて sshd が起動しなくなる)。runner の検め (`runner/src/host.rs`) と
  同じ例 (末尾の改行) を両方の試験に置く
- `bootstrap-windows-sshd.sh` と runner の `runner/src/steps/ps1.rs` は、終了コードと、状態の表の見出し (`sshd (OpenSSH Server`) と、締めの行の文言
  (`→ Install-Sshd で揃える`・`→ Install-Sshd -IfMissing で入れる`・揃える前に人が直すことの文言) で分かれる。変えるときは向こうも直す
- Herdr を開いたままにする案内は、入れ終えたときに ps1 が 1 行出す (wrapper と runner は重ねて出さない)
- 管理者でない PowerShell (setup・runner の `-Check`) では、`Get-NetFirewallPortFilter -All` が PermissionDenied で落ちる (`Get-NetFirewallProfile`・
  `Get-NetFirewallRule -Name`・規則からパイプで引く filter は通る)。22 番を許す受信の規則は COM (`HNetCfg.FwPolicy2` の `Rules`) で読み、無効にするのも
  COM の規則の `Enabled` で書く (COM の規則は `Get-NetFirewallRule` の `Name` を持たない)。規則ごとに `Get-NetFirewallPortFilter` を引く形は、管理者で
  なくても通るが、有効な受信の許可に絞っても 10 秒を超え、毎回の setup に乗る
- サービス・ファイル・権限・Windows Firewall・winget・msiexec に触る本物の部分は、実機で `-Check` と本番を打って確かめる
