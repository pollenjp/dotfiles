---
name: pjp-dotfiles-register-host
description: この PC (Linux / macOS / WSL) の home-manager のホストを、dotfiles-private の nix/hosts/<user>@<hostname>.nix に
  登録するとき・登録した値を直すときに使う。「この PC を dotfiles-private に登録して」「--host を付け忘れる」「PC ごとに
  ~/dotfiles/flake.nix を切り替えるのが面倒」「ホストの値を private に置きたい」と言われたとき、setup が「dotfiles-private に、
  この PC のホスト … があります」「この PC は dotfiles-private に … として登録されていますが」と知らせたとき、登録の PR が merge
  されて ~/dotfiles/flake.nix を仕上げるとき、新しい PC を登録するときに読む。ローカル flake を今の雛形へ移すだけの話は
  pjp-dotfiles-local-flake-migrate の側。
---

# pjp-dotfiles-register-host

その PC のホストの定義と値の全部を、private な dotfiles-private の `nix/hosts/<user>@<短い hostname>.nix` に 1 PC 1 ファイルで
置く (dotfiles の ADR 025)。ローカル flake の雛形がその clone の `nix/` を読み、setup は `--host` なしでそのホストを選ぶ。
ローカル flake の `local` はそのホストに当たらない (ファイルが値の全部を持つ)。

決まった処理 (名前・調べる・下書き・比べる) は本体の `nix/scripts/private-host.sh` が持つ。この skill は手順・判断・確認の取り方を教える。

## はじめにユーザーへ伝える

登録は 2 段で、**2 段目までやらないと `--host` の付け忘れは直らない**。最初にこれを伝えてから始める。

1. dotfiles-private に `nix/hosts/<名前>.nix` を足す PR (この登録で世代の中身が変わらないことを比べてから)
2. PR の merge のあと、この PC の `~/dotfiles/flake.nix` を今の雛形へ移す (dotfiles-private の入力が clone の `nix/` を指す)

dotfiles 本体が ADR 025 の版 (`nix/scripts/private-host.sh` と `lib.privateHosts` がある) であることも要る。無ければ先に本体を新しくする。

## 書く前に必ず確認を取る

関門は 2 つ。どちらも「登録して」「さっとやって」と頼まれていても同じ (頼まれたのは登録で、何が変わるかはまだ見せていない)。

| 関門 | 見せるもの |
| --- | --- |
| dotfiles-private の作業ツリーに書く前 | 下書きの全文と、登録で振る舞いが変わる所 (下の「確認の形」) |
| `~/dotfiles/flake.nix` を書き換える前 | 差分 (pjp-dotfiles-local-flake-migrate の「確認の形」) |

下書きは scratchpad に描く。dotfiles-private の作業ツリーには、確認の答えが来てから置く。

## どの会話が何をするか

| 手順 | する会話 |
| --- | --- |
| 1 調べる・2 下書きの確認 | その PC の会話 (今の世代とローカル flake はその PC にしか無い。読むだけ) |
| 3 書く・4 比べる・5 PR | dotfiles-private の worktree の会話。今の会話が集約ハブ (`~/h`) や別の repo なら、pjp-herdr-other-repo の手順で dotfiles-private の子に、確かめた下書きと元にしたホストを渡して任せる |
| 6 merge のあとのローカル flake | その PC の会話 (repo の外のユーザーのファイル) |

## 前提

- `<p>` は ADR 025 以降の本体の `nix/scripts/private-host.sh` のフルパス。`bash <p> <コマンド>` で流す (Bash tool はシェルの変数を
  次の呼び出しへ持ち越さない)。比べる (`compare`) ときの本体は、既定でこの script の repo の `nix/`
- **比べる間、本体の checkout を動かさない** (pull・編集・別の作業の commit)。`path:` の入力は narHash で lock されるので、途中で
  変わると比べ方がずれる。変わりうるなら `git -C <本体> archive HEAD nix | tar -x -C <scratchpad>/body` で写し、その
  `<scratchpad>/body/nix/scripts/private-host.sh` を使う
- 作業場所・下書きは Claude の scratchpad に作る。`~/dotfiles` と dotfiles-private の main の clone (setup が取る場所) には書かない
- 秘密 (API キー・トークン) を書かない (`~/.config/pjp/env` のもの)。dotfiles-private の `nix/` は誰でも読める `/nix/store` に入る
- private の値 (hostname・Windows のユーザー名・option の値) を public の repo (dotfiles の文書・テスト・skill・PR の本文) に書かない

## 手順

### 1. 調べる (その PC)

`bash <p> inspect` を読む。

- **ホストの名前** (`<user>@<短い hostname>`): ファイル名になる。setup はこの名前を探すので、別の名前にしない
- **この PC のホスト**: 「ある」なら登録済み。下の「既に登録した PC」へ
- **一致するホスト**: 今の世代と outPath が一致したホスト。これを元にする (`--base`)
- **一致するホストが無い** (本体が最後の switch から進んだ・別の本体で switch した): 元にするホストを決めずに、setup が選ぶホスト
  (推測) と、登録簿で値の違う候補 (例: 署名の入る `pollenjp@laptop` と入らない `pollenjp@x86_64-linux`) を並べ、推奨と理由を
  添えてユーザーに確かめる。手がかりは、前の世代 (`~/.local/state/nix/profiles/home-manager-<n>-link`) を `inspect` と同じ形で
  評価して一致するか、今の世代の `home-files/.config/git/config` の署名 (`gpgSign`) など。深追いする前に聞いてよい
- **WSL**: Windows のユーザー名。下書きの `wsl.windowsUserName` と合うか
- **local の行**: dotfiles の option の外の行 (`programs.*` など) は下書きに入らない

### 2. 下書きを描いて確かめる (その PC)

`bash <p> draft --base <元のホスト> --out <scratchpad>/<名前>.nix`

- 読む所: 値 (`mkHome` の引数と `modules`)・`# TODO:` の行 (値を書き出せなかった option)・頭のコメントの notes
  (dotfiles の外の local の行。要るなら `modules` に足す、要らないなら消す。どちらかはユーザーに聞く)
- 既定と同じ値を明示した行 (例: `gitViaGh.enable = true`) も描かれる。書いた意図はユーザーにしか分からないので消さない
- 下の「確認の形 (下書き)」で出し、答えが来るまで次へ進まない

### 3. dotfiles-private に書く (dotfiles-private の worktree)

- dotfiles-private の main の checkout (setup が取る clone) には書かない。branch を切った worktree に書く (pjp-herdr-other-repo)
- 確かめた下書きを `nix/hosts/<名前>.nix` に置く (頭のコメントは残してよい)
- README.md に `nix/hosts/` の行と節が無ければ足す (何を置くか・`/nix/store` に入ること・登録はこの skill で)

### 4. 比べる (dotfiles-private の worktree)

`bash <p> compare --base <元のホスト> --private <worktree>` (ローカル flake はその PC の `~/dotfiles`。写しなら `--flake <写し>`)

| 終了コード | 意味 | すること |
| --- | --- | --- |
| 0 | 旧い形 (元のホスト + local) と登録したホストの drvPath が同じ | この登録で世代の中身は変わらない。次へ |
| 1 | 違う | 出力の `config.dotfiles の違い (旧い → 新しい)` を読む。下書きの誤りなら直して比べ直す。ユーザーが値を変えると決めた違いなら、PR の本文にそう書く |
| 2 | 使い方の誤り・登録のファイルが無い | 出力のとおり直す |
| 3 | 旧い形が評価できない | 今の local が今の本体と合わない (option の削除など)。pjp-dotfiles-local-flake-migrate の「旧い flake が評価できないとき」 |
| 4 | 登録したホストが評価できない | ファイルの誤り (構文・option の名前)。直して比べ直す |

「中身が同じ」は今の世代との一致では決めない (本体を進めると、skill を 1 つ足しただけでも世代が変わる)。出力の「参考: 今の世代 …」は参考。

### 5. commit・push・PR (dotfiles-private の worktree)

`nix/hosts/<名前>.nix` (と README) を commit して PR を出す。merge はユーザー。PR の本文に元にしたホストと compare の結果
(drvPath が同じ) を書く。

### 6. merge のあと (その PC)

1. clone を新しくする: `~/dotfiles/setup --steps private-fetch` (か `git -C <clone> pull --ff-only`)
2. merge のあとの本体と clone で比べ直す: `bash <p> compare --base <元のホスト> --private <clone>` が 0
3. ローカル flake を今の雛形へ移す: pjp-dotfiles-local-flake-migrate の手順 (prepare → 衝突 → compare)。prepare が dotfiles-private の
   入力を足す (指し直す)
4. `<作業場所>/new/flake.nix` で、登録したファイルへ移した値を `local` から外し、雛形の既定に戻す (例: `devTracker.enable = false`・
   `notion.profile = null`・port の行はコメントに戻す)。外した値は、登録簿のホストを `--host` で当てたときにしか効かない
5. migrate の compare は 1 になる: 登録簿のホストは外した値の分だけ違い、この PC のホストは「dotfiles-private のホスト (移した
   flake だけ。この PC のホスト)」と出る (setup の選ぶホストが変わる)。この 2 つが出る違いの全部なら、確認の形で見せて承認を取り、
   `apply --accept-changes`
6. `~/dotfiles/setup --which-host` が `<名前><TAB>private` を出すことを確かめ、`~/dotfiles/setup --update` を流してよいかを聞く
   (`--host` は付けない。この PC で switch する)

## 既に登録した PC (値を直す)

- `inspect` の「この PC のホスト: … (ある)」。元にするホストは今のそのホスト (`--base <名前>`)。ローカル flake がまだ clone の
  `nix/` を読んでいなければ、手順 6 の 3〜4 を先にする
- 直したい値を反映した下書きを作り、今のファイルとの差 (`diff -u`) を見せて確認を取る (手順 2 と同じ関門)
- `compare --base <名前> --private <worktree>` は直した値の分だけ違う (1)。今と同じなら何もしない

## 確認の形 (下書き)

手順 3 の前に、この順で出す。

1. 何をするか: dotfiles-private に `nix/hosts/<名前>.nix` を足す PR を出す。merge のあとローカル flake を移すまで、setup はまだ
   そのホストを選ばない
2. 元にしたホストと、そう決めた理由 (今の世代と一致した・一致しないので推測した、など)
3. 下書きの全文
4. 登録で変わる所・変わらない所: 署名 (`onePassword`)・Notion の宛先 (`notion.profile`)・Dev Tracker・cc-pages の port・WSL の値。
   compare を流していれば、その結果
5. notes (dotfiles の外の local の行) と `# TODO:` の行をどうするか
6. 問い: 「この内容で dotfiles-private に登録してよいですか」(残る判断は、推奨と理由を添えて選択肢ごとに)

## よくある誤り

| やりがちなこと | どうするか |
| --- | --- |
| 確認の前に dotfiles-private の作業ツリーに書く | 下書きは scratchpad。確認の答えのあとで置く |
| dotfiles-private の main の clone に書く・commit する | branch を切った worktree に書く |
| 今の世代と一致するかで「中身が同じ」を決める | compare (同じ本体・同じ lock の旧い形と新しい形) で決める |
| 下書きを手で一から書く | draft が描く (既定と同じ明示の値・WSL の値も) |
| 登録の PR を出して終わる | merge のあとローカル flake を移すまで setup は選ばない。`--which-host` で確かめる |
| 比べている間に本体を pull・編集する | 本体を写して使う |
| ファイル名を好きな名前にする | `private-host.sh name` の名前 (setup がその名前を探す) |
| 一致するホストが無いのに、推測のホストで黙って進める | 候補を並べてユーザーに確かめる (署名の有無などで値が変わる) |
| private の値を dotfiles の PR の本文や文書に書く | private の値は dotfiles-private の中だけ |

## 関連

- dotfiles の `nix/README.md`「dotfiles-private に登録したホスト」・ADR 025
- pjp-dotfiles-local-flake-migrate — 手順 6 の、ローカル flake を今の雛形へ移す側
- pjp-herdr-other-repo — dotfiles-private の worktree を作る・子に任せる
