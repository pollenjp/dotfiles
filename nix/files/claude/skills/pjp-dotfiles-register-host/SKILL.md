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
置く (dotfiles の ADR 026)。ローカル flake の雛形がその clone の `nix/` を読み、setup は `--host` なしでそのホストを選ぶ。
ローカル flake の値はそのホストに当たらない (ファイルが値の全部を持つ。前の雛形の `local` も当たらない)。

段階 3 (dotfiles の ADR 027) のあとは、setup は対象ホストを推測しない。公開の登録簿には型 (`<user>@<system>`) と `sandbox` しか無く、
登録も `~/dotfiles/flake.nix` の `tmp` も無い PC では、setup は止まって選べる道を出す。登録の前の 1 回は `--host <型>` で当てる。

決まった処理 (名前・調べる・下書き・比べる) は本体の `nix/scripts/private-host.sh` が持つ。この skill は手順・判断・確認の取り方を教える。

## はじめにユーザーへ伝える

登録は 2 段で、**2 段目までやらないと `--host` の付け忘れは直らない**。最初にこれを伝えてから始める。

1. dotfiles-private に `nix/hosts/<名前>.nix` を足す PR (この登録で世代の中身が変わらないことを比べてから)
2. PR の merge のあと、この PC の `~/dotfiles/flake.nix` を今の雛形へ移す (dotfiles-private の入力が clone の `nix/` を指す)

dotfiles 本体が ADR 026 の版 (`nix/scripts/private-host.sh` と `lib.privateHosts` がある) であることも要る。無ければ先に本体を新しくする。
2 段目を済ませるまで、`--host` なしの setup はこの PC のホストを選べない (段階 3 のあとは止まる。それまでは `--host <型>` で当てる)。

## 書く前に必ず確認を取る

関門は 2 つ。どちらも「登録して」「さっとやって」と頼まれていても同じ (頼まれたのは登録で、何が変わるかはまだ見せていない)。

| 関門 | 見せるもの |
| --- | --- |
| dotfiles-private の作業ツリーに書く前 | 下の「確認の形 (登録)」 |
| `~/dotfiles/flake.nix` を書き換える前 | 下の「確認の形 (merge のあと)」 |

下書きは scratchpad に描き、比べるのも scratchpad の写しで先にできる。dotfiles-private の作業ツリーには、確認の答えが来てから置く。

## どの会話が何をするか

| 手順 | する会話 |
| --- | --- |
| 1 調べる・2 下書きと確認 | その PC の会話 (今の世代とローカル flake はその PC にしか無い。読むだけ) |
| 3 書く・4 比べる・5 PR | dotfiles-private の worktree の会話。今の会話が集約ハブ (`~/h`) や別の repo なら、pjp-herdr-other-repo の手順で dotfiles-private の子に、確かめた下書きと元にしたホストを渡して任せる |
| 6 merge のあとのローカル flake | その PC の会話 (repo の外のユーザーのファイル) |

## 前提

- `<p>` は ADR 026 以降の本体の `nix/scripts/private-host.sh` のフルパス。`bash <p> <コマンド>` で流す (Bash tool はシェルの変数を
  次の呼び出しへ持ち越さない)。`draft` と `compare` が評価する本体は、どちらも既定でこの script の repo の `nix/` (ローカル flake が
  別の本体を指していても揃える)
- **比べる間、本体の checkout を動かさない** (pull・編集・別の作業の commit)。`path:` の入力は narHash で lock されるので、途中で
  変わると比べ方がずれる。動きうるなら、`git -C <本体> status` で commit していない変更が無いことを見てから
  `git -C <本体> archive HEAD nix | tar -x -C <scratchpad>/body` で写し、その `<scratchpad>/body/nix/scripts/private-host.sh` を
  `<p>` にする (draft・compare とも)。写しが効くのは private-host.sh だけ (local-flake-migrate.sh は git の履歴とローカル flake の本体を使う)
- 作業場所・下書きは Claude の scratchpad に作る。`~/dotfiles` と dotfiles-private の main の clone (setup が取る場所) には書かない
- 秘密 (API キー・トークン) を書かない (`~/.config/pjp/env` のもの)。dotfiles-private の `nix/` は誰でも読める `/nix/store` に入る
- private の値 (hostname・Windows のユーザー名・option の値) を public の repo (dotfiles の文書・テスト・skill・PR の本文) に書かない
- PR を出すなら、その会話のチケットに結ぶ (pjp-dev-tracker。dotfiles-private の repo の行)
- **元にするホストが段階 3 で公開の登録簿から消えた PC** (`pollenjp@wsl`・`pollenjp@wsl-no-1password`・`pollenjp@laptop` で当てていた、
  まだ登録していない PC): 今の本体ではそのホストを評価できない (draft が 3)。消す前の本体を写し、その `nix/` を draft と compare の
  `--nix-dir` に渡す。merge のあとの比べ直し (手順 6 の 2) も同じ写しで行う

  ```sh
  # 段階 3 で実機の行を消した commit の 1 つ前 (まだ実機の行がある)
  rev=$(git -C <本体> log -1 --format=%H -S'"pollenjp@wsl" = mkHome' -- nix/hosts/default.nix)^
  mkdir -p <scratchpad>/pre-stage3 && git -C <本体> archive "${rev}" nix | tar -x -C <scratchpad>/pre-stage3
  bash <p> draft --base pollenjp@wsl --nix-dir <scratchpad>/pre-stage3/nix --out <scratchpad>/draft/<名前>.nix
  ```

  写しの本体は Dev Tracker の既定が今と違うことがある。下書きに `claude.devTracker.enable` があるか (使う PC なら true) を確かめる

## 手順

### 1. 調べる (その PC)

`bash <p> inspect` を読む。

- **ホストの名前** (`<user>@<短い hostname>`): ファイル名になる。setup はこの名前を探すので、別の名前にしない
- **この PC のホスト**: 「ある」なら登録済み。下の「既に登録した PC」へ
- **setup が --host なしで選ぶホスト**: 登録していない PC では「決まらない (setup は止まる)」か、`~/dotfiles/flake.nix` に足した `tmp`
- **一致するホスト**: 今の世代と outPath が一致したホスト。これを元にする (`--base`)。新しい PC で 1 回目を型で当てたなら、その型
- **一致するホストが無い** (本体が最後の switch から進んだ・別の本体で switch した。「lock を写しで張り直して評価した」と
  出ていれば、本体が変わっているので一致しないのは想定どおり): 元にするホストを黙って決めない。
  - その PC について前に決めた値 (チケットの決定・登録の依頼・設計の spec。最初の登録は dotfiles の ADR 026 からリンクした spec) が
    あれば、それを推奨の根拠にする。今の世代と違うなら、その違い (例: 署名が外れる) を確認で書く
  - 手がかり: 今の世代 (`readlink -f ~/.local/state/nix/profiles/home-manager`) と前の世代
    (`~/.local/state/nix/profiles/home-manager-<n>-link`) の `home-files/.config/git/config` の署名 (`gpgSign`)、ローカル flake の値 (前の
    雛形の `local`・`tmp`) が当たっているか (cc-pages の port など)。値の違う候補を並べる (今の登録簿は型だけなので、候補は型と
    `tmp`。段階 3 の前に当てていたホストなら、上の「前提」の写しの本体の `pollenjp@laptop` (署名あり) と `pollenjp@x86_64-linux`
    (署名なし) など)。
    今の世代がどの候補の形かを確かめるなら、compare の作業場所 (`--out`) の `old/` で候補の
    `config.xdg.configFile."git/config".text` を `nix eval --raw` し、世代の `home-files/.config/git/config` と `diff` する
  - 候補ごとに下書きを描いて比べ (手順 2。置き場所は `draft/<候補>/`・`preview/<候補>/` のように分ける)、ホストの問いと下書きの確認を
    1 回にまとめてよい。推す候補が今の世代の形と違うなら、`compare --base <今の世代の形の候補> --private <推す候補の preview>` の
    `config.dotfiles` の違いが「登録で今の世代から変わる値」になる
- **WSL**: Windows のユーザー名。下書きの `wsl.windowsUserName` と合うか (型を元にすると下書きに `wsl` が無い。下の「型を元にする」)
- **local の行 (前の雛形)**: dotfiles の option の外の行 (`programs.*` など) は下書きに入らない。今の雛形なら「local: 無い」

### 2. 下書きを描いて確かめる (その PC)

1. `bash <p> draft --base <元のホスト> --out <scratchpad>/draft/<名前>.nix`
   (元のホストが段階 3 で消えたなら `--nix-dir <scratchpad>/pre-stage3/nix`。「前提」)
2. 読む: 値 (`mkHome` の引数と `modules`)・`# TODO:` の行 (値を書き出せなかった option)・頭のコメントの notes (dotfiles の外の local の
   行。要るなら `modules` に足す、要らないなら消す。どちらかはユーザーに聞く)。既定と同じ値を明示した行 (例: `gitViaGh.enable = true`)
   も描かれる。書いた意図はユーザーにしか分からないので消さない
3. 確認の前に比べる (書くのは scratchpad だけ): `<scratchpad>/preview/nix/hosts/<名前>.nix` に下書きを写し、
   `bash <p> compare --base <元のホスト> --private <scratchpad>/preview`。読み方は手順 4 の表
4. 初めての登録 (dotfiles-private の README に `nix/hosts/` が無い) なら、README に足す行と節の下書きも作る (何を置くか・`/nix/store` に
   入ること・登録はこの skill で)
5. 型を元にしたとき (新しい PC) は、下の「型を元にする登録」で値を足してから確認に進む
6. 「確認の形 (登録)」で出し、答えが来るまで次へ進まない

#### 型を元にする登録 (新しい PC)

型 (`<user>@<system>`) には PC の値が無いので、下書きは `username`・`system` (と、前の雛形の `local` の値) だけになる。その PC で要る値を
足す。どれを入れるかは推奨と理由を添えてユーザーに聞く (足した分だけ、compare は 1 になる。それで正しい)。

| 値 | 足すとき |
| --- | --- |
| `wsl = { enable = true; windowsUserName = "<inspect の値>"; };` | WSL の PC (inspect の「WSL: はい」)。Windows のユーザー名は inspect が出す |
| `wsl.windowsFiles.enable = true;`・`wsl.exeExecTrace.enable = true;` | WSL の PC で、win/ を Windows へ配る・.exe の起動を記録する (ADR 010・012。exeExecTrace は setup が sudo を呼ぶ) か聞く |
| `onePassword.enable = true;` | 1Password で git の署名をする PC か聞く (WSL なら Windows 側の 1Password。`windowsUserName` が要る) |
| `claude.devTracker.enable = true;` | Notion Dev Tracker を使う PC (本体の既定は使わない)。使うなら `claude.notion.profile` も |
| `claude.notion.profile = "personal";` など | Notion へ書く skill を使う PC (`"personal"` / `"work"`) |

ほかの値 (`gitViaGh`・`notion.routes`・`videoOffer.autoStart`・`modules` の `dotfiles.ccPages.port` など) は、ユーザーが望んだときだけ。
例と説明は dotfiles の雛形 (`setup-local-flake.sh`) の `tmp` の例にある。

### 3. dotfiles-private に書く (dotfiles-private の worktree)

- setup が取る clone の main では branch を切らない・書かない (bootstrap-dotfiles-private は、未コミットの変更や upstream の無い branch では
  取得を飛ばす)。pjp-herdr-other-repo の herdr の worktree か、herdr を使わない会話なら
  `git -C <clone> worktree add <場所> -b <branch> origin/main`
- 確かめた下書きを `nix/hosts/<名前>.nix` に置く (頭のコメントは残す。merge のあと、元にしたホストをそこから引く)。README も確かめた形で

### 4. 比べる (dotfiles-private の worktree)

`bash <p> compare --base <元のホスト> --private <worktree>` (ローカル flake はその PC の `~/dotfiles`。写しなら `--flake <写し>`)

| 終了コード | 意味 | すること |
| --- | --- | --- |
| 0 | 旧い形 (元のホスト。前の雛形なら + local) と登録したホストの drvPath が同じ | この登録で世代の中身は変わらない。次へ |
| 1 | 違う | 出力の `config.dotfiles の違い (旧い → 新しい)` を読む。下書きの誤りなら直して比べ直す。ユーザーが値を変えると決めた違い (型を元にして値を足した、など) なら、PR の本文にそう書く |
| 2 | 使い方の誤り・登録のファイルが無い | 出力のとおり直す |
| 3 | 旧い形が評価できない | 今の local が今の本体と合わない (option の削除など)。pjp-dotfiles-local-flake-migrate の「旧い flake が評価できないとき」 |
| 4 | 登録したホストが評価できない | ファイルの誤り (構文・option の名前)。直して比べ直す |

「中身が同じ」は今の世代との一致では決めない (本体を進めると、skill を 1 つ足しただけでも世代が変わる)。出力の「参考: 今の世代 …」は参考。

### 5. commit・push・PR (dotfiles-private の worktree)

`nix/hosts/<名前>.nix` (と README) を commit して PR を出す。merge はユーザー。PR の本文に元にしたホストと compare の結果
(drvPath が同じ) を書く。

### 6. merge のあと (その PC)

1. clone を新しくする: `~/dotfiles/setup --steps private-fetch` (取得して fast-forward するだけで、switch しない。確認なしで流してよい)
2. merge のあとの本体と clone で比べ直す: `bash <p> compare --base <元のホスト> --private <clone>` が 0 (型を元にして値を足したなら、
   足した分だけ 1)。元のホストは、登録したファイルの頭のコメント (「元にしたホスト: …」) にある。段階 3 で消えたホストなら、
   「前提」の写しの本体を `--nix-dir` に渡す
3. ローカル flake が clone の `nix/` を読む形にする (dotfiles-private の入力を stub から clone へ指し直す)。道は 2 つ:
   - **値を書き足していない雛形** (新しい PC で 1 回目に置いたまま。`tmp` もほかの行も足していない): `<本体>/nix/scripts/setup-local-flake.sh --force`
     で作り直す (今の雛形で clone の `nix/` を読む。退避は取らないので、`diff` で値が無いことを見せて確認を取ってから。nixos-config の
     README の入れ直しの手順と同じ)。作り直したら 7 へ
   - **値を書き足したあと** (前の雛形の `local` に値がある・`tmp` を足した): pjp-dotfiles-local-flake-migrate の手順 (prepare → 衝突 →
     compare)。prepare が dotfiles-private の入力を足す (指し直す)。この時点の compare で、登録簿のホストが全部「同じ」で、この PC の
     ホストが「dotfiles-private のホスト (…この PC のホスト)」と出ることを見る (移すこと自体は値を落としていない。前の雛形から今の雛形へ
     移すときに `local` の値が型のホストから外れる分は「違う」と出る。pjp-dotfiles-local-flake-migrate の「段階 3 の雛形へ移すとき」)。
     prepare が「移すものはありません」と出したら (ローカル flake が既に今の雛形で clone の `nix/` を読んでいる)、`prepare --always` で
     作業場所を作る (new/flake.nix は今のファイルと同じ)。その compare では、この PC のホストは両側にあるので「同じ」と出る
4. `<作業場所>/new/flake.nix` で、登録したファイルへ移した値をローカル flake から外す。前の雛形なら `local` を雛形の既定に戻し (例:
   `devTracker.enable = false`・`notion.profile = null`・port の行はコメントに戻す)、今の雛形なら足していた `tmp` を消す (**残すと `tmp` が
   登録したホストより先に選ばれる**)。**既定と同じ値を明示した行 (`gitViaGh.enable = true` など) も外す** (登録したファイルに残っている。
   pjp-dotfiles-local-flake-migrate の「既定と同じ値をあえて書いた行は消さない」は、移すだけのときの決まり)。手で足したホストも module も
   無ければ、外したあとの `new/flake.nix` は `<作業場所>/template.nix` と同じになる (`diff` で確かめられる)
5. もう一度 compare: 1 になり、違いは外した値の分 (登録簿のホスト) と、この PC のホストが足されることだけ、を確かめる。apply の前に
   `DOTFILES_LOCAL_DIR=<作業場所>/new bash <本体>/nix/scripts/setup.sh --which-host` が `<名前><TAB>private` を出すことも見る
6. 「確認の形 (merge のあと)」で出して承認を取り、`apply --accept-changes`
7. `~/dotfiles/setup --which-host` が `<名前><TAB>private` を出すことを確かめ、`~/dotfiles/setup --update` を流してよいかを聞く
   (`--host` は付けない。この PC で switch する)

## 既に登録した PC (値を直す)

- `inspect` の「この PC のホスト: … (ある)」。ローカル flake がまだ clone の `nix/` を読んでいなければ、手順 6 の 3〜7 を先にする
  (入れ直した PC など、登録済みで値を書き足していない雛形なら、手順 6 の 3 の `setup-local-flake.sh --force`)
- 元にするホストは今のそのホスト (`--base <名前>`)。直したい値を反映した下書きを作り、今のファイルとの差 (`diff -u`) を見せて確認を
  取る (手順 2 と同じ関門)
- `compare --base <名前> --private <worktree>` は直した値の分だけ違う (1)。今と同じなら何もしない

## 確認の形 (登録)

手順 3 の前に、この順で出す。

1. 何をするか: dotfiles-private に `nix/hosts/<名前>.nix` (初めてなら README も) を足す PR を出す。merge のあとローカル flake を移すまで、
   setup はまだそのホストを選ばない
2. 元にしたホストと、そう決めた理由 (今の世代と一致した・前に決めた値・一致しないので推した、など)
3. 下書きの全文 (と README の追記)
4. compare の結果 (scratchpad の写しで比べた値)。登録で変わる所・変わらない所: 署名 (`onePassword`)・Notion の宛先 (`notion.profile`)・
   Dev Tracker・cc-pages の port・WSL の値。型を元にして足した値は、変わる所として並べる。2 段目のあとに `--host <型>` で当てると、値は
   登録したファイルではなく本体の既定から来る (Dev Tracker も off。setup は警告するだけ) ことも書く
5. notes (前の雛形の `local` の、dotfiles の外の行) と `# TODO:` の行をどうするか
6. 問い: 「この内容で dotfiles-private に登録してよいですか」(残る判断は、推奨と理由を添えて選択肢ごとに)

## 確認の形 (merge のあと)

pjp-dotfiles-local-flake-migrate の「確認の形」に、次を足す。

- `--host` なしで当たるホストの中身は変わらない (手順 6-2 の compare が 0)。apply が「値が変わるので反映は setup --update」と出すのは
  登録簿のホストの話で、`setup --update` は lock を張り直し、登録したホストへ切り替えるために流す
- ローカル flake から外した値 (前の雛形の `local`・`tmp`) と、外したあとに効く場面 (前の雛形の `local` は、`--host <型>` で当てたときだけ。
  `tmp` は消すので効かない)。`setup-local-flake.sh --force` で作り直すなら、作り直す前と後の差分 (stub → clone の 1 行と、雛形の版の印)
- `DOTFILES_LOCAL_DIR=<作業場所>/new` の `--which-host` が `<名前><TAB>private` だったこと

## よくある誤り

| やりがちなこと | どうするか |
| --- | --- |
| 確認の前に dotfiles-private の作業ツリーに書く | 下書きと比べるのは scratchpad。確認の答えのあとで置く |
| dotfiles-private の main の clone で branch を切る・書く | 別の worktree に書く |
| 今の世代と一致するかで「中身が同じ」を決める | compare (同じ本体・同じ lock の旧い形と新しい形) で決める |
| 下書きを手で一から書く | draft が描く (既定と同じ明示の値・WSL の値も) |
| 登録の PR を出して終わる | merge のあとローカル flake を移すまで setup は選ばない。`--which-host` で確かめる |
| 比べている間に本体を pull・編集する | 本体を写して使う |
| ファイル名を好きな名前にする | `private-host.sh name` の名前 (setup がその名前を探す) |
| 一致するホストが無いのに、setup が選ぶホストや型で黙って進める | 前に決めた値と候補を並べてユーザーに確かめる (署名の有無などで値が変わる) |
| 移したあとも local に値を残す (既定と同じ明示の値も) | 登録したファイルが持つので外す。残すと 2 か所に同じ値が並び、片方だけ直してずれる |
| 登録したのに `tmp` を残す | `tmp` が登録したホストより先に選ばれる (ローカル flake のホストが先)。外す |
| 型を元にした下書きをそのまま登録する | 型には PC の値が無い (WSL・署名・Dev Tracker など)。要る値を聞いて足す |
| 段階 3 で消えたホストを、今の本体で draft・compare する | 評価できない (3)。消す前の本体を写して `--nix-dir` に渡す (「前提」) |
| 値を書き足した flake を `setup-local-flake.sh --force` で作り直す | 値と足したホストが消える (退避も無い)。値があれば local-flake-migrate.sh で移す |
| private の値を dotfiles の PR の本文や文書に書く | private の値は dotfiles-private の中だけ |

## 関連

- dotfiles の `nix/README.md`「dotfiles-private に登録したホスト」「新規マシンの手順」・ADR 026・ADR 027
- pjp-dotfiles-local-flake-migrate — 手順 6 の、ローカル flake を今の雛形へ移す側
- pjp-herdr-other-repo — dotfiles-private の worktree を作る・子に任せる
- pjp-dev-tracker — PR とチケットを結ぶ
