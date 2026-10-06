# win/

Windows 側のアプリの設定を置く場所。WSL から `/mnt/c` 越しにコピーして配る
(経緯は [ADR 010](../docs/adr/010_win_files_from_wsl_20260928T003933JST/README.md))。

| ファイル | 置き先 (Windows) | 中身 |
| --- | --- | --- |
| `orca/keybindings.json` | `%USERPROFILE%\.orca\keybindings.json` | Orca のキーバインド ([TKT-25](https://app.notion.com/p/Orca-worktree-Ctrl-Alt-Ctrl-Ctrl-W-3e779149a66f8177809ac8632bf68b2c)) |
| `powershell/dotfiles.ps1` | `%USERPROFILE%\.config\powershell\dotfiles.ps1` | PowerShell の共有設定 (herdr の alias)。`$PROFILE` から読む ([後述](#powershell)、[TKT-77](https://app.notion.com/p/PowerShell-profile-dotfiles-win-herdr-alias-h-hss-hls-Windows-3ef79149a66f817abc28dd3fa5241903)) |
| `herdr/config.toml` | `%APPDATA%\herdr\config.toml` | Windows の herdr の設定。キーバインドは WSL と同じ ([後述](#herdr)、[TKT-92](https://app.notion.com/p/herdr-Windows-win-herdr-config-toml-3f079149a66f819fb49ef2d13e6a76f5)) |
| `openssh/Install-OpenSSH.ps1` | `%USERPROFILE%\.config\powershell\Install-OpenSSH.ps1` | Windows の OpenSSH を winget で固定した版に揃える。PowerShell の `Install-OpenSSH` から呼ぶ ([後述](#openssh)、[TKT-109](https://app.notion.com/p/winget-Windows-OpenSSH-win-3f179149a66f812fba25c6b2d6ce5d31)) |
| `herdr/Install-Herdr.ps1` | `%USERPROFILE%\.config\powershell\Install-Herdr.ps1` | Windows の herdr を winget で固定した版に揃える。PowerShell の `Install-Herdr` から呼ぶ ([後述](#herdr-を入れる-winget)、[TKT-112](https://app.notion.com/p/winget-Windows-herdr-Herdr-Herdr-Preview-dotfiles-3f179149a66f81858e0cf4555c9c598f)) |

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
diff を出して止まる。`setup --update` ではこの手順だけ失敗する (最後に走るので、ほかは止めない)。

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

叩くのは Windows に入れた `herdr.exe` (WinGet の `Herdr.Herdr.Preview`) で、WSL の herdr とは
別の server (session を共有しない)。

### dotfiles.ps1 を書くときの注意

- **BOM 付きの UTF-8 で保存する** (`.editorconfig` も `*.ps1` を `utf-8-bom` にしている)。
  Windows PowerShell 5.1 は BOM の無い UTF-8 を CP932 として読み、日本語コメントの次の行を
  黙って読み飛ばすことがある (`Set-Alias` の行が消えたのを確かめた)。PowerShell 7 はどちらでも読む

  ```sh
  head -c3 win/powershell/dotfiles.ps1 | od -An -tx1   # ef bb bf と出れば BOM 付き
  ```

- PowerShell の alias は引数を持てない。引数を足すものは function にする
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

1. 入っている版 (winget の置き場所の `herdr.exe --version`) と固定した版を比べる。違えば
   `winget uninstall` してから `winget install --version` で入れる。portable の置き場所は版によらず
   同じで、`%APPDATA%\herdr` の設定やセッションは消えない
2. 入れ替えの前に pin を外し、入れた後に `winget pin add` で `winget upgrade --all` から外す
3. 読み直して、版・pin・PATH で引かれる herdr を確かめる

- 入れ替えるときに herdr が動いていると (server・`herdr --remote`・conpty の OpenConsole.exe)、
  herdr.exe を置き換えられないので、何も変えずに止まる。herdr の外の PowerShell
  (Windows Terminal など) で `hsvstop` を打ち、`--remote` の窓も閉じてから打ち直す。
  スクリプトが server を止めないのは、herdr の pane の中で打つと自分ごと消えるため
- `herdr update` は打たない。herdr 自身の installer が `%USERPROFILE%\.herdr\packages\standalone` に
  別に入れ、`%LOCALAPPDATA%\Programs\Herdr\bin` と `%USERPROFILE%\.herdr\packages\standalone\current` を
  ユーザーの PATH の先頭に足すので、winget の herdr が引かれなくなる。新しい版の通知は
  `herdr/config.toml` の `[update] version_check = false` で止めてある。打ってしまったら
  (`-Check` の「PATH の herdr」が ⚠ になる)、ユーザーの PATH から上の 2 つを外し、
  `%USERPROFILE%\.herdr\packages` と `%LOCALAPPDATA%\Programs\Herdr` を消す
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
- 版を変えるときは、`-Version` の既定値を変えて commit し、`setup --update` で配る (差が ⚠ で出る)。
  そのあと `Install-OpenSSH` か `--apply` で揃える。新しい版は先に入れずに試す (GitHub の ZIP を展開して
  `ssh.exe -V`・`ssh -G <host>`・`ssh-add.exe -l` を流す。[TKT-107](https://app.notion.com/p/Windows-ssh-exe-Win32-OpenSSH-3f079149a66f8153877df4a8e87ed0d7))
- 新しい版が出たかは `-Check` の「winget の最新版」と ※ の行で分かる

### Install-OpenSSH.ps1 を書くときの注意

- `dotfiles.ps1` と同じく **BOM 付きの UTF-8** で保存する
- 副作用の無い関数 (版の比べ方・winget の出力の読み方・winget の引数・状態の表) は
  `openssh/Install-OpenSSH.Tests.ps1` で確かめる。Linux の pwsh で流すので Windows には触らない
  (このファイルは manifest に無いので配られない):

  ```sh
  nix shell nixpkgs#powershell -c pwsh -NoProfile -File win/openssh/Install-OpenSSH.Tests.ps1
  ```

- winget やサービスに触る部分は、実機で `-Check` と本番を打って確かめる
