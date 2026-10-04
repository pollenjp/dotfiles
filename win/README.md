# win/

Windows 側のアプリの設定を置く場所。WSL から `/mnt/c` 越しにコピーして配る
(経緯は [ADR 010](../docs/adr/010_win_files_from_wsl_20260928T003933JST/README.md))。

| ファイル | 置き先 (Windows) | 中身 |
| --- | --- | --- |
| `orca/keybindings.json` | `%USERPROFILE%\.orca\keybindings.json` | Orca のキーバインド ([TKT-25](https://app.notion.com/p/Orca-worktree-Ctrl-Alt-Ctrl-Ctrl-W-3e779149a66f8177809ac8632bf68b2c)) |
| `powershell/dotfiles.ps1` | `%USERPROFILE%\.config\powershell\dotfiles.ps1` | PowerShell の共有設定 (herdr の alias)。`$PROFILE` から読む ([後述](#powershell)、[TKT-77](https://app.notion.com/p/PowerShell-profile-dotfiles-win-herdr-alias-h-hss-hls-Windows-3ef79149a66f817abc28dd3fa5241903)) |

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

alias の名前と中身は WSL の fish の abbr (`nix/home/modules/fish.nix`) とそろえてある。
足す・直すときは両方を変える。

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
