# win/

Windows 側のアプリの設定を置く場所。WSL から `/mnt/c` 越しにコピーして配る
(経緯は [ADR 010](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/010_win_files_from_wsl_20260928T003933JST/README.md))。

| ファイル | 置き先 (Windows) | 中身 |
| --- | --- | --- |
| `orca/keybindings.json` | `%USERPROFILE%\.orca\keybindings.json` | Orca のキーバインド ([TKT-25](https://app.notion.com/p/Orca-worktree-Ctrl-Alt-Ctrl-Ctrl-W-3e779149a66f8177809ac8632bf68b2c)) |
| `powershell/dotfiles.ps1` | `%USERPROFILE%\.config\powershell\dotfiles.ps1` | PowerShell の共有設定 (herdr と Claude Code の alias、`e` = `exit`)。`$PROFILE` から読む ([後述](#powershell)、[TKT-77](https://app.notion.com/p/PowerShell-profile-dotfiles-win-herdr-alias-h-hss-hls-Windows-3ef79149a66f817abc28dd3fa5241903)) |
| `herdr/config.toml` | `%APPDATA%\herdr\config.toml` | Windows の herdr の設定。キーバインドと sidebar の行は WSL と同じ ([後述](#herdr)、[TKT-92](https://app.notion.com/p/herdr-Windows-win-herdr-config-toml-3f079149a66f819fb49ef2d13e6a76f5)) |
| `openssh/Install-OpenSSH.ps1` | `%USERPROFILE%\.config\powershell\Install-OpenSSH.ps1` | Windows の OpenSSH を winget で固定した版に揃える。PowerShell の `Install-OpenSSH` から呼ぶ ([後述](#openssh)、[TKT-109](https://app.notion.com/p/winget-Windows-OpenSSH-win-3f179149a66f812fba25c6b2d6ce5d31)) |
| `herdr/Install-Herdr.ps1` | `%USERPROFILE%\.config\powershell\Install-Herdr.ps1` | Windows の herdr を winget で固定した版に揃える。PowerShell の `Install-Herdr` から呼ぶ ([後述](#herdr-を入れる-winget)、[TKT-112](https://app.notion.com/p/winget-Windows-herdr-Herdr-Herdr-Preview-dotfiles-3f179149a66f81858e0cf4555c9c598f)) |
| `herdr-app/Install-HerdrApp.ps1` | `%USERPROFILE%\.config\powershell\Install-HerdrApp.ps1` | Windows の herdr-app (herdr の desktop app) と herdr-core を、dotfiles が固定した版で公式の install.ps1 と同じ置き場所に入れる・外す。自己更新の取得元を、固定した版だけを載せた手元のフィードに替える。PowerShell の `Install-HerdrApp` から呼ぶ ([後述](#herdr-app)) |
| (`nix/pkgs/herdr-core/releases.json`) | `%USERPROFILE%\.config\powershell\herdr-releases.json` | herdr-app と herdr-core の固定した版と sha256。`Install-HerdrApp.ps1` が読む。Linux の home-manager も同じファイルを読むので `nix/` に置き、manifest の `base = "nix"` で配る ([後述](#固定した版を上げる)) |
| `powertoys/keyboard-manager/default.json` | `%LOCALAPPDATA%\Microsoft\PowerToys\Keyboard Manager\default.json` | PowerToys の Keyboard Manager の割り当て (CapsLock → F13 など)。エンジンが読む ([後述](#powertoys)、[TKT-139](https://app.notion.com/p/Windows-Google-dotfiles-win-3f679149a66f81b1a592d85d7300a62b)) |
| `powertoys/keyboard-manager/editorSettings.json` | `%LOCALAPPDATA%\Microsoft\PowerToys\Keyboard Manager\editorSettings.json` | Keyboard Manager の新しいエディタが持つ割り当ての一覧 ([後述](#powertoys)) |
| `powertoys/fancyzones/custom-layouts.json` | `%LOCALAPPDATA%\Microsoft\PowerToys\FancyZones\custom-layouts.json` の中のレイアウト | FancyZones のエディターの「カスタム」に登録したレイアウト。manifest では配らず、`bootstrap-windows-fancyzones.sh` が uuid ごとに足す (PC にだけあるレイアウトには触らない。[後述](#fancyzones)) |
| `powertoys/fancyzones/layout-rules.json` | `%LOCALAPPDATA%\Microsoft\PowerToys\FancyZones\applied-layouts.json` の、テンプレートのままの組 | ディスプレイの解像度から、あてるレイアウトを決める決まり。manifest では配らず、`bootstrap-windows-fancyzones.sh` がテンプレートのままのディスプレイの組を決まりのレイアウトで埋める (手であてたものは残す。[後述](#ディスプレイへのあて方)) |
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

## 配る

WSL で流す。`home-manager switch` だけでは Windows 側に届かない。

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

## winget の新しい版を確かめる

winget で版を固定しているもの (OpenSSH・herdr・Google 日本語入力) は、新しい版が出ても手元では
`-Check` の ※ の行でしか見えない (`setup --update` を流したときだけ)。そこで GitHub Actions の
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

- 確かめるのは `nix/scripts/check-winget-version.sh <名前>`。ps1 から固定した版とパッケージ ID (`$packageId`) を読み、
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
  - 30 日は script の先頭の `grace_days` の 1 か所で決める (3 つで同じ)
- 猶予がたって落ちる (exit 1) のは:
  - 固定した版より新しい版が winget にある (見送りの一覧に無いもの) → 名前ごとの手順で、上げるか見送るかを決める。
    出た日が分からない (合う release や commit が無い) ときは、待たずに落ちる
  - GitHub に出た版が winget のこのパッケージに無い (OpenSSH と herdr だけ。パッケージ ID が移ると、古い ID には
    新しい版が来ない) → 下の「パッケージ ID を確かめる」
- 猶予を置かずに落ちる (exit 1) のは、新しい版の知らせではなく、壊れていることの知らせ:
  - 固定した版が winget に無い (新しいマシンで入れられない) → winget にある版を選び直す
  - パッケージが winget に無い (`Microsoft.OpenSSH.Beta` は 2025-04-09 に全部の版が外された)
    → 下の「パッケージ ID を確かめる」
  - 版の形でないディレクトリがある・GitHub の最新の release から版が読めない・取った release に winget に載る側の
    ものが無い (版や名前の付け方、出し方が変わった) → script の読み方を直す
- パッケージ ID を確かめる: job が出す `winget search …` (`OpenSSH`・`herdr`・`JapaneseIME`) で今のパッケージ ID を
  確かめる。移るなら `git grep <今の ID>` で出る所 (ps1 の `$packageId` と状態の表・bootstrap の見分け・テスト) と
  固定した版を直す
- 確かめられずに落ちる (exit 2) のは、GitHub API の失敗・ps1 から版か ID が読めない・見送りの一覧の書き損じ。
  出た日を引く一覧 (GitHub の release・winget-pkgs の commit) だけが取れないときも、新しい版が猶予の中かを
  決められないので exit 2 になる。summary の `!!` の行を見て、一時的な失敗なら流し直し、書き損じなら直す
- 見送るときは、その名前の `skipped-versions.txt` に「版 理由」を 1 行足して commit する。その版では落ちなくなり、
  もっと新しい版が出ると、その版が出てから 30 日でまた落ちる。固定した版以下になった行は消してよい (job が
  「消してよい」と出す)。このファイルは manifest に無いので Windows へは配らない
- 猶予がたった新しい版がある間は、別の理由で ps1 や script を直す PR も赤くなる (merge は止まらない)。
  どれか 1 つを変えた PR でも、3 つの job が走る

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

固定した版は `nix/pkgs/herdr-core/releases.json` (今は app 0.1.13・core 0.1.18) の 1 か所で決める。app の版と windows-x86_64 の sha256、
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
`openssh/Install-OpenSSH.ps1` の `-Version` の既定値 (今は `10.0.0.0`) の 1 か所だけに書く。

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
   `--version` を付けて揃える。下げるときは MSI が「新しい版が入っている」で止めるので、先に `uninstall` する。
   どれにも `--custom ADDLOCAL=Client` を付け、sshd は入れない
2. ssh-agent サービスを停止・無効に戻す。MSI の更新は ssh-agent を「自動・実行中」で作り直し、1Password と
   `\\.\pipe\openssh-ssh-agent` を取り合う ([Win32-OpenSSH#2057](https://github.com/PowerShell/Win32-OpenSSH/issues/2057))。
   ssh-agent はクライアント側の部品でもあるので、`ADDLOCAL=Client` でも入る
3. `winget pin add` で `winget upgrade --all` から外す (名指しの `winget upgrade --id …` は通る)
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
ディスプレイへのあて方は [ADR 053](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/053_win_fancyzones_layout_by_resolution_20261110T213751JST/README.md))。
どれも manifest では配らず、`nix/scripts/bootstrap-windows-fancyzones.sh` (order 92) が `setup --update` のたびに書く。

| ファイル | 中身 | 書き方 |
| --- | --- | --- |
| `custom-layouts.json` | エディターの「カスタム」に登録したレイアウト (今は `4k-43inch` と `1080p`)。uuid・名前・座標だけ | PC の `custom-layouts.json` へ、レイアウトを uuid ごとに足す。PC にだけあるレイアウトには触らない ([カスタムレイアウト](#カスタムレイアウト)) |
| `layout-rules.json` | ディスプレイの解像度から、あてるレイアウトを決める決まり (今は 3840x2160 に `4k-43inch`、それ以外に `1080p`)。レイアウトの名前で書く | PC の `applied-layouts.json` のうち、テンプレートのままの組を決まりのレイアウトで埋める。手であてたものは残す ([ディスプレイへのあて方](#ディスプレイへのあて方)) |
| `managed.json` | `settings.json` のうち dotfiles が持つキーだけを、同じ形で書いたもの。今は「Windows スナップのオーバーライド」(`fancyzones_overrideSnapHotkeys`) を `true` | そのキーだけを `settings.json` へ書く ([持つキー](#持つキー)) |

| 打つもの | すること |
| --- | --- |
| `nix/scripts/bootstrap-windows-fancyzones.sh` | 持つキーの値が違えば書き、PC に無いレイアウトを足し、テンプレートのままのディスプレイの組にレイアウトをあてる (`setup --update` でも毎回走る) |
| `nix/scripts/bootstrap-windows-fancyzones.sh --dry-run` | 判定だけ見る (ディスプレイの解像度は `powershell.exe` で聞く) |
| `nix/scripts/bootstrap-windows-fancyzones.sh --force` | PC のエディターで直した・消したレイアウトも repo の中身にし、手であてたカスタムレイアウト・blank の組も決まりのレイアウトにする (書き換える前のファイルは退避する。先に `--dry-run --force` で見られる) |
| `nix/scripts/bootstrap-windows-fancyzones.sh --import <名前>` | PC のレイアウトを名前で選び、repo の `custom-layouts.json` へ写す (繰り返せる。commit は自分で) |
| `nix/scripts/bootstrap-windows-fancyzones.sh --check` | `managed.json`・`custom-layouts.json`・`layout-rules.json` の検証だけ (CI の lint でも走る) |

持たないもの:

| ファイル | わけ |
| --- | --- |
| `applied-layouts.json` | どのモニター × 仮想デスクトップの組にどのレイアウトをあてたか。モニターのシリアルが入り、PC ごとに違う (この repo は public)。持つのは、解像度であてるレイアウトを決める決まり (`layout-rules.json`) だけ |
| `layout-hotkeys.json`・`layout-templates.json`・`default-layouts.json` | 今は空か既定のまま |
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

FancyZones は、レイアウトを「モニター × 仮想デスクトップ」の組ごとにあてる (PC の `applied-layouts.json`)。新しいモニターや仮想デスクトップの
組はテンプレート (priority-grid など) で始まるので、エディターを開いてディスプレイの数だけあてて回らずに済むよう、`bootstrap-windows-fancyzones.sh` が
テンプレートのままの組を、解像度の決まりのレイアウトで埋める ([ADR 053](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/053_win_fancyzones_layout_by_resolution_20261110T213751JST/README.md))。

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
- 解像度は `powershell.exe` で Windows に聞く (FancyZones と同じ手順でディスプレイを並べる。0.6 秒ほどかかる)。聞くのは、埋める候補の組
  (テンプレートのままの組と、前に setup があてたままの組) があるときだけ

| 組 (モニター × 仮想デスクトップ) | 既定 | `--force` |
| --- | --- | --- |
| 合うディスプレイが無い (つながっていない)・縦向き | 触らない | 触らない |
| 決まりのレイアウトがあたっている | 何もしない | 何もしない |
| テンプレートのまま (blank を除く。エディターで選んだものも) | 決まりのレイアウトにする | 同じ |
| 前に setup があてたままで、決まりか解像度が変わった | 新しい決まりのレイアウトにする | 同じ |
| 手であてたカスタムレイアウト (PC にだけあるものも)・blank | 残し、まとめて 1 行知らせる (警告のまとめには載せない) | 決まりのレイアウトにする |
| 決まりのレイアウトが PC の `custom-layouts.json` に無い (PC で消した) | 飛ばして ⚠ で知らせる | `--force` が足し直してから、あてる |

- **手であてたものは、既定では残す。** blank (レイアウトなし) も、そのディスプレイではゾーンを使わないと選んだ印として残す。上書きするなら:

  ```sh
  nix/scripts/bootstrap-windows-fancyzones.sh --dry-run --force   # 何が変わるかを先に見る
  nix/scripts/bootstrap-windows-fancyzones.sh --force             # 上書きする (PC で直した・消したカスタムレイアウトも repo の中身に戻る)
  ```

- setup があてた組は `~/.local/state/dotfiles/windows-fancyzones.assigned.json` に覚える (キーはモニターの ID と仮想デスクトップで、シリアルは
  入れない)。後で決まりを足したとき・ディスプレイの解像度を変えたときに、setup があてたままの組は新しい決まりへ移り、手であてた組は残る
- 組は新しく作らない。まだ開いていない仮想デスクトップは、FancyZones が開いたときに前のデスクトップの組から写す。テンプレートのままの組に
  気づいたら、`~/dotfiles/setup --steps bootstrap-windows-fancyzones` で埋まる
- シリアルは見ない・読まない・出さない (FancyZones は同じ型のモニターに同じシリアルを入れるので、見分けにも使えない)。シリアルだけが違う
  古い組も、同じレイアウトにする
- 変えた組は 1 組 1 行で出す (モニター ID・解像度・仮想デスクトップの GUID の頭 8 桁・前 → 後)。書き方 (隣に書いて `mv` → `touch`・退避・
  PowerToys の形) はカスタムレイアウトと同じで、FancyZones はその場で読み直す
- `powershell.exe` が無い・失敗する・60 秒たっても終わらない・`applied-layouts.json` を読めない・記録が壊れている・`layout-rules.json` に
  誤りがあるときは、書かずに ⚠ で知らせて先へ進む (exit 0)

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
- 版は `Install-TypeClipboard.ps1` の `-Version` の既定値 (今は `0.2.0`) の 1 か所で、その版の exe の SHA-256 は同じファイルの
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
