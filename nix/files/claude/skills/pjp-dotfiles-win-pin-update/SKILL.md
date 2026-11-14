---
name: pjp-dotfiles-win-pin-update
description: >-
  dotfiles が Windows に固定した版で入れているもの (OpenSSH・herdr・Google 日本語入力・ntn・Claude Code・herdr-app・herdr-core) を、
  新しい版へ上げるかをユーザーに聞き、上げる (か見送る) PR を作るときに使う。setup の警告のまとめに「Windows に固定した版より
  新しい版があります → Claude Code の pjp-dotfiles-win-pin-update skill で…」が出たとき、「Windows の Claude Code (ntn・herdr など)
  を新しい版に上げたい」「固定した版の上げ先の候補を出して」と言われたとき、winget-versions などの CI が新しい版で落ちたときに読む。
  WSL・Linux の側の固定 (nix/pkgs・mise・flake.lock) を上げる話は pjp-dotfiles-update・pjp-dep-update の側。
metadata:
  pjp-pack: machine
---

# pjp-dotfiles-win-pin-update

dotfiles は Windows のアプリを版を固定して入れる (`win/README.md` の「固定した版より新しい版の知らせ」)。新しい版が出ると、
`setup --update` の手順 `bootstrap-windows-pin-updates.sh` が「新しい版がある」とだけ短く出し、警告のまとめにこの skill の名前を
書く。この skill は、その続き: 猶予ごとの上げ先の候補を出し、上げるか (どの版か・上げないか) を**ユーザーに**決めてもらい、
決まったとおりに PR を作る。どの版を入れるかはユーザーが決めること。候補を出して推奨を添えるまでが Claude で、黙って上げない。

## 1. 候補を出す

dotfiles の checkout (setup を流した所) で打つ。`~/dotfiles/setup` は checkout の `nix/scripts/setup.sh` への symlink:

```sh
scripts=$(dirname "$(readlink -f ~/dotfiles/setup)")
"${scripts}/bootstrap-windows-pin-updates.sh" --candidates                 # 全部の名前
"${scripts}/bootstrap-windows-pin-updates.sh" --candidates ntn claude-code # 名前を選ぶ
"${scripts}/bootstrap-windows-pin-updates.sh" --candidates --grace 1,3,7   # 猶予の日数 (既定は 1,3,7)
```

- 名前は `openssh`・`herdr`・`google-japanese-input`・`ntn`・`claude-code`・`herdr-app`・`herdr-core`。まとめの行の題
  (「Windows の Claude Code」など) から選ぶか、省いて全部を出す (新しい版の無い名前は最後に 1 行でまとまる)
- 名前ごとに、新しい版 (出た日・何日前・release notes などの URL。見送った版は理由)、猶予ごとの上げ先 (その日数以上たった、
  見送っていない新しい版のうち、いちばん新しいもの)、上げ方の README の節と見送りの一覧の場所が出る
- 出た日は、OpenSSH・herdr・Claude Code が GitHub の release、Google 日本語入力・ntn が winget-pkgs に載った日、herdr-app・
  herdr-core が成果物の Last-Modified。winget の版だけを数える (GitHub にあって winget にまだ無い版は上げ先にならない)
- gh のログインが要る (GitHub API で読む)。確かめられない名前があれば、ほかを出したうえで終了コード 2
- 固定した版は checkout の ps1 (と `releases.json`) から読む。setup を `--self-update` 無しで流した checkout は古いことがあるので、
  PR を作る前に origin/main の版も見る (3.)

## 2. ユーザーに聞く

名前ごとに 1 問にする (見送っていない新しい版がある名前だけ)。

- 選択肢は、猶予ごとの上げ先を重ねずに並べたもの (同じ版が 2 つの猶予の上げ先なら 1 つにまとめ、「2.1.323 (猶予 1・3 日)」の
  ように書く) と、「上げない」。出た日と URL を説明に添える
- 推奨は、`nix/release-age.nix` の `minimumReleaseAgeDays` (dotfiles の遅延の日数。今は 7) の上げ先。その上げ先が「無い」なら
  「上げない」を推奨にする (その日数たつまで待つ)。推奨を先頭に置き、label の末尾に「(推奨)」を付けて、理由を説明に書く
- 「上げない」なら続けて聞く: **見送る** (見送りの一覧に足す。今出ている新しい版は、次から setup も CI も知らせない) か、
  **今は決めない** (何もしない。次の setup でもまた出る)。見送るなら理由も聞く (一覧に書く)
- 話している相手がユーザーなら AskUserQuestion で聞く (1 回に 4 問・1 問に選択肢 4 つまで。溢れたら答えを受けてから続ける)。
  指揮役から動かされる子の会話では AskUserQuestion を使わず、問いと選択肢 (推奨を先頭に、理由つき) を報告に書いてターンを終える
- 答えを受けたら、決まったことを短く並べて返し、3. へ進む。「今は決めない」だけなら、ここで終わる

## 3. PR を作る

上げる・見送るが 1 つでもあれば、dotfiles に PR を 1 本作る (名前をまとめてよい)。

| 今の会話 | すること |
| --- | --- |
| 集約ハブ (`~/h`) | pjp-herdr-other-repo の手順で dotfiles の子に任せる。決まった版 (と見送る版と理由) と、この skill の名前を依頼に書く |
| dotfiles の worktree | 自分で直す。origin/main から branch を切る (`chore/win-<名前>-<版>` など。public な repo なので、チケットの ID は書かない) |
| ほかの repo | pjp-herdr-other-repo の手順 (herdr の外なら、進め方をユーザーに聞く) |

名前ごとに直す所:

| 名前 | 版を書く所 | 一緒に直す所 | 流すテスト | 上げ方 (`win/README.md`) |
| --- | --- | --- | --- | --- |
| `openssh` | `win/openssh/Install-OpenSSH.ps1` の `-Version` の既定値 | 「OpenSSH」の冒頭の「今は」 | `win/openssh/Install-OpenSSH.Tests.ps1` | 「OpenSSH の新しい版が出たとき」(入れずに試す手順がある) |
| `herdr` | `win/herdr/Install-Herdr.ps1` の同じ所 | 「herdr を入れる (winget)」の「今は」 | `win/herdr/Install-Herdr.Tests.ps1` | 「herdr の新しい版が出たとき」 |
| `google-japanese-input` | `win/google-japanese-input/Install-GoogleJapaneseInput.ps1` の同じ所 | (README に版は書いていない) | `win/google-japanese-input/Install-GoogleJapaneseInput.Tests.ps1` | 「Google 日本語入力の新しい版が出たとき」(上の「版を上げる」の 1〜5。この PC で上げて設定を読み書きできるかを確かめてから commit する) |
| `ntn` | `win/ntn/Install-Ntn.ps1` の同じ所 | 「ntn」の「今は」 | `win/ntn/Install-Ntn.Tests.ps1` | 「ntn の新しい版が出たとき」 |
| `claude-code` | `win/claude-code/Install-ClaudeCode.ps1` の同じ所 | 「Claude Code」の「今は」 | `win/claude-code/Install-ClaudeCode.Tests.ps1` | 「Claude Code の新しい版が出たとき」 |
| `herdr-app`・`herdr-core` | `nix/pkgs/herdr-core/releases.json` の版と sha256 (core は 3 つの target と generation) | 「herdr-app を入れる」の「今は」 | `win/herdr-app/Install-HerdrApp.Tests.ps1`・`nix build ./nix#checks.x86_64-linux.herdr-core-test` | 「固定した版を上げる」(sha256・core_min・generation・ソースが取得元の変数を読むかを確かめる) |

- 上げる前に、その節のとおり release notes (CHANGELOG) を読み、設定・置き場所・更新の仕組みに触る変更が無いかを見る。気になる変更が
  あれば、PR を出す前にユーザーに伝える
- 見送るなら、その名前の見送りの一覧 (候補の「見送るなら」の行のファイル) に 1 行足す。winget のものは「版 理由」、herdr-app・
  herdr-core は「app か core・版・理由」。今出ている新しい版を全部書く (1 つだけだと、残りの版でまた知らせる)
- origin/main の版が checkout の版と違えば (ほかの PR が先に上げた)、origin/main を正にして候補を出し直す。同じファイルを触る open の
  PR (`gh pr list --state open`) があれば重ねずに伝える (claude-skills の pjp-dep-update も同じ ps1 を上げる PR を作ることがある)
- テストを流し、pjp-gh-pr-create の手順で PR を出す。本文は dotfiles の CLAUDE.md の「この repo の PR・commit に書くもの」に従う
  (変えたこと・確かめたこと・反映の仕方。ユーザーとのやり取りは書かない)

## 4. merge の後

ユーザーが各マシンで `~/dotfiles/setup --self-update --update` を流す。名前ごとに揃い方が違うので、PR を返すときに添える。

| 名前 | setup --update のあと |
| --- | --- |
| `ntn`・`claude-code` | setup が揃える。exe が動いていると (Windows の Claude Code の会話を開いている・ntn が動いている) ⚠ で止まるので、閉じてから `Install-Ntn`・`Install-ClaudeCode` か `bootstrap-windows-*.sh --apply` |
| `herdr` | 差が ⚠ で出る。herdr の外の PowerShell で `hsvstop` を打ち、`herdr --remote` の窓も閉じてから `Install-Herdr` |
| `openssh` | 差が ⚠ で出る。Windows で動いている `ssh.exe` (herdr の remote など) を閉じてから `Install-OpenSSH` か `bootstrap-windows-openssh.sh --apply` (UAC が 1 回出る) |
| `google-japanese-input` | 差が ⚠ で出る。日本語入力を使っているアプリをできるだけ閉じてから `Install-GoogleJapaneseInput` (UAC の確認が出る) |
| `herdr-app`・`herdr-core` | setup がフィードを書き直して揃える (Linux のホストは switch で新しい herdr-core が入る) |

## 対象の外

- WSL・Linux の側の固定 (`nix/pkgs/ntn` の版・mise の道具・`nix/flake.lock`): pjp-dotfiles-update・pjp-dep-update
- type-clipboard (自作のアプリ。公開からの猶予を置かず、Release を出す流れで上げる。`win/README.md` の「type-clipboard の新しい版を
  出したとき」) と PowerToys (版を固定しない)
- 週 1 回の CI (`winget-versions` の猶予 30 日・`herdr-app-installers` の猶予 7 日) はこの skill と別に今までどおり知らせる。見送りの
  一覧はどちらにも効く
