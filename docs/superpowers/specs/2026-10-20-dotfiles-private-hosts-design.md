# ホストの定義と値を dotfiles-private へ移す — 設計 (TKT-245)

- チケット: [TKT-245](https://app.notion.com/p/dotfiles-private-nix-host-PC-dotfiles-flake-nix-3ff79149a66f81ecab8ac9d144f866c1)
  (集約ハブの会話のチケット。dotfiles と dotfiles-private の作業はそれぞれの子のチケットに束ねる)
- 方針は 2026-10-20 にユーザーが承認した (段階 1)。この文書はその書き写しと、実装に要る細部
- 承認のときにユーザーが決めたこと:
  - lavie には git の署名 (1Password) を **入れない** (推奨は「入れる」だったが、ユーザーは入れないを選んだ)
  - 公開の登録簿から実機 (`pollenjp@wsl`・`pollenjp@laptop`) を消すのは **段階 3** (実機が全部 private に移ってから)
- 関連: ADR 002 (登録簿とローカル flake)・ADR 015 / 016 (dotfiles-private を public の flake input にしない)・
  ADR 024 と TKT-228 (ローカル flake の雛形の版の印と移行)・ADR 022 (1Password を WSL の外でも使う)

## 背景と意図

いまマシンごとの差は 3 か所に分かれている。

| 場所 | 中身 | git |
| --- | --- | --- |
| `nix/hosts/default.nix` (public の登録簿) | 型 (`pollenjp@x86_64-linux`・`aarch64-linux`・`aarch64-darwin`・`sandbox`) と実機 (`pollenjp@wsl` (Windows のユーザー名入り)・`pollenjp@wsl-no-1password`・`pollenjp@laptop` (lavie)) | public |
| `~/dotfiles/flake.nix` (ローカル flake) の `local` と手で足したホスト | マシンごとの option の値 (devTracker・gitViaGh・notion.profile・ccPages.port など) | 管理外 |
| setup のホストの決め方 | `--host` → `DOTFILES_HOST` → ローカル flake が定義するホスト → `$USER` と uname からの推測 | — |

困っていること (ユーザーの言葉: 「wsl の pc で option 周りを修正したり等した。`~/dotfiles/setup --self-update --update` で
更新することがおおく、host を指定し忘れてしまうことがおおい」「いまは dotfiles という public な repository で管理しようと
しているけど、これを dotfiles-private 側に移すにはどうするかの方が大事だと思う」):

- **--host の付け忘れ。** lavie (NixOS の実機) の今の home-manager の世代は、`pollenjp@x86_64-linux` の
  `activationPackage` の outPath と一致し、登録簿の `pollenjp@laptop` とは違った (2026-10-20 に `nix eval` で確かめた)。
  ローカル flake がホストを持たず `DOTFILES_HOST` も無いので、setup が推測した。nixos-config の README は
  「`--host` は省かない」と書いているが、毎回覚えておく必要がある
- **値が PC ごとの手書き。** `local` の値は各 PC の git 管理外のファイルにしか無く、雛形が変わるたびに PC ごとに移す
  (TKT-228 で道具は作った)
- **実機の情報が public にある。** public に載せたくない差分はローカル flake に書く決まりだが、そうすると上の手書きに戻る

dotfiles-private (pollenjp/dotfiles-private) は今 `ssh/` (ssh の接続先) と `google-japanese-input/` (辞書) を持ち、
`nix/scripts/bootstrap-dotfiles-private.sh` (order 50。switch の **後**) が ghq の下へ clone / fast-forward する。
public の repo の flake input や submodule にはしない決まり (ADR 015 / 016: public な repo に private の rev を残さない)。

## ゴール

1. dotfiles-private に `nix/hosts/<user>@<hostname>.nix` を置く。1 実機 1 ファイルで、中身はその PC のホストの定義と値の全部
   (今の登録簿のエントリと同じ `mkHome` の引数 + `local` に書いていた値)。ファイル名から `.nix` を除いたものがホストの名前
2. ローカル flake の雛形が dotfiles-private の `nix/` を `path:` の input に取り、そのホストを `homeConfigurations` に足す。
   登録した PC の `~/dotfiles/flake.nix` は雛形のままで済む
3. setup は `--host` を付けなくても、登録した PC では `<user>@<hostname>` のホストで switch する。dotfiles-private は
   switch の **前に** 取る
4. skill `pjp-dotfiles-register-host` が、今いる PC を dotfiles-private に登録する手順を Claude に教える
   (調べる → 下書きを見せて確かめる → private の branch に書く → 評価して比べる → PR → merge 後の片付け)
5. この PC (lavie) を `pollenjp@lavie` として登録する (dotfiles-private の PR。4 の skill を通して作る)
6. 決定を ADR 025 に残し、README などの文書を今の形に揃える

## 非ゴール

- 公開の登録簿から実機 (`pollenjp@wsl`・`pollenjp@wsl-no-1password`・`pollenjp@laptop`) を消すこと (段階 3)。
  この段階では 1 行も消さない
- WSL の PC の登録 (段階 2。その PC で、後日 skill を呼ぶ)
- nixos-config (system 側と README) を直すこと (段階 3)
- dotfiles-private を public の repo の flake input・submodule にすること
- setup が `~/dotfiles/flake.nix` を自動で書き換えること (書き換えは今までどおり、script / skill を明示して流したときだけ)
- 会社の PC など、dotfiles-private を取らないマシンを private に載せること (今までどおり public の型とローカル flake で動く)
- 秘密 (API キー・トークン) の置き場所を変えること。今までどおり `~/.config/pjp/env`

## アンチゴール (技術的に動いても失敗とみなすもの)

- public の CI が dotfiles-private を要るようになる・private が無いと落ちる
- dotfiles-private を取っていない PC (新しい PC の初回・会社の PC) で、評価や switch や setup が止まる
- dotfiles-private の全体 (`ssh/`・辞書) が `/nix/store` に入る
- 登録した PC が、ユーザーの知らないうちに前と違う中身で switch される (登録の前に差を見せていない・setup がどのホストを
  どこから選んだかを出さない)
- private の値 (ホスト名・Windows のユーザー名・option の値) が public の repo (文書・テスト・skill の例) に入る
- setup が、Nix より前に無いコマンド (jq など) を要るようになる。private の有無やホストの判定で setup が止まる
- 分かりにくいエラーで止まる (例: private にホストがあるのにローカル flake が private を読んでおらず、attribute が無いと落ちる)

## 制約

- 本体は public。skill・script・テストに実機の値を書かない (テストの値は作り物にする)
- setup.sh はホストの判定を手順 1 (Nix のインストール) の前にも行う。nix と jq に頼らず、ファイルの有無と sed / grep で
  決める (bash 3.2 の macOS も対象)
- ローカル flake の `path:` 入力は narHash で lock される (setup-local-flake.sh の冒頭)。張り直しは
  `sync_local_flake_lock` が switch の前に行うが、今は最初の `path:` 入力 1 つしか見ない
- dotfiles-private の clone の場所の決め方は 1 つにする (`$DOTFILES_PRIVATE_DIR` → `$(ghq root)/github.com/pollenjp/dotfiles-private`
  → `~/ghq/github.com/pollenjp/dotfiles-private`。bootstrap-dotfiles-private.sh・bootstrap-windows-* と同じ)
- `dotfiles-private/nix/` に書いたものは、誰でも読める `/nix/store` に入る (今の `local` の値と同じ扱い)
- 雛形の heredoc を直すと雛形の版の印が変わり、既存の PC に移行の知らせが出る (ADR 024)。`local-flake-migrate.sh` は
  履歴の雛形を、heredoc の展開を真似て描き出す (今は `${nix_dir}` と `\$` だけ)。展開を足すなら描き出しも追従させる
- flake の checks は Nix のサンドボックスで流れる (ネットワークも本物の private も無い)

## 決まったこと

### 1. dotfiles-private の形

```
dotfiles-private/
└── nix/
    └── hosts/
        ├── pollenjp@lavie.nix
        └── <user>@<hostname>.nix …
```

- 1 実機 1 ファイル。ファイル名は `<user>@<hostname>.nix`、ホストの名前はファイル名から `.nix` を除いたもの
- 中身は public の登録簿の 1 エントリと同じ形で、`mkHome` を受け取って呼ぶ関数にする (段階 3 で public から移すときに
  そのまま写せるように):

  ```nix
  # 例 (値は作り物)
  { mkHome, ... }:
  mkHome {
    username = "alice";
    system = "x86_64-linux";
    claude = {
      devTracker.enable = true;
      notion.profile = "work";
    };
    modules = [ { dotfiles.ccPages.port = 7801; } ];
  }
  ```

- `nix/` の下だけを input に取る。`ssh/` と辞書は `/nix/store` に入れない

### 2. 読み込む仕組みは本体の lib に置く

- 本体の flake の `lib` に、private の input (store path) を受け取ってホストの attrset を返す関数を足す
  (`hosts/*.nix` を `builtins.readDir` で並べ、各ファイルを `{ mkHome = dotfiles.lib.mkHome; … }` で呼ぶ。
  `hosts/` が無い・空なら `{ }`)。雛形はそれを呼ぶだけにする。読み方を直しても雛形の版が変わらないようにするため
- private のホストには `local` を **当てない** (下の「こちらの判断」1)。private のファイルがその PC の値の全部

### 3. ローカル flake の雛形

- 2 つ目の `path:` 入力として dotfiles-private の `nix/` を取る。`sync_local_flake_lock` と `local-flake-migrate.sh` が
  今の 1 行の形で拾えるよう、`inputs.<名前>.url = "path:…";` の 1 行と、`inputs.<名前>.flake = false;` の行に分けて書く
- 指す先 (こちらの判断 2): 雛形を書くときに clone の `nix/` があればそこ、無ければ本体に置く空の stub のディレクトリ。
  どちらでも input の行の形は同じにする
- `homeConfigurations` は「登録簿 (`hostsWith [ local ]`)」→「private のホスト」→「このマシンだけのホスト」の順に `//` で
  重ねる (後ろが勝つ)
- `local` の説明に「dotfiles-private にこの PC のホストがあるときは、そのホストには当たらない」を足す
- 雛形の版の印は変わる。既存の PC は setup の知らせと pjp-dotfiles-local-flake-migrate (または登録の skill の最後の手順) で移す

### 4. setup.sh

- **dotfiles-private の取得:** `--update` (と `--self-update --update`) で、switch の **前に** fast-forward する。
  取れないとき (オフライン・鍵が無い・分岐) は今までどおり警告して続ける (手元の clone で評価する)。bootstrap の order 50 の
  手順は残してよい (二度目は何も起きないか、軽い)
- **ホストの決め方:** `--host` → `DOTFILES_HOST` → ローカル flake が定義するホスト → **private の `<user>@<hostname>`** → 推測。
  private のホストは、clone に `nix/hosts/<user>@<hostname>.nix` があり、かつローカル flake の private の入力がその clone の
  `nix/` を指しているときだけ選ぶ
- **表示:** 選んだホストがどこで定義されたかを出す (今の「~/dotfiles/flake.nix で定義」と同じ形で「dotfiles-private で定義」)
- **一覧・メニュー・`ensure_host_registered`:** private のホスト (ファイル名) も並べる
- **lock の張り直し:** `path:` 入力を全部見る (今は最初の 1 つだけ)
- **知らせ:** clone にこの PC のホストがあるのに、ローカル flake が private を読んでいない (入力が無い・stub を指す) ときは、
  推測に落ちたことと直し方 (登録の skill の最後の手順か local-flake-migrate) を残りの手作業に出す
- **登録と違うホストの知らせ:** `--host` か `DOTFILES_HOST` が、この PC の private のホスト (`<user>@<hostname>`) と違う名前を
  指したときは、そのことを知らせる (止めない。明示した方で当てる)。nixos-config の README などに残る `--host pollenjp@laptop` の
  手順で当てたときに気づけるようにする (こちらの判断 7)
- hostname の取り方は 1 つの関数にまとめ、setup と skill (の script) で同じものを使う (こちらの判断 3)

### 5. 登録の skill `pjp-dotfiles-register-host`

- 置き場所は `nix/files/claude/skills/pjp-dotfiles-register-host/` (pjp-dotfiles-update・pjp-dotfiles-local-flake-migrate と
  並べ、本体と同じ版で配る)。決まった処理 (調べる・下書きを描く・評価して比べる) は本体の `nix/scripts/` の script に置き、
  skill は判断と確認の取り方を受け持つ (TKT-228 と同じ分け方)
- 手順 (どの会話で何をするかは、こちらの判断 8):
  1. **この PC を調べる:** hostname・user・system・WSL か (WSL なら Windows のユーザー名)・元にするホスト・ローカル flake の
     `local` の値と手で足したホスト・private に既にエントリがあるか。元にするホストは、今のローカル flake のまま評価して
     今の世代の `activationPackage` と一致したもの。一致するものが無い (本体が最後の switch から進んだ) ときは、setup の判定と
     同じ順で推したホストを示し、ユーザーに確かめる
  2. **下書きを見せて確かめる:** 元にするホストの `mkHome` の引数に `local` の値を足して下書きを描く。登録で振る舞いが変わる所
     (署名・Notion の宛先など) は書く前に並べて見せ、ユーザーの確認を取る
  3. **dotfiles-private に書く:** dotfiles-private の main の checkout ではなく、branch (worktree) に 1 ファイル足す
  4. **評価して比べる:** **同じ本体の版・同じ lock** で、旧い形 (元のホスト + 今の `local`) と新しい形 (private の
     `<user>@<hostname>`。`local` は当たらない) を評価し、drvPath を比べる (こちらの判断 6)。同じなら「この登録で中身は
     変わらない」と言える。違えば、何が違うか (`config.dotfiles` の差など) を出す。今の世代との一致は参考として出すだけにする
     (本体を進めると、skill を 1 つ足しただけでも全ホストの世代が変わるため)
  5. **commit・push・PR:** dotfiles-private へ PR を出す (merge はユーザー)
  6. **merge のあと:** ローカル flake を今の雛形へ移し (private の入力が入る)、移した値を `local` から外して雛形の既定に戻す。
     どちらも書き換える前に差分を見せて確認を取る (ローカル flake はユーザーのファイル)。書き換える前に、merge 後の本体で 4 と
     同じ比べ方をもう一度通す。そのあと `~/dotfiles/setup --update` (`--host` なし) が `<user>@<hostname>` を選ぶことを確かめる
- 既にエントリがある PC で呼ばれたら、今の値と比べて直す (同じなら何もしない)
- 秘密を書かない。private の値を public の repo に書かない

### 6. lavie の登録 (dotfiles-private の PR)

- ホストの名前は `pollenjp@lavie` (hostname は `lavie`)
- 元は今の世代と一致した `pollenjp@x86_64-linux` (git の署名なし。ユーザーが「入れない」を選んだので `onePassword` は書かない)
- 値は今の `~/dotfiles/flake.nix` の `local` から移す (4 行。本体の既定と同じ値も、今のファイルが明示しているので残す)。
  値そのものは dotfiles-private の PR に書く (この文書を public の repo に置くときに、値の列挙は外した)
- 期待: dotfiles の子の branch の本体・同じ lock で評価した、旧い形 (`pollenjp@x86_64-linux` + 今の `local`) と
  `pollenjp@lavie` の drvPath が同じ (この登録で中身は変わらない)。参考: lavie の今の世代は、2026-10-20 に main
  (3cf54a3) で評価した `pollenjp@x86_64-linux` + 今の `local` の outPath と一致した
- 評価は dotfiles の子の worktree の本体と、この子の worktree の `nix/` を `--override-input` で指し、ローカル flake は
  scratchpad の写しで行う
- dotfiles-private の README.md に `nix/hosts/` の行と節を足す (何を置くか・`/nix/store` に入ること・登録は skill で)
- ユーザーの `~/dotfiles/flake.nix` はこの PR では触らない (merge 後に skill の 6 で移す)

### 7. 文書

- ADR 025 (`docs/adr/025_<slug>_<日時>/`): 決定 (private に置く・ローカル flake の input・hostname で選ぶ)、採らなかった案
  (下の表)、段階 1〜3、`/nix/store` に入ること
- nix/README.md: 登録簿の節・「登録簿に載せずにマシンを足す」・新規マシンの手順・setup のホストの決め方・dotfiles-private の節。
  lavie に `--host pollenjp@laptop` を付けて当てる記述は、private に登録した PC では `--host` を付けない形に直す
  (ADR 022 の本文は記録なので直さず、ADR 025 に書く)。ADR 002 の「後続 ADR」に 025 を足す
- nixos-config の README の `--host pollenjp@laptop` は段階 3 で直す (この段階では setup の知らせで気づける。こちらの判断 7)
- `nix/hosts/default.nix` の冒頭のコメント: 実機は dotfiles-private に置く方向で、段階 3 まで実機の行が残ることを書く

| 採らなかった案 | 理由 |
| --- | --- |
| A. 各 PC の `~/.config/pjp/env` に `DOTFILES_HOST` を書く | --host 忘れは直るが、値は PC ごとの手書きのまま git に残らない |
| B. public の登録簿に値も書く | 実機の情報が public に出る |
| C. dotfiles-private を本体の flake の input にする | public の lock に private の rev が残り、public の CI が private を取れずに落ちる (ADR 015 / 016) |

## テスト

flake の checks に足す (作り物の private と hostname で。本物の値は使わない)。

- lib の関数: 作り物の `hosts/` (名前に `@` を含む 2 ファイル) から 2 ホストができる・`hosts/` が無い/空なら `{ }`・
  ホストの名前がファイル名どおり
- 雛形: clone があるときは clone の `nix/` を、無いときは stub を指す・どちらも `inputs.<名前>.url = "path:…"` の 1 行の形・
  雛形の版の印が計算できる・local-flake-migrate.sh が新旧の雛形を描き出せる
- setup のホストの決め方: 優先順 (`--host` > `DOTFILES_HOST` > ローカル flake のホスト > private > 推測)・private の
  ファイルがあってもローカル flake が private を読んでいなければ選ばず、知らせを出す・一覧とメニューに private のホストが出る
- setup の手順の並び: `--update` で dotfiles-private の取得が switch より前に来る (`--dry-run` の出力で見る)・取れなくても止まらない
- lock の張り直し: `path:` 入力 2 つのどちらがずれても張り直す
- 登録の script: 作り物の PC (hostname・local の値・今の世代) から下書きを描く・評価の比べ方 (同じ / 違う)
- 既存のテストで、登録簿の実機を前提にしたもの (`nix/tests/one-password.nix` など) はこの段階では変えない

## こちらの判断 (ユーザーに確かめずに決めたもの)

1. **private のホストには `local` を当てない。** 雛形の `local` は `devTracker.enable = false`・`notion.profile = null` を
   同じ優先度で書くので、当てると private の値 (`true`・プロファイルの名前) とぶつかって評価が落ちる (`mkDefault` に変えると雛形と
   既存の PC の移行が込み入る)。登録した PC で一時的に試すときは、dotfiles-private の作業ツリーのファイルを直す
   (`path:` 入力は commit していない変更も見える。git status に残るので戻し忘れにも気づける)。承認したページの
   「`local` はその PC で一時的に試す場所として残す」は、登録簿のホストとこのマシンだけのホストについて残る
2. **雛形の private の入力は、clone が無ければ本体の空の stub を指す。** 入力を条件で消すと、雛形の形が PC で変わり、
   migrate の 3-way merge が込み入る。新しい PC は、clone ができたあとで登録の skill の 6 (か local-flake-migrate) で指し直す
3. **PC の見分け方は短い hostname。** Linux は `hostname -s` 相当、macOS は `scutil --get LocalHostName` (ネットワークで
   変わらない名前)。home-manager も `--flake` の `#` を省くと `$USER@$(hostname -s)` などを探すので、名前の付け方が揃う
4. **名前の重なり。** private のホストの名前が public の登録簿と同じなら private が勝つ (段階 3 で実機を移すときの形)。
   setup の表示でどちらから来たかが分かれば足りる
5. **ADR の番号は 025** (指揮役が割り当てた。open の PR に ADR を足すものは無い)
6. **「中身が同じ」は、同じ本体の版・同じ lock での旧い形と新しい形の比べ方で判定する** (builder check の問い 1)。
   今の世代は main で作られており、この PR で skill を足すだけで全ホストの世代が変わるので、今の世代との一致では判定できない。
   今の世代との一致は、元にするホストを見つけるため (手順 1) と参考の表示にだけ使う。lavie の登録 (6.) はこの段階に含め、
   dotfiles-private の子が dotfiles の子の worktree の本体を `--override-input` で指して評価する
7. **`--host` で public のホストを指したときは、setup が知らせるだけにする** (builder check の問い 2)。手順 6 で値を `local` から
   外すので、private に登録した PC で `--host pollenjp@laptop` (nixos-config の README・ADR 022 の手順) を付けて当てると、
   値が雛形の既定に戻り、ユーザーが入れないと決めた署名も入る。ユーザーの普段の打ち方は `--host` なしなので、登録と違うホストを
   明示したときの知らせ (4.) で足りるとし、値を `local` に残すこと (雛形のままにならない) と、nixos-config の子をこの段階で
   立てること (範囲が広がる) はしない。dotfiles の README の記述はこの PR で直す
8. **登録の skill は、会話の置き場所で手順を分ける** (builder check の問い 3)。1・2 (調べる・下書きの確認) と 6 (merge 後の
   ローカル flake) は、その PC で動いている会話がする (読むだけと、repo の外のユーザーのファイル)。3〜5 (private に書く・評価・
   PR) は dotfiles-private の worktree でする: 会話が dotfiles-private の worktree にいればその会話が、集約ハブ (`~/h`) や
   別の repo の会話なら pjp-herdr-other-repo の手順で dotfiles-private の子に、確かめた下書きを渡して任せる。
   script は書き先 (private の worktree の場所) を引数で受け取る

## 実装に任せること

- lib の関数の名前・引数・stub の置き場所と名前
- setup の取得を switch の前に出す仕組み (新しい手順にするか、switch の手順の中で呼ぶか) と、order 50 の手順との重なりの扱い
- 登録の script の名前・サブコマンドの分け方・出力の形 (TKT-228 の local-flake-migrate.sh の compare を流用してよい)
- hostname を取る関数の細部 (コマンドが無いときの扱いなど)
- skill の文面 (`nix/files/claude/skills/README.md` の決まりに従う)。skill なし / ありの subagent で確かめる (TKT-228 と同じ)
- README のどの節をどこまで直すか
