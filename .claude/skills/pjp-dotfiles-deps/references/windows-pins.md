# Windows に固定した版 (pins の `windows`)

dotfiles は Windows のアプリを版を固定して入れる (`win/README.md` の「固定した版より新しい版の知らせ」)。対象は OpenSSH・herdr・
Google 日本語入力・ntn・Claude Code・herdr-app・herdr-core。新しい版の候補と猶予ごとの上げ先は、依存の更新の skill が repo の口
(`deps.toml` の `[[pins]]` の `windows`。`nix/scripts/bootstrap-windows-pin-updates.sh --candidates --json`) から出す。どの版を
入れるか (上げないかも) はユーザーが決めること。候補を出して推奨を添えるまでが Claude で、黙って猶予より新しい版にしない。

- 人が読んで確かめるなら、同じ候補を文で出せる: `nix/scripts/bootstrap-windows-pin-updates.sh --candidates [--grace 1,3,7] [<名前>…]`
  (gh のログインが要る。見送った版の理由・上げ方の README の節・見送りの一覧の場所も出る)
- 出た日は、OpenSSH・herdr・Claude Code が GitHub の release、Google 日本語入力・ntn が winget-pkgs に載った日、herdr-app・
  herdr-core が成果物の Last-Modified。winget の版だけを数える (GitHub にあって winget にまだ無い版は上げ先にならない)
- 口の JSON で `error` のある名前は確かめられていない。その名前は上げず、わけを報告と PR の本文に書く

## 問い

会話で聞くとき (`ask = "interactive"`)。定期実行では聞かない (SKILL.md の「人が決めること」)。

名前ごとに 1 問にする (見送っていない新しい版がある名前だけ)。

- 選択肢は、猶予ごとの上げ先を重ねずに並べたもの (同じ版が 2 つの猶予の上げ先なら 1 つにまとめ、「2.1.323 (猶予 1・3 日)」の
  ように書く) と、「上げない」。出た日と URL を説明に添える
- 推奨は、`nix/release-age.nix` の `minimumReleaseAgeDays` (dotfiles の遅延の日数。今は 7) の上げ先。その上げ先が無いなら
  「上げない」を推奨にする (その日数たつまで待つ)。推奨を先頭に置き、label の末尾に「(推奨)」を付けて、理由を説明に書く
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
| `herdr-app`・`herdr-core` | `nix/pkgs/herdr-core/releases.json` の版と sha256 (core は 3 つの target と generation) | 「herdr-app を入れる」の「今は」 | 「固定した版を上げる」(sha256・core_min・generation・ソースが取得元の変数を読むかを確かめる) |

- テスト (名前ごとの ps1 のテストと herdr-core の build) は `deps.toml` の `[[checks]]` にあり、依存の更新の skill が PR の前に流す
- 上げる前に、その節のとおり release notes (CHANGELOG) を読み、設定・置き場所・更新の仕組みに触る変更が無いかを見る。気になる
  変更があれば、PR を出す前にユーザーに伝える (定期実行なら PR の本文に書く)
- 見送るなら、その名前の見送りの一覧に 1 行足す (候補の JSON の `skip_file`)。winget のものは「版 理由」、herdr-app・herdr-core は
  「app か core・版・理由」。今出ている新しい版を全部書く (1 つだけだと、残りの版でまた知らせる)
- 同じファイルを触る open の PR (`gh pr list --state open`) があれば、重ねずにユーザーに伝える
- PR の本文は、この repo の CLAUDE.md の「この repo の PR・commit に書くもの」に従う (変えたこと・確かめたこと・反映の仕方。
  ユーザーとのやり取りは書かない)。どの PR に入れるか (猶予どおりの上げ先・人が猶予より新しい版を選んだとき・見送ったとき) は、
  依存の更新の skill の決まりに従う

## merge の後

ユーザーが各マシンで `~/dotfiles/setup --self-update --update` を流す。名前ごとに揃い方が違うので、PR を返すときに添える。

| 名前 | setup --update のあと |
| --- | --- |
| `ntn`・`claude-code` | setup が揃える。exe が動いていると (Windows の Claude Code の会話を開いている・ntn が動いている) ⚠ で止まるので、閉じてから `Install-Ntn`・`Install-ClaudeCode` か `bootstrap-windows-*.sh --apply` |
| `herdr` | 差が ⚠ で出る。herdr の外の PowerShell で `hsvstop` を打ち、`herdr --remote` の窓も閉じてから `Install-Herdr` |
| `openssh` | 差が ⚠ で出る。Windows で動いている `ssh.exe` (herdr の remote など) を閉じてから `Install-OpenSSH` か `bootstrap-windows-openssh.sh --apply` (UAC が 1 回出る) |
| `google-japanese-input` | 差が ⚠ で出る。日本語入力を使っているアプリをできるだけ閉じてから `Install-GoogleJapaneseInput` (UAC の確認が出る) |
| `herdr-app`・`herdr-core` | setup がフィードを書き直して揃える (Linux のホストは switch で新しい herdr-core が入る) |

## 対象の外

- WSL・Linux の側の固定 (`nix/pkgs/ntn` の版・`nix/flake.lock`) は SKILL.md の「上げ方」のほかの行。mise のグローバルの道具は
  「反映」
- type-clipboard (自作のアプリ。公開からの猶予を置かず、Release を出す流れで上げる。`win/README.md` の「type-clipboard の新しい版を
  出したとき」) と PowerToys (版を固定しない)
- 週 1 回の CI (`winget-versions` の猶予 30 日・`herdr-app-installers` の猶予 7 日) は、これと別に今までどおり知らせる。見送りの
  一覧はどちらにも効く
