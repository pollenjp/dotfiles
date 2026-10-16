# ADR: Windows Terminal の settings.json は、dotfiles が持つキーだけを setup が書き足す

| 項目 | 内容 |
| --- | --- |
| ステータス | 提案 (Proposed) — レビュー中 |
| 日付 | 2026-10-16 (JST) |
| 決定者 | pollenjp |
| チケット | [TKT-167](https://app.notion.com/p/Windows-Terminal-settings-json-dotfiles-bell-3fb79149a66f81e6a695c581b5ab5cef) |
| 前提 ADR | [010_win_files_from_wsl](../010_win_files_from_wsl_20260928T003933JST/README.md)（Windows 側へは WSL の bootstrap が `/mnt/c` へコピーして配り、Windows 側で変わっていたら止める）、[015_win_google_ime_powertoys](../015_win_google_ime_powertoys_20261011T234247JST/README.md)（アプリが書き換える設定は、比べる単位を決めて repo の側から組み立てて配る） |
| 運用手順 | [`win/README.md`「Windows Terminal」](../../../win/README.md#windows-terminal)、[`nix/README.md`「Windows 側のファイルを配る」](../../../nix/README.md#windows-側のファイルを配る) |

---

## 1. 背景 (Context)

### やりたかったこと

- Windows Terminal で BEL が来るたびに鳴る音を替えたい。既定の `bellStyle` は `audible` で、`bellSound` が
  空だと SystemHand の音 (この PC では `C:\Windows\Media\Windows Foreground.wav`、2.1 秒) を鳴らす
- まずこの PC の `settings.json` の `profiles.defaults` に `bellSound` (`Windows Information Bar.wav`、0.1 秒) を
  手で書き、鳴ることを確かめた。同じ設定を会社の PC など、ほかのマシンにも配りたい
- これから、ほかの設定 (`copyOnSelect`・キー割り当てなど) も同じ仕組みで持てるようにしたい

### 設計を縛る事実

この PC の Windows Terminal (Store 版 1.24.12741.0) と WSL のソースで確かめた。

#### 1. 値は上の層から探し、`profiles.defaults` は fragment より強い

効く順は、profile 自身 > `settings.json` の `profiles.defaults` > fragment の `updates` > 生成された profile
(WSL・PowerShell 7 など) > 組み込みの既定値。fragment の `updates` も「いちばん強い親」として差し込まれるが、
読み込みの最後に `profiles.defaults` がさらに前へ入る。

```cpp
// microsoft/terminal v1.24.12741.0 src/cascadia/TerminalSettingsModel/CascadiaSettingsSerialization.cpp L983-990 (_parseFragment)
        for (const auto& fragmentProfile : settings.profiles)
        {
            if (const auto updates = fragmentProfile->Updates(); updates != winrt::guid{})
            {
                if (const auto it = userSettings.profilesByGuid.find(updates); it != userSettings.profilesByGuid.end())
                {
                    it->second->AddMostImportantParent(fragmentProfile);
                }

// 同 L485-491 (FinalizeLayering。fragment より後に走る)
    // Layer default profile defaults -> user profile defaults
    userSettings.baseLayerProfile->AddLeastImportantParent(inboxSettings.baseLayerProfile);
    userSettings.baseLayerProfile->_FinalizeInheritance();
    // Layer user profile defaults -> user profiles
    for (const auto& profile : userSettings.profiles)
    {
        profile->AddMostImportantParent(userSettings.baseLayerProfile);
```

#### 2. fragment は `profiles.defaults` も全体設定のキー割り当ても読まない

`settings.json` からは `profiles.defaults` を読むが、fragment の profile は一覧 (配列) しか読まない。fragment の
全体設定から読むのは `actions` だけで、キーへの割り当ては読まない。

```cpp
// 同 L850 (_parse)・L946 (_parseFragment)
        settings.baseLayerProfile = Profile::FromJson(json.profileDefaults);
…
        for (const auto& profileJson : json.profilesList)

// 同 L924-932 (_parseFragment)
            // Parse out actions from the fragment. Manually opt-out of keybinding
            // parsing - fragments shouldn't be allowed to bind actions to keys
            // directly. We may want to revisit circa GH#2205
            settings.globals = winrt::make_self<GlobalAppSettings>();
            settings.globals->SourceBasePath = sourceBasePath;
            settings.globals->LayerActionsFrom(json.root, OriginTag::Fragment, false);
```

#### 3. WSL の profile の GUID は PC ごとに違う

WSL は、distro を登録したときの ID (登録のたびにランダム) から v5 UUID で profile の GUID を作る。同じ
`Ubuntu-24.04` でも、別の PC や入れ直した後は GUID が変わる。

```cpp
// microsoft/WSL 9a32b5e src/windows/service/exe/LxssUserSession.cpp L2890-2892
    auto distributionIdString = wsl::shared::string::GuidToString<wchar_t>(Registration.Id());
    auto distributionProfileId =
        wsl::shared::string::GuidToString<wchar_t>(CreateV5Uuid(WslTerminalNamespace, std::as_bytes(std::span{distributionIdString})));
```

#### 4. Windows Terminal は `settings.json` を自分で書き換える

新しい profile (WSL の distro など) を見つけると、読み込みの後で `settings.json` を書き直す。設定画面で保存した
ときも書き直す。`settings.json` の `profiles.list` には、PC ごとに違う GUID の profile が並ぶ。

```cpp
// microsoft/terminal v1.24.12741.0 CascadiaSettingsSerialization.cpp L1268-1278 (LoadAll)
    loader.FindFragmentsAndMergeIntoUserSettings(false /*generateExtensionPackages*/);
    loader.FinalizeLayering();

    // DisableDeletedProfiles returns true whenever we encountered any new generated/dynamic profiles.
    // Similarly FixupUserSettings returns true, when it encountered settings that were patched up.
    mustWriteToDisk |= loader.DisableDeletedProfiles();
```

#### 5. `settings.json` を書き換えると、その場で読み直す

WSL から `settings.json` を書き換えた直後に開いたタブで、新しい音が鳴った。中身を書き直した場合も、
同じディレクトリの一時ファイルから `mv` で置き換えた場合も同じだった。

## 2. 決定 (Decision)

### A. 持つキーだけを `win/windows-terminal/managed.json` に書く

`settings.json` と同じ形で、dotfiles が持つキーだけを書く。object を辿った先の、object でない値 (文字列・数・
真偽・null・配列) 1 つが、持つキー 1 つ。配列 (`actions`・`keybindings` など) は中を見ず、丸ごと 1 つの値として
持つ。`profiles.list` は PC ごとに違うので持てない (`--check` が落ちる)。全 profile に効かせるときは
`profiles.defaults` に書く。

形は `jq --indent 4` の出力に揃える (`--import` が書き直したときの差分を、値の変更だけにするため)。

### B. `bootstrap-windows-terminal.sh` (order 99) がキーごとに判定して書き足す

`setup --update` のたびに走り、`managed.json` のキーを 1 つずつ、Store 版の `settings.json` の値と、前回書いた値
(`~/.local/state/dotfiles/windows-terminal.applied.json`) で判定する。

| `settings.json` の値 | すること |
| --- | --- |
| `managed.json` と同じ | 何もしない (記録が無ければ記録だけする) |
| 前回書いた値と同じ | `managed.json` が更新された。書く |
| 無く、記録も無い | 書き足す |
| それ以外 (Windows 側で変えた・消した、書く前から違う値があった) | 衝突。両方の値を出して触らない |

- 書くときは `settings.json` を `~/.local/state/dotfiles/windows-terminal/backup/` へ退避し (新しい方から 10 回分)、
  同じディレクトリの一時ファイルに jq で書いてから `mv` する
- 衝突しないキーは書き、衝突があれば ⚠ の枠で出して exit 1。`setup` はそこで止まる
- `managed.json` から消したキーは、`settings.json` からは消さない (記録からだけ消す。manifest から消した
  ファイルを消さない ADR 010 と同じ)
- `settings.json` が無い・JSON として読めない (コメントがある、など) ときは、warn で知らせて書かずに exit 0
- 判定の考え方は、ファイル単位で同じことをしている `bootstrap-windows-ssh-config.sh` (ADR 016) と同じ。
  単位をファイルからキーに変えた
- order は 99 にする。ほかの bootstrap が置くものは使わず、衝突で止まったときに巻き込むのが、後ろの
  exe-exec-trace と最後の「残りの手作業」だけで済むため

### C. 衝突は `--import` か `--force` で解く

- `--import` は、衝突したキーの値を `settings.json` から `managed.json` へ取り込む (値が無ければ `managed.json` から
  消す)。`managed.json` に commit していない変更があると、何も書かずに止まる (Google 日本語入力の `--import` と同じ)
- `--force` は、`settings.json` を退避してから `managed.json` の値で書く

### D. 音などのファイルは repo に入れない

`bellSound` には Windows に入っている音のパス (`C:\Windows\Media\…`) を書き、wav などのファイルそのものは commit
しない。この repo は public で、Windows に付いてくる音は Microsoft の著作物なので、ファイルを置くと配布になる。
パスを書くだけなら、各 PC の Windows に入っている音をその PC で鳴らすだけで済む。

### E. 最初に持つキーは `profiles.defaults.bellSound` だけ

`bellStyle` は既定の `audible` のままにし、音だけを `C:\Windows\Media\Windows Information Bar.wav` に替える。
ほかのキーは、必要になったときに `managed.json` へ足す。

## 3. 変更点の詳細

| ファイル | 変更 |
| --- | --- |
| `win/windows-terminal/managed.json` | 新規。`profiles.defaults.bellSound` だけを持つ |
| `nix/scripts/bootstrap-windows-terminal.sh` | 新規 (order 99)。`--dry-run`・`--force`・`--import`・`--check` |
| `nix/tests/bootstrap-windows-terminal.test.sh`・`nix/flake.nix` | 偽の HOME と checkout で判定ごとの振る舞いを確かめる check (`bootstrap-windows-terminal-test`) |
| `.github/workflows/nix.yml` | lint に `bootstrap-windows-terminal.sh --check` を足す (flake からは `win/` が見えないので、checkout の上で流す) |
| `win/README.md` | 「Windows Terminal」の節と、冒頭の表の 1 行。99 が増えたので、止まったときに走らない手順の範囲 (91〜99) を直す |
| `nix/README.md` | 実行順・手順・段の表、コマンドの一覧、ファイルの木に足す。範囲 (91〜99・95〜99) を直す |
| `nix/scripts/bootstrap-windows-google-ime.sh`・`bootstrap-windows-ssh-config.sh` | 冒頭のコメントの、後ろに走る手順の範囲を直す (98 の後ろに 99 が来た) |

## 4. 検討した代替案

### `settings.json` を manifest で丸ごと配る (ADR 010 の仕組み)

採らない。Windows Terminal が新しい profile を見つけたときや設定画面で保存したときに書き換えるので (事実 4)、
そのたびに次の `setup --update` が衝突で止まる。`profiles.list` には PC ごとに違う GUID の profile が並ぶので
(事実 3)、1 つのファイルを PC の間で共有することもできない。

### fragment を配る (`%LOCALAPPDATA%\Microsoft\Windows Terminal\Fragments\`)

採らない。Windows Terminal は fragment を書き換えないので、manifest に 1 行足すだけで衝突なく配れる。しかし:

- fragment は `profiles.defaults` を読まないので (事実 2)、profile の GUID を 1 つずつ `updates` で指すことになる。
  WSL の profile の GUID は PC ごとに違うので (事実 3)、共有の fragment から指せない。当てられるのは PowerShell 7・
  Windows PowerShell・コマンド プロンプトなど、どの PC でも GUID が同じ profile に限られる
- `settings.json` の `profiles.defaults` に値があると、fragment の値は何も言わずに負ける (事実 1)。設定画面の
  「既定値」で変えたときも同じ
- 全体設定 (`copyOnSelect` など) とキー割り当ては書けない (事実 2)

### 管理しない (README に手で足す手順だけ書く)

bell の音だけなら足りる (新しい PC で足すのは 3 行)。しかし設定画面で変えても気づけず、ほかの設定を持つ
余地も無い。

### 衝突しても止めず、warn で知らせて進む (exit 0)

採らない。ほかの bootstrap (ADR 010・015・016) と同じく止める。進めると、Windows 側の変更か repo 側の変更の
どちらかを、決めないまま放っておくことになる。

## 5. 影響 (Consequences)

### 良くなること

- bell の音を、`setup --update` で各 PC に揃えられる。全 profile (WSL・PowerShell など) に効く
- ほかの Windows Terminal の設定も、`managed.json` にキーを足すだけで同じように持てる
- 設定画面で持つキーを変えると次の `setup --update` が知らせるので、repo と Windows のずれに気づける

### 注意が必要なこと

- 書いた後の `settings.json` は、字下げなどの形が jq のものに変わる。Windows Terminal は気にせず読み、次に
  自分で保存したときに自分の形へ戻す
- 設定画面で持つキーを変えると、次の `setup --update` がこの手順で止まる。`--import` か `--force` で解く
- 配列は丸ごと 1 つの値として持つので、`actions`・`keybindings` を持つと、設定画面でキー割り当てを 1 つ変えた
  だけでも衝突になる
- 見るのは Store 版の `settings.json` だけ。Preview と zip 版を使う PC では何もしない
- order 98 の Google 日本語入力の手順が止まると、99 のこの手順も走らない (逆も同じで、99 が止まっても 98 は済んでいる)

## 6. 検証 (Verification)

- `nix build ./nix#checks.x86_64-linux.bootstrap-windows-terminal-test` (29 件)。書き足し・同じ値・
  `managed.json` の更新・3 種類の衝突・`--force`・`--dry-run`・`--import` (取り込み・消す・commit していない
  変更で止まる・git の外で止まる)・名前に `.` を含むキーと配列と null・消したキー・書けないキー・退避の数・
  壊れた記録・引数の誤り・setup の警告のまとめ
- shfmt・shellcheck・`check-test-headers.sh`・`warn-helpers.test.sh`・`bootstrap-windows-terminal.sh --check`
- この PC (Windows Terminal 1.24.12741.0) で:
  1. 手で書いた値と同じなので、初回は `settings.json` に触らず記録だけが作られた (sha256 が変わらない)
  2. `bellSound` を `ding.wav` に書き換えて流すと、衝突として両方の値を出し、触らずに exit 1 で止まった
  3. `--force` で `managed.json` の値に書き戻し、退避が 1 つできた。直後に開いたタブで `Windows Information Bar.wav`
     が鳴り、Windows Terminal が `mv` での置き換えを読み直したことを確かめた
  4. もう一度流すと「揃っています」で終わった

## 7. 移行・運用手順

### この PC

手で書いた `bellSound` と同じ値なので、merge した後の `setup --update` は記録だけを作る (検証で済ませてある)。

### ほかの PC (会社の PC など)

```sh
~/dotfiles/setup --update
```

- Windows Terminal を一度も起動していないと `settings.json` が無いので、起動してから流し直す
- 手で違う `bellSound` を設定してあったら、「書いた記録が無く」の衝突で止まる。repo の値でよければ
  `nix/scripts/bootstrap-windows-terminal.sh --force`、その PC の値を repo に入れるなら `--import`

### キーを足すとき

[`win/README.md`「キーを足す」](../../../win/README.md#キーを足す) の手順で、設定画面で決めた値を `managed.json` に写す。
