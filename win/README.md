# win/

Windows 側のアプリの設定を置く場所。WSL から `/mnt/c` 越しにコピーして配る
(経緯は [ADR 010](../docs/adr/010_win_files_from_wsl_20260928T003933JST/README.md))。

| ファイル | 置き先 (Windows) | 中身 |
| --- | --- | --- |
| `orca/keybindings.json` | `%USERPROFILE%\.orca\keybindings.json` | Orca のキーバインド ([TKT-25](https://app.notion.com/p/Orca-worktree-Ctrl-Alt-Ctrl-Ctrl-W-3e779149a66f8177809ac8632bf68b2c)) |
| `powershell/dotfiles.ps1` | `%USERPROFILE%\.config\powershell\dotfiles.ps1` | PowerShell の共有設定 (herdr と Claude Code の alias、`e` = `exit`)。`$PROFILE` から読む ([後述](#powershell)、[TKT-77](https://app.notion.com/p/PowerShell-profile-dotfiles-win-herdr-alias-h-hss-hls-Windows-3ef79149a66f817abc28dd3fa5241903)) |
| `herdr/config.toml` | `%APPDATA%\herdr\config.toml` | Windows の herdr の設定。キーバインドは WSL と同じ ([後述](#herdr)、[TKT-92](https://app.notion.com/p/herdr-Windows-win-herdr-config-toml-3f079149a66f819fb49ef2d13e6a76f5)) |
| `openssh/Install-OpenSSH.ps1` | `%USERPROFILE%\.config\powershell\Install-OpenSSH.ps1` | Windows の OpenSSH を winget で固定した版に揃える。PowerShell の `Install-OpenSSH` から呼ぶ ([後述](#openssh)、[TKT-109](https://app.notion.com/p/winget-Windows-OpenSSH-win-3f179149a66f812fba25c6b2d6ce5d31)) |
| `herdr/Install-Herdr.ps1` | `%USERPROFILE%\.config\powershell\Install-Herdr.ps1` | Windows の herdr を winget で固定した版に揃える。PowerShell の `Install-Herdr` から呼ぶ ([後述](#herdr-を入れる-winget)、[TKT-112](https://app.notion.com/p/winget-Windows-herdr-Herdr-Herdr-Preview-dotfiles-3f179149a66f81858e0cf4555c9c598f)) |
| `powertoys/keyboard-manager/default.json` | `%LOCALAPPDATA%\Microsoft\PowerToys\Keyboard Manager\default.json` | PowerToys の Keyboard Manager の割り当て (CapsLock → F13 など)。エンジンが読む ([後述](#powertoys)、[TKT-139](https://app.notion.com/p/Windows-Google-dotfiles-win-3f679149a66f81b1a592d85d7300a62b)) |
| `powertoys/keyboard-manager/editorSettings.json` | `%LOCALAPPDATA%\Microsoft\PowerToys\Keyboard Manager\editorSettings.json` | Keyboard Manager の新しいエディタが持つ割り当ての一覧 ([後述](#powertoys)) |
| `powertoys/Install-PowerToys.ps1` | `%USERPROFILE%\.config\powershell\Install-PowerToys.ps1` | Windows の PowerToys が入っていなければ winget で入れる。PowerShell の `Install-PowerToys` から呼ぶ ([後述](#powertoys-を入れる-winget)、[TKT-143](https://app.notion.com/p/winget-Windows-Google-PowerToys-Google-dotfiles-3f779149a66f817a8944c9e4e460383f)) |
| `google-japanese-input/` | `%USERPROFILE%\AppData\LocalLow\Google\Google Japanese Input\` | Google 日本語入力の設定とキー設定のテキスト (`config.txtpb`・`keymap.tsv`)。manifest では配らず、組み立てて配る ([後述](#google-日本語入力)、[TKT-139](https://app.notion.com/p/Windows-Google-dotfiles-win-3f679149a66f81b1a592d85d7300a62b)) |
| `google-japanese-input/Install-GoogleJapaneseInput.ps1` | `%USERPROFILE%\.config\powershell\Install-GoogleJapaneseInput.ps1` | Windows の Google 日本語入力を winget で固定した版に揃える。PowerShell の `Install-GoogleJapaneseInput` から呼ぶ ([後述](#google-日本語入力を入れる-winget)、[TKT-143](https://app.notion.com/p/winget-Windows-Google-PowerToys-Google-dotfiles-3f779149a66f817a8944c9e4e460383f)) |
| (dotfiles-private の `ssh/*.ssh_config`) | `%USERPROFILE%\.ssh\config` と `config.d\` | ssh の接続先。manifest では配らず、`bootstrap-windows-ssh-config.sh` がコピーする ([後述](#ssh-の設定)、[TKT-145](https://app.notion.com/p/Windows-OS-Windows-ssh-3f779149a66f81c4a2cff0233027c26e)) |

## 配る

WSL で流す。`home-manager switch` だけでは Windows 側に届かない。

```sh
~/dotfiles/setup --update                          # switch + bootstrap をまとめて
nix/scripts/bootstrap-windows-files.sh             # 配る部分だけ (この checkout の win/ を配る)
nix/scripts/bootstrap-windows-files.sh --dry-run   # 判定だけ見る
```

- 配るのは `dotfiles.wsl.windowsFiles.enable = true` のマシンだけ (登録簿では `pollenjp@wsl`)
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
- 書けるキーは `src` / `dst` / `hint` だけ。`..` と `\` は書けない
- 大文字小文字だけが違う `dst` は重複として止まる (Windows では同じファイル)
- 今の設定をそのまま取り込んだなら、1 回目は「同じです」になり記録だけが作られる
- manifest から消したファイルは Windows 側から消さない

## 衝突したら

Windows 側でファイルが変わっていた (アプリの設定画面で変えた、など) と、上書きせずに
diff を出して止まる。`setup --update` はこの手順 (order 90) で失敗して止まる。前の手順は済んで
いるが、後ろの bootstrap (91〜98) と exe-exec-trace、最後の「残りの手作業」は、直して流し直す
まで走らない。

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
| `c` | `claude --remote-control --dangerously-skip-permissions --effort max --model claude-opus-5-5` (Claude Code。Remote Control を有効にして起動する) |

叩くのは Windows に入れた `herdr.exe` (WinGet の `Herdr.Herdr.Preview`) で、WSL の herdr とは
別の server (session を共有しない)。`c` も Windows に入れた `claude.exe` (この PC では WinGet の
`Anthropic.ClaudeCode`) を叩く。`claude.exe` は dotfiles からは入れていない。

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

`herdr/config.toml` は Windows の herdr (WinGet の `Herdr.Herdr.Preview`) の設定で、
`%APPDATA%\herdr\config.toml` へ配る。キーバインドは WSL の herdr
(`nix/files/herdr/config.toml`) と同じにしてあり、キーごとの意図はそちらのコメントにある。

- `[keys]` と `onboarding` は WSL 側と同じに保つ。CI の lint が 2 つを比べ、違えば落ちる。
  手元でも確かめられる:

  ```sh
  nix/scripts/check-herdr-keys.sh   # 「WSL と Windows で同じ (13 個)」と出れば揃っている
  ```

- WSL 側との違いは 2 つ。`[terminal]` を書かない (WSL 側の `default_shell = "fish"` は
  Windows に無い。空のままなら、Windows の herdr は PATH の `pwsh.exe` (PowerShell 7) を使い、
  無ければ `powershell.exe` (5.1) を使う。pwsh 7 なら上の alias も pane の中で使える)。
  `[update] version_check = false` で新しい版の通知を止める ([herdr を入れる](#herdr-を入れる-winget))
- 配った後は、herdr の中で prefix + shift + r (外からなら PowerShell で `hreload`) で読み直す
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

Windows の herdr は winget の `Herdr.Herdr.Preview` (portable の zip。管理者は要らない) で入れ、
版を `herdr/Install-Herdr.ps1` の `-Version` の既定値 (今は `0.9.2-preview.2026-09-29-8e78f929d8f0`)
の 1 か所で固定する。winget に安定版のパッケージは無いので preview になる。

| 打つもの | すること |
| --- | --- |
| `Install-Herdr -Check` (PowerShell) | 差を出すだけ。揃っていれば終了コード 0、差があれば 1、入っていなければ 3 |
| `Install-Herdr` (PowerShell) | 揃える (入れる・入れ替える・pin を足す) |
| `nix/scripts/bootstrap-windows-herdr.sh` (WSL) | `setup --update` でも毎回走る。入っていなければ入れ、差があれば ⚠ で囲んで知らせる (入れ替えはしない) |
| `nix/scripts/bootstrap-windows-herdr.sh --apply` (WSL) | WSL から揃える |

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
- `herdr update` は打たない。herdr 自身の installer が
  `%USERPROFILE%\.herdr\packages\standalone\releases\<版>-<target>` に別に入れ、そのディレクトリを
  ユーザーの PATH の先頭に足すので、winget の herdr が引かれなくなる。新しい版の通知は
  `herdr/config.toml` の `[update] version_check = false` で止めてある。打ってしまったら
  (`-Check` の「PATH の herdr」が ⚠ になり、外すディレクトリが ※ の行に出る)、そのディレクトリを
  ユーザーの PATH から外し、`%USERPROFILE%\.herdr\packages` と `%LOCALAPPDATA%\Programs\Herdr` を消す。
  `Install-Herdr` は PATH を直さない
- 入れ替えの途中で `winget install` が落ちると、herdr が入っていない状態で止まることがある
  (取得は先に確かめてあるので稀)。そのときは `Install-Herdr` を打ち直す (`setup --update` でも入る)
- 版を変えるときは、`-Version` の既定値を変えて commit し、`setup --update` で配る (差が ⚠ で出る)。
  そのあと `Install-Herdr` か `--apply` で揃える。新しい preview が出たかは `-Check` の ※ の行で分かる
- 新しいマシンでは `setup --update` が入れる。依存の VCRedist が無いマシンでは、winget が入れるときに
  Windows に UAC が出る

### Install-Herdr.ps1 を書くときの注意

- `dotfiles.ps1` と同じく **BOM 付きの UTF-8** で保存する
- 副作用の無い関数 (版の読み方・並び・plan・winget の引数・PATH の解決・状態の表) は
  `herdr/Install-Herdr.Tests.ps1` で確かめる。Linux の pwsh で流すので Windows には触らない
  (このファイルは manifest に無いので配られない):

  ```sh
  nix shell nixpkgs#powershell -c pwsh -NoProfile -File win/herdr/Install-Herdr.Tests.ps1
  ```

- winget やプロセスに触る部分は、実機で `-Check` と本番を打って確かめる

## OpenSSH

WSL の `ssh` は Windows の `ssh.exe` (`C:\Program Files\OpenSSH`) を呼んで 1Password の agent に
つなぐ ([ADR 004](../docs/adr/004_nix_wsl_ssh_wrapper_20260811T124616JST/README.md))。その OpenSSH の版を、
winget の `Microsoft.OpenSSH.Preview` で固定する。固定する版は
`openssh/Install-OpenSSH.ps1` の `-Version` の既定値 (今は `10.0.0.0`) の 1 か所だけに書く。

| 打つもの | すること |
| --- | --- |
| `Install-OpenSSH -Check` (PowerShell) | 差を出すだけ。管理者は要らない。揃っていれば終了コード 0、差があれば 1 |
| `Install-OpenSSH` (PowerShell) | 揃える。直すことがあるときだけ UAC が 1 回出る |
| `nix/scripts/bootstrap-windows-openssh.sh` (WSL) | `setup --update` でも毎回走る。`-Check` を流し、差があれば ⚠ で囲んで知らせる (揃えはしない) |
| `nix/scripts/bootstrap-windows-openssh.sh --apply` (WSL) | WSL から揃える。UAC は Windows のデスクトップに出る |
| `nix/scripts/check-windows-openssh-version.sh` (WSL・CI) | 固定した版を winget の版の一覧と比べる。GitHub Actions の `windows-openssh` が週 1 回流し、新しい版が GitHub に出て 30 日たつと落ちて知らせる ([後述](#openssh-の新しい版が出たとき)) |

揃えるときにすること:

1. 入っている版 (`ssh.exe` の FileVersion) と固定した版を比べ、`winget upgrade` か `install` に
   `--version` を付けて揃える。下げるときは MSI が「新しい版が入っている」で止めるので、先に `uninstall` する。
   どれにも `--custom ADDLOCAL=Client` を付け、sshd は入れない
2. ssh-agent サービスを停止・無効に戻す。MSI の更新は ssh-agent を「自動・実行中」で作り直し、1Password と
   `\\.\pipe\openssh-ssh-agent` を取り合う ([Win32-OpenSSH#2057](https://github.com/PowerShell/Win32-OpenSSH/issues/2057))。
   ssh-agent はクライアント側の部品でもあるので、`ADDLOCAL=Client` でも入る
3. `winget pin add` で `winget upgrade --all` から外す (名指しの `winget upgrade --id …` は通る)
4. 読み直して、版・ssh-agent・pin と、`ssh-add -l` で 1Password の鍵が見えるかを確かめる

- 入れ替えるときに `ssh.exe` などが動いていると、閉じるよう出して止まる (`-Force` で進む)。
  使用中のファイルは再起動まで置き換わらないことがある
- 終わったら WSL で `ssh.exe -V` と `ssh-add -l` を確かめる。鍵が見えなければ、1Password をトレイから
  終了して起動し直す
- 版を変える・新しい版を見送るときは、次の「OpenSSH の新しい版が出たとき」の手順で
- 手元でも、`-Check` の「winget の最新版」と ※ の行で新しい版が出たことが分かる (`setup --update` で流したときだけ)

### OpenSSH の新しい版が出たとき

固定した版より新しい版が GitHub に出て 30 日たつと、GitHub Actions の `windows-openssh`
([`.github/workflows/windows-openssh.yml`](../.github/workflows/windows-openssh.yml)) が落ちて知らせる
([TKT-110](https://app.notion.com/p/Windows-OpenSSH-Win32-OpenSSH-3f179149a66f81eaa691e12ef3e0b86c))。
週 1 回 (月曜の朝) と、固定した版や見送りの一覧を変える PR で走り、落ちた定期実行の通知は
`nix.yml` の closure-scan と同じく GitHub から届く。

- 確かめるのは `nix/scripts/check-windows-openssh-version.sh`。`Install-OpenSSH.ps1` から固定した版と
  パッケージ ID (`$packageId`) を読み、winget-pkgs (`manifests/m/Microsoft/OpenSSH/Preview/<版>/`) と
  GitHub の release を GitHub API で読むので、Windows は要らない。手元で打つなら gh のログインが要る
- 新しい版は、GitHub に出てから 30 日 (猶予) は落とさずに待つ。待つ間は、実行の画面に notice
  (版・出た日・あと何日で知らせるか) が出る。summary にも ※ の行で出る
  - 追いついていない版がいくつかあるときは、いちばん早く出た版の日から数える。遅れ始めてから 30 日で知らせ、
    新しい版が続けて出ても先送りしない
  - 見送った版は数えない。猶予の中に上げるか見送るかを決めておけば、落ちずに済む
  - 30 日は script の先頭の `grace_days` の 1 か所で決める
- 猶予がたって落ちる (exit 1) のは:
  - 固定した版より新しい版が winget にある (見送りの一覧に無いもの) → 下の「上げるとき」か「見送るとき」。
    その版に合う GitHub の release が無く、出た日が分からないときは、待たずに落ちる
  - GitHub に出た版が winget のこのパッケージに無い (パッケージ ID が移ると、古い ID には新しい版が来ない。
    2024-10 に Preview ができてから、Beta には新しい版が来なかった) → 下の「パッケージ ID を確かめる」
- 猶予を置かずに落ちる (exit 1) のは、新しい版の知らせではなく、壊れていることの知らせ:
  - 固定した版が winget に無い (新しいマシンで入れられない) → winget にある版を選び直す
  - パッケージが winget に無い (`Microsoft.OpenSSH.Beta` は 2025-04-09 に全部の版が外された)
    → 下の「パッケージ ID を確かめる」
  - 版の形でないディレクトリがある・GitHub の最新 release に `OpenSSH-Win64-v<版>.msi` が無い
    (版や名前の付け方が変わった) → script の読み方を直す
- パッケージ ID を確かめる: `winget search OpenSSH` で今のパッケージ ID を確かめる。移るなら
  `git grep Microsoft.OpenSSH.Preview` で出る所 (`Install-OpenSSH.ps1` の `$packageId` と状態の表の見出し・
  `bootstrap-windows-openssh.sh` の見分け・テスト) と固定した版を直す
- 確かめられずに落ちる (exit 2) のは、GitHub API の失敗・`Install-OpenSSH.ps1` から版か ID が読めない・
  見送りの一覧の書き損じ。GitHub の release の一覧だけが取れないときも、新しい版が猶予の中かを決められないので
  exit 2 になる。summary の `!!` の行を見て、一時的な失敗なら流し直し、書き損じなら直す
- GitHub の release から winget に載るまでは、これまで 5 時間〜4 日だった
- 猶予がたった新しい版がある間は、別の理由で `Install-OpenSSH.ps1` や script を直す PR も赤くなる
  (merge は止まらない)

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
   `Install-OpenSSH.Tests.ps1` を流して PR を出す (`windows-openssh` が、書いた版が winget にあるかを確かめる)
5. merge したら、各マシンで `setup --update` を流す (差が ⚠ で出る)。Windows で動いている `ssh.exe`
   (herdr の remote など) を閉じてから、`Install-OpenSSH` か `bootstrap-windows-openssh.sh --apply` で揃える
   (UAC が 1 回出る)
6. WSL で `ssh.exe -V`・`ssh-add -l`・GitHub への ssh を確かめる。鍵が見えなければ、1Password を
   トレイから終了して起動し直す

見送るとき (2・3 で合わないと分かったとき):

- `openssh/skipped-versions.txt` に「版 理由」を 1 行足して commit する。その版では落ちなくなり、
  もっと新しい版が出ると、その版が GitHub に出てから 30 日でまた落ちる。このファイルは manifest に無いので
  Windows へは配らない
- 固定した版以下になった行は消してよい (job が「消してよい」と出す)
- `-Check` の ※ の行は見送っても出続ける (winget に新しい版があるのは事実なので)

### Install-OpenSSH.ps1 を書くときの注意

- `dotfiles.ps1` と同じく **BOM 付きの UTF-8** で保存する
- 副作用の無い関数 (版の比べ方・winget の出力の読み方・winget の引数・状態の表) は
  `openssh/Install-OpenSSH.Tests.ps1` で確かめる。Linux の pwsh で流すので Windows には触らない
  (このファイルは manifest に無いので配られない):

  ```sh
  nix shell nixpkgs#powershell -c pwsh -NoProfile -File win/openssh/Install-OpenSSH.Tests.ps1
  ```

- winget やサービスに触る部分は、実機で `-Check` と本番を打って確かめる

## ssh の設定

1Password を使う WSL のマシンでは、WSL の `ssh` は Windows の `ssh.exe` を呼ぶ ([OpenSSH](#openssh))。
`ssh.exe` が読むのは Windows 側の `%USERPROFILE%\.ssh\config` なので、そこにも WSL と同じ形を置く
(経緯は [ADR 016](../docs/adr/016_ssh_config_from_dotfiles_private_20261012T131912JST/README.md))。
`manifest.toml` では配らず、`nix/scripts/bootstrap-windows-ssh-config.sh` (order 91) が
`setup --update` のたびにコピーする。

| Windows 側 | 中身 | 出所 |
| --- | --- | --- |
| `%USERPROFILE%\.ssh\config` | `Include config.d/*.ssh_config` の 1 行と説明のコメント | script が置く |
| `%USERPROFILE%\.ssh\config.d\<名前>.ssh_config` | 接続先 | private な dotfiles-private の `ssh/` からコピー |
| `%USERPROFILE%\.ssh\config.d\` のほかのファイル | マシン固有の接続先 | my-cloud の `ssh-config.sh` などが書く。script は触らない |

- `config.d` はファイル名の順に読まれ、同じキーは先に読んだ値が効く (WSL と同じ)
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
  ([PowerToys を入れる](#powertoys-を入れる-winget))、名前付きイベント
  `PowerToys_KeyboardManager_Event_Settings` を `powershell.exe` から送って読み直させる (エンジンは
  ファイルを見張っていない)。`default.json` の sha256 が前回読み直させたときと同じなら何もしない。
  PowerToys が動いていなければ、起動したときに読む
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
- setup が待つ上限は、`-Check` が 60 秒、`-IfMissing` が 600 秒。時間切れになったらそう出して、そのまま読み直しへ進む
  (どちらでも setup は止めない)
- 入れた直後は PowerToys が動いていないことがある。スタートメニューから起動する
- 入れたばかりのマシンでは、PowerToys の設定画面を一度開くまで、Keyboard Manager は配った割り当てを読まない。
  エンジンが読む `settings.json` (有効なプロファイルの名前) を作るのは設定画面だけで、作っても読み直しはしないため
  ([ADR 017](../docs/adr/017_win_apps_winget_20261012T115007JST/README.md) §1 の 7)。91 はこれを見分けて、
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
([ADR 015](../docs/adr/015_win_google_ime_powertoys_20261011T234247JST/README.md)、
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
  済んでいるが、後ろの exe-exec-trace と最後の「残りの手作業」は、解いて流し直すまで走らない。衝突で
  出すのは、設定は diff、辞書は辞書ごとの行の数 (「Windows 側にだけある行 N・repo 側にだけある行 M」
  など) だけで、辞書の語は setup の出力に出さない。語の diff は、自分の端末で `--dry-run --show-words`
- `--import` で取り込み、`git diff` を見て、dotfiles と dotfiles-private の両方で commit する (dotfiles-private の diff には辞書の語が出るので、自分の端末で見る)
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
([ADR 017](../docs/adr/017_win_apps_winget_20261012T115007JST/README.md)、[TKT-143](https://app.notion.com/p/winget-Windows-Google-PowerToys-Google-dotfiles-3f779149a66f817a8944c9e4e460383f))。

| 打つもの | すること |
| --- | --- |
| `Install-GoogleJapaneseInput -Check` (PowerShell) | 差を出すだけ。揃っていれば終了コード 0、差があれば 1、入っていなければ 3 |
| `Install-GoogleJapaneseInput` (PowerShell) | 揃える (入れる・上げる・pin を足す)。入れる・上げるときは UAC の確認が出る |
| `nix/scripts/bootstrap-windows-google-ime-install.sh` (WSL) | `setup --update` でも毎回走る (order 95)。入っていなければ入れ (UAC の確認が出る)、差があれば ⚠ で囲んで知らせる (上げはしない) |
| `nix/scripts/bootstrap-windows-google-ime-install.sh --apply` (WSL) | WSL から揃える。UAC の確認は Windows のデスクトップに出る |

- 版は `GoogleIMEJaConverter.exe` の ProductVersion で読む。`C:\Program Files\` と `C:\Program Files (x86)\` の
  `Google\Google Japanese Input\` の両方を見る (版によって、入る先が違うため)
- 上げるのは setup からはしない。日本語入力は全部のアプリに読み込まれていて、入れ替えるとアプリや Windows の
  再起動が要ることがあるため。上げる前に、日本語入力を使っているアプリをできるだけ閉じる。上げた後も `-Check` が
  古い版を出すなら、Windows を再起動してからもう一度 `-Check` で確かめる
- 入れた後と上げた後に `winget pin add` で `winget upgrade --all` から外す (上げるときは先に pin を外し、上げた後に足し直す)
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

PowerToys の割り当ては、これとは別に、91 が Keyboard Manager の設定 (`settings.json`) がまだ無いと出したら、設定画面を一度開いてから
91 を流し直すと効く ([PowerToys を入れる](#powertoys-を入れる-winget))。

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
