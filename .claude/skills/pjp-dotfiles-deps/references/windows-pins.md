# Windows に固定した版 (pins の `windows`)

dotfiles は Windows のアプリを版を固定して入れる (`win/README.md` の「固定した版より新しい版の知らせ」)。対象は OpenSSH・herdr・
Google 日本語入力・ntn・Claude Code・Tailscale・ghq・fzf・starship・herdr-app・herdr-core と、新しい Windows で最初に流す bootstrap (`win/bootstrap/Install-Bootstrap.ps1`) が
入れる Git for Windows (`git`)・GitHub CLI (`gh`)・Visual Studio Build Tools 2022 (`vs-buildtools`)・rustup (`rustup`)。新しい版の候補と猶予ごとの上げ先は、依存の更新の skill が repo の口
(`deps.toml` の `[[pins]]` の `windows`。`nix/scripts/bootstrap-windows-pin-updates.sh --candidates --json`) から出す。どの版を
入れるか (上げないかも) はユーザーが決めること。候補を出して推奨を添えるまでが Claude で、黙って猶予より新しい版にしない。

- 人が読んで確かめるなら、同じ候補を文で出せる: `nix/scripts/bootstrap-windows-pin-updates.sh --candidates [--grace 1,3,7] [<名前>…]`
  (gh のログインが要る。見送った版の理由・上げ方の README の節・見送りの一覧の場所も出る)
- 出た日は、OpenSSH・herdr・Claude Code・git・gh が GitHub の release、Google 日本語入力・ntn・Tailscale・ghq・fzf・starship・vs-buildtools・rustup が winget-pkgs に
  載った日、herdr-app・herdr-core が成果物の Last-Modified。winget の版だけを数える (GitHub にあって winget にまだ無い版は上げ先にならない)
- 口の JSON で `error` のある名前は確かめられていない。その名前は上げず、わけを報告と PR の本文に書く

## 問い

会話で聞くとき (`ask = "interactive"`)。定期実行では聞かない (SKILL.md の「人が決めること」)。

名前ごとに 1 問にする (見送っていない新しい版がある名前だけ)。

- 選択肢は、猶予ごとの上げ先を重ねずに並べたもの (同じ版が 2 つの猶予の上げ先なら 1 つにまとめ、「2.1.323 (猶予 1・3 日)」の
  ように書く) と、「上げない」。出た日と URL を説明に添える
- 推奨は、`nix/release-age.nix` の `minimumReleaseAgeDays` (dotfiles の遅延の日数。今は 7) の上げ先。その上げ先が無いなら
  「上げない」を推奨にする (その日数たつまで待つ)。推奨を先頭に置き、label の末尾に「(推奨)」を付けて、理由を説明に書く
- `starship` だけは、Linux の home-manager が入れる starship と同じ版を推奨にする (`nix eval --raw --inputs-from ./nix nixpkgs#starship.version`)。その版が
  猶予の上げ先に入っていなければ (winget にまだ無い・猶予の内側)、「上げない」の「今は決めない」を推奨にして、わけを説明に書く。flake.lock を上げて
  nixpkgs の starship が変わったときも、この問いで揃える
- 「上げない」なら続けて聞く: **見送る** (見送りの一覧に足す。今出ている新しい版は、次から setup も CI も知らせない) か、
  **今は決めない** (何もしない。次の setup でもまた出る)。見送るなら理由も聞く (一覧に書く)
- 話している相手がユーザーなら AskUserQuestion で聞く (1 回に 4 問・1 問に選択肢 4 つまで。溢れたら答えを受けてから続ける)。
  指揮役から動かされる子の会話では、依存の更新の skill の決まりどおり、問いと選択肢 (推奨を先頭に、理由つき) を報告に書いて止まる
- 答えを受けたら、決まったことを短く並べて返し、「直す所」へ進む。「今は決めない」だけなら、ここで終わる

## 直す所

| 名前 | 版を書く所 | 一緒に直す所 | 上げ方 (`win/README.md`) |
| --- | --- | --- | --- |
| `openssh` | `win/openssh/Install-OpenSSH.ps1` の `-Version` の既定値 | 「OpenSSH」の冒頭の「今は」 | 「OpenSSH の新しい版が出たとき」(入れずに試す手順がある) |
| `herdr` | `win/herdr/Install-Herdr.ps1` の同じ所 | 「herdr を入れる (winget)」の「今は」 | 「herdr の新しい版が出たとき」 |
| `google-japanese-input` | `win/google-japanese-input/Install-GoogleJapaneseInput.ps1` の同じ所 | (README に版は書いていない) | 「Google 日本語入力の新しい版が出たとき」(「版を上げる」の 1〜5。Windows で上げて設定を読み書きできるかを確かめてから merge する) |
| `ntn` | `win/ntn/Install-Ntn.ps1` の同じ所 | 「ntn」の「今は」 | 「ntn の新しい版が出たとき」 |
| `claude-code` | `win/claude-code/Install-ClaudeCode.ps1` の同じ所 | 「Claude Code」の「今は」 | 「Claude Code の新しい版が出たとき」 |
| `tailscale` | `win/tailscale/Install-Tailscale.ps1` の同じ所 | 「Tailscale」の「今は」 | 「Tailscale の新しい版が出たとき」(固定した版は新しく入れるときの版。入っている Tailscale は自動更新で上がるので、上げ遅れても困るのは新しいマシンだけ) |
| `ghq`・`fzf` | `win/ghq/Install-Ghq.ps1`・`win/fzf/Install-Fzf.ps1` の同じ所 | 「ghq・fzf」の道具の表の版 | 「ghq・fzf の新しい版が出たとき」(cdrepo が使う `ghq list`・`ghq root` の出力と、`fzf -1 +m` の振る舞いが変わっていないか。fzf は winget の manifest に portable の zip が残っているか (`--installer-type portable`)) |
| `starship` | `win/starship/Install-Starship.ps1` の同じ所 | 「starship」の今の版 | 「starship の新しい版が出たとき」(上げる版は Linux の home-manager が入れる starship (`nix/flake.lock` の nixpkgs。`nix eval --raw --inputs-from ./nix nixpkgs#starship.version`) と揃える方向で選び、違う版を選ぶならわけを PR の本文に書く。PowerShell の init (`src/init/starship.ps1`) が ViModeChangeHandler を包む形が変わっていないか (`dotfiles.ps1` の Vi モードが前提にする)・`nix/files/starship.toml` が警告なしで読めるか・winget の manifest に portable の zip が残っているか) |
| `herdr-app`・`herdr-core` | `nix/pkgs/herdr-core/releases.json` の版と sha256 (core は 3 つの target と generation) | 「herdr-app を入れる」の「今は」。app を上げるなら、Windows で効く新しい既定のキーを `win/herdr-app/keys.json` に (dotfiles のキーと重なる既定のキーは、その既定の値を `win/herdr-app/keys.defaults.json` に) | 「固定した版を上げる」(sha256・core_min・generation・ソースが取得元の変数を読むか・既定のキーの増えを確かめる) |
| `git`・`gh`・`vs-buildtools`・`rustup` | `win/bootstrap/Install-Bootstrap.ps1` の名前ごとの param (`-GitVersion`・`-GhVersion`・`-VsBuildToolsVersion`・`-RustupVersion`) の既定値 | 「bootstrap (新しい Windows で最初に流す)」の道具の表の版 | 「bootstrap の固定した版の新しい版が出たとき」(Build Tools はワークロードと部品の ID が残っているか、rustup は `--default-host x86_64-pc-windows-msvc --default-toolchain none` と自己更新の止めが効くかも見る) |

- テスト (名前ごとの ps1 のテストと herdr-core の build) は `deps.toml` の `[[checks]]` にあり、依存の更新の skill が PR の前に流す
- 上げる前に、その節のとおり release notes (CHANGELOG) を読み、設定・置き場所・更新の仕組みに触る変更が無いかを見る。気になる
  変更があれば、PR を出す前にユーザーに伝える (定期実行なら PR の本文に書く)
- herdr-app (app) を上げるときは、既定のキーが増えた・変わったかも見る。dotfiles (Windows の runner の `herdr-app-keys`) がキーを書き足した
  keys.json には、herdr-app を上げても新しい既定のキーが足されない (`win/README.md` の「herdr-app のキー」)。上げる版までの `herdrdev/herdr-app` の
  `CHANGELOG.md` (herdr-app の更新ノート What's new と同じ中身) で、keys.json に触れた項 (「if you edited keys.json, add …」など) を探し、
  Windows で効くキー (macOS だけの `cmd-` のキー・Linux だけの項は除く) を同じ PR で `win/herdr-app/keys.json` の同じ section に足す。dotfiles の
  キーと同じ section の同じキーなら keys.json には足さず、その既定の値を `win/herdr-app/keys.defaults.json` に書く。細かい section (`terminal`
  など) に dotfiles のキーと同じキーが増えたとき・足さないと決めたキー・Windows で効くキーが無かったことは、PR の本文に書く (手順の細部は
  `win/README.md` の「固定した版を上げる」の 3)。setup の新しい版の知らせ (警告のまとめ) も、herdr-app の行があれば末尾に同じ注意を添える
- 見送るなら、その名前の見送りの一覧に 1 行足す (候補の JSON の `skip_file`)。winget のものは「版 理由」、herdr-app・herdr-core は
  「app か core・版・理由」。今出ている新しい版を全部書く (1 つだけだと、残りの版でまた知らせる)
- 同じファイルを触る open の PR (`gh pr list --state open`) があれば、重ねずにユーザーに伝える
- PR の本文は、この repo の CLAUDE.md の「この repo の PR・commit に書くもの」に従う (変えたこと・確かめたこと・反映の仕方。
  ユーザーとのやり取りは書かない)。どの PR に入れるか (猶予どおりの上げ先・人が猶予より新しい版を選んだとき・見送ったとき) は、
  依存の更新の skill の決まりに従う

## merge の後

ユーザーが各マシンで `~/dotfiles/setup --self-update --update` を流す。名前ごとに揃い方が違うので、PR を返すときに添える。

受け持ちを Windows の runner に切り替えたホスト (dotfiles-private の `win/hosts/*.toml` で `[runner] enable = true`) では、WSL の setup は Windows に
触らない。そのホストでは、Windows で PowerShell の `dotfiles --self-update apply` (3 つの clone を進めてから `dotfiles apply`) を流す (`win/README.md` の
「受け持ちを runner に切り替える」・「clone を進める (dotfiles --self-update)」)。
下の表の「setup」は、そのホストでは `dotfiles apply` と読む (runner の ps1 の手順は WSL の setup と同じ判断で揃える・知らせる)。
`bootstrap-windows-*.sh --apply` は PowerShell の `Install-*` と読む。PR を返すときは、両方の道を添える。

| 名前 | setup --update (切り替えたホストは dotfiles apply) のあと |
| --- | --- |
| `ntn`・`claude-code` | setup が揃える。exe が動いていると (Windows の Claude Code の会話を開いている・ntn が動いている) ⚠ で止まるので、閉じてから `Install-Ntn`・`Install-ClaudeCode` か `bootstrap-windows-*.sh --apply` |
| `herdr` | 差が ⚠ で出る。herdr の外の PowerShell で `hsvstop` を打ち、`herdr --remote` の窓も閉じてから `Install-Herdr` |
| `openssh` | 差が ⚠ で出る。Windows で動いている `ssh.exe` (herdr の remote など) を閉じてから `Install-OpenSSH` か `bootstrap-windows-openssh.sh --apply` (UAC が 1 回出る)。sshd を入れたマシン (`windowsSshd`) では Server も一緒に入れ直るので、続けて `Install-Sshd` か `bootstrap-windows-sshd.sh --apply` で揃える (上げ直した MSI が 22 番の受信の許可を有効に戻す。SSH でつないだ会話は入れ直す間に切れる) |
| `google-japanese-input` | 差が ⚠ で出る。日本語入力を使っているアプリをできるだけ閉じてから `Install-GoogleJapaneseInput` (UAC の確認が出る) |
| `tailscale` | 入っている版の方が新しければ揃っている扱い (※ だけ)。古ければ差が ⚠ で出るので、Tailscale の自動更新を待つか `Install-Tailscale` (UAC の確認が出て、上げる間 Tailscale の接続が少しの間切れる)。新しいマシンは setup が固定した版で入れる |
| `ghq`・`fzf` | WSL の setup は入れない (Windows の runner の手順 `ghq`・`fzf` だけが入れる)。受け持ちによらず、Windows で `dotfiles --self-update apply` (clone を進めてから流す。`--steps ghq,fzf` で絞れる) を流すと揃える。exe が動いていると (別の端末の cdrepo の選ぶ画面など) ⚠ で止まるので、閉じてから `Install-Ghq`・`Install-Fzf` |
| `starship` | ghq・fzf と同じ (Windows の runner の手順 `starship` だけが入れる。`--steps starship` で絞れる)。starship.exe はプロンプトを描く間だけ動くので、ふつうは止まらない。止まったら描き終わらないプロンプトを閉じてから `Install-Starship` |
| `herdr-app`・`herdr-core` | setup がフィードを書き直して揃える (Linux のホストは switch で新しい herdr-core が入る)。`win/herdr-app/keys.json` にキーを足したなら、Windows で `dotfiles --self-update apply --steps herdr-app-keys` (clone を進めてから流す) を流す (受け持ちが WSL のホストでも流す) |
| `git`・`gh`・`vs-buildtools`・`rustup` | setup は揃えない (WSL の setup は Windows のこの 4 つを入れない)。新しい Windows は、bootstrap が新しい版で入れる。入っている Windows では bootstrap の `-Check` が版のずれを ⚠ で出すので、`win/README.md` の「版のずれを手で揃える」の手順 (名指しの `winget upgrade --id <ID> --exact --version <版> --include-pinned`。`--include-pinned` が無いと bootstrap が足した pin に止められる) で手で揃える (runner の `bootstrap` の手順も `-Check` で確かめるだけで、揃えない) |

- 設定グループ・道具の switch でその名前を入れないマシン (`dotfiles.wsl.windowsFiles` の `ntn`・`claudeCode`・`herdr`・`tailscale` の
  `enable` が false。herdr-app・herdr-core は `herdr` の値。グループ minimum では、どれも足さなければ false) では、setup はその名前を確かめも
  揃えもしない (`nix/README.md` の「設定グループ」)。受け持ちを runner に切り替えたホストでは、Nix の値でなく、Windows のホストの値の `[tools]`
  (`windowsNtn`・`windowsClaudeCode`・`windowsHerdr`・`windowsTailscale`) と `win/runner/groups.json` の既定で決まる (`win/README.md` の「ホストの値」)

## 対象の外

- WSL・Linux の側の固定 (`nix/pkgs/ntn` の版・`nix/flake.lock`) は SKILL.md の「上げ方」のほかの行。mise のグローバルの道具は
  「反映」
- type-clipboard (自作のアプリ。公開からの猶予を置かず、Release を出す流れで上げる。`win/README.md` の「type-clipboard の新しい版を
  出したとき」) と PowerToys (版を固定しない)
- op-reason (`win/op-reason/Install-OpReason.ps1`。自作のアプリ。WSL の `nix/pkgs/op-reason` と同じ版を同じ PR で、Release を出す
  流れで上げる。`nix/README.md` の「op-reason の新しい版を出したとき」)
- 週 1 回の CI (`winget-versions` の猶予 30 日・`herdr-app-installers` の猶予 7 日) は、これと別に今までどおり知らせる。見送りの
  一覧はどちらにも効く
