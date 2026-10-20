# ローカル flake を値を引き継いで今の雛形へ移す — 設計 (TKT-228)

- チケット: [TKT-228](https://app.notion.com/p/flake-dotfiles-flake-nix-flake-nix-skill-3ff79149a66f812da559fe8f48e8e2d5)
- 方針は 2026-10-20 にユーザーが承認した (問い 1 は A = setup 側に雛形の版の印と知らせを入れる、問い 2 は
  skill の名前を `pjp-dotfiles-local-flake-migrate`)。この文書はその書き写しと、実装に要る細部
- 承認のときに指揮役が添えたこと: 本体で option が改名・削除されて旧い flake が今の本体で評価できないときの扱い
  (compare がはっきり出す・skill に読み解き方を書く・setup の知らせが switch の失敗のあとにも見える) を入れる (6 節)
- 関連: ADR 002 (登録簿とローカル flake)、TKT-153 (本体を進める前に local へ新しい option を書くと評価が止まる)、
  ADR 022 (旧名を `mkRenamedOptionModule` で新しい名前へ渡す決まり)

## 背景と意図

`~/dotfiles/flake.nix` は `nix/scripts/setup-local-flake.sh` が heredoc の雛形から 1 度だけ作る、git 管理外のマシン固有の
ファイル。既にあれば触らず、`--force` は作り直すので、`local` に書いた値と手で足したホストが消える。

雛形は 2026-08-10 から 2026-10-19 までに 24 版ある (説明の書き換え・option の節の追加・例の移動)。既存のファイルは
古い形のまま残り、気づく仕組みは `hostsWith` と `notion.profile` の grep だけ。ユーザーは「気づかないまま旧い形で
動いているやつもありそうかも」と言う。

この PC の実物 (TKT-228 のメモ):

- `~/dotfiles/flake.nix` は 87922f9 版 (870b317 と同じ中身) の雛形から作られ、利用者が変えたのは 4 行
  (`devTracker.enable = true`・`gitViaGh.enable = true` (コメントを外した)・`notion.profile = "personal"`・
  `ccPages.port = 7778` (コメントを外した))
- 最新の雛形 (a662c76) と `git merge-file --diff3` で 3-way merge すると、3 か所は機械的に移る。
  `ccPages.port` の行の直後に videoOffer の節が足された所だけが、隣接の衝突になる
- 旧い flake と、merge して衝突を解いた flake の写しを同じ lock で評価すると、登録簿の 7 ホストの
  `activationPackage.drvPath` が全部一致した (評価は 1 回 20〜45 秒)。port を 1 つ変えると 7 ホストとも変わり、
  `config.dotfiles` を JSON で比べると `ccPages.port` だけが違うと読めた

本体で option が改名されたときは、`mkRenamedOptionModule` で旧名を新しい名前へ渡す決まり (ADR 022) なので、旧い
`local` は警告を出しつつ動く。削除されたとき・型が変わったときは、旧い `local` のままでは評価が止まる。setup.sh は
手順が失敗すると残りの手作業 (`post_notes`) を出さないので、今の「古い雛形」の案内もそのときは見えない。

## ゴール

1. skill `pjp-dotfiles-local-flake-migrate` (`nix/files/claude/skills/`) が、旧いローカル flake を今の雛形の形へ移し、
   値 (`local` の option・足したホスト・手で書いた module) は旧いファイルから引き継ぐ手順を Claude に教える。
   書き換える前に差分を見せてユーザーの確認を取る
2. 決まった処理は本体の `nix/scripts/local-flake-migrate.sh` が持つ。skill はローカル flake が指す本体の script を呼ぶ
3. 値を引き継げたことは、旧い flake と移した flake を同じ本体・同じ lock で評価し、全ホストの名前と
   `activationPackage.drvPath` が同じことで確かめる。違えば、違うホストの `config.dotfiles` の差を出す
4. 雛形に「雛形の版」の印を入れる。setup が旧い雛形を見つけたら移し方を案内する:
   `--steps local-flake` を流したとき (setup-local-flake.sh の警告)、`--update` などが通ったとき (残りの手作業)、
   switch が失敗したとき (失敗の案内のあと)
5. 旧い flake が今の本体で評価できないときは、compare がそう出して止まる。skill が読み解き方と、基準 (旧い flake に
   評価が通るだけの最小の直しを当てたもの) を作って比べ直す手順を示す

## 非ゴール

- setup の中で `~/dotfiles/flake.nix` を自動で書き換えること。移すのは script / skill を明示して流したときだけ
- 本体の option の改名・削除の書き方を変えること
- この PC の `~/dotfiles/flake.nix` をこの PR で移すこと (merge のあと、skill で移す)
- 雛形を heredoc から別のファイルへ出すこと
- 旧い本体 (pull する前の本体) で旧い flake を評価すること。path: 入力は narHash で厳密に lock されるので、
  本体を進めたあとでは旧い lock のままでは評価できない (setup-local-flake.sh の冒頭)

## アンチゴール (技術的に動いても失敗とみなすもの)

- ユーザーの確認を取る前に `~/dotfiles/flake.nix` を書き換える
- 退避を取らずに書き換える。prepare のあとに書き換わった `~/dotfiles/flake.nix` を上書きする
- 値が黙って変わる・落ちる (compare が「同じ」と出したのに世代の中身が違う)
- 旧い flake を評価できないのに「同じ」と出す
- 古い版の setup-local-flake.sh を実行する (古い版は `DOTFILES_LOCAL_DIR` を知らず、`~/dotfiles` に書きうる)
- setup が、雛形の印のために Nix より前に無いコマンド (jq など) を要るようになる。印を確かめられないことで
  setup が止まる

## 制約

- 本体は public。skill と script に私的な値 (Notion の URL など) を書かない
- skill は switch のときに store へ写る。本体を pull しただけの時点では古い skill が残るので、決まった処理は本体の
  script に置く (pjp-dotfiles-update が `nix/scripts/closure-scan.sh` を呼ぶのと同じ形)
- setup-local-flake.sh と setup.sh は、jq の無い段階 (Nix を入れた直後) でも走る。印の計算と照合は bash・awk・sed・
  cksum だけで行う
- `~/dotfiles` は git 管理外の path: flake で、置いたファイルは評価のたびに store へ写る
- ローカル flake の path: 入力は narHash で lock される。本体を進めたあとは lock が合わないので、比べる前に写しの
  lock を張り直す (setup.sh の `sync_local_flake_lock` と同じ `nix flake update dotfiles`)

## 決まったこと

### 1. 雛形の版の印

- 印は、setup-local-flake.sh の heredoc の**原文** (`  cat >"${flake_file}" <<EOS` の次の行から `EOS` の前の行まで、
  展開する前のまま) の POSIX cksum の CRC を、8 桁の 16 進にしたもの
  - 原文にはマシンごとのパスが入らないので、同じ版ならどのマシンでも同じ印になる
  - 印の行は原文では `${template_id}` のままなので、印が自分自身を含んでも循環しない
  - heredoc の外 (script の処理) を直しても印は変わらない
- 雛形の先頭のコメントに印の行と、移し方の案内を置く:

  ```nix
  # 雛形の版: ${template_id}
  #   雛形が新しくなると setup が知らせる。値を引き継いで今の雛形へ移すには
  #   (Claude Code なら pjp-dotfiles-local-flake-migrate skill):
  #     ${nix_dir}/scripts/local-flake-migrate.sh prepare
  ```

- 印の計算は local-flake-migrate.sh の `id` だけが持つ。setup-local-flake.sh は書くときに `id` を呼び、
  setup.sh と setup-local-flake.sh は照合に `check` を呼ぶ

### 2. 雛形の各版の描き出し

- 版ごとの雛形は、`git show <rev>:nix/scripts/setup-local-flake.sh` から原文を awk で抜き、bash の heredoc の展開を
  真似て描く。古い版の script は**実行しない**
- 置き換えるのは `${nix_dir}` (旧いファイルの `inputs.dotfiles.url` の `path:` のパス)・`${template_id}`
  (その版の印)・`\$`・`` \` ``・`\\` だけ。ほかの展開 (`$NAME`・`${...}`・`$(...)`・`` `...` ``・特殊なパラメータ・
  行末の `\`) があれば、描けないとして止まる。履歴の 24 版は `${nix_dir}` と `\$` だけ
- 開きの行が `  cat >"${flake_file}" <<EOS` と完全に一致する行が 1 つでない版は、描けないとして飛ばす (理由を出す)

### 3. `nix/scripts/local-flake-migrate.sh`

```text
local-flake-migrate.sh status  [--flake <dir>]
local-flake-migrate.sh check   [--flake <dir>]
local-flake-migrate.sh prepare [--flake <dir>] [--out <dir>]
local-flake-migrate.sh compare <作業場所> [--baseline <dir>]
local-flake-migrate.sh apply   <作業場所> [--accept-changes]
local-flake-migrate.sh id      [<setup-local-flake.sh のパス> | -]
local-flake-migrate.sh render  (--rev <rev> | --file <path>) --nix-dir <path>
```

- `--flake` の既定は `${DOTFILES_LOCAL_DIR:-~/dotfiles}`。雛形の履歴と今の雛形は、**この script が置かれた repo**
  (script の 2 つ上) の `nix/scripts/setup-local-flake.sh` から取る (今の雛形は作業ツリーのファイル)
- `status`: 旧いファイルの印・今の雛形の印・同じか。違えば、印の版 (commit と日付) か、印が無ければ履歴で最も
  近い版と差分の行数。同じなら 0、違う・印が無いなら 1、ローカル flake でない (`inputs.dotfiles.url` の `path:` が
  無い) などは 2
- `check`: setup のための静かな版。git も nix も使わない。同じなら何も出さず 0、違えば 1 行 (印の値) を出して 1、
  調べられなければ 2
- `prepare`: 作業場所 (`--out`。既定は `mktemp -d`。在るなら空であること) に次を作る
  - `old/flake.nix`・`old/flake.lock` — 旧いローカル flake の写し (このあと誰も触らない)
  - `template.nix` — 今の雛形 (旧いファイルの `${nix_dir}` で描く)
  - `base.nix` — 元の雛形。印があり、その版が履歴にあればその版。無ければ履歴の各版を描き、旧いファイルとの diff の
    行数が最小の版 (同数なら新しい方)
  - `candidates.tsv` — 履歴の各版 (commit・日付・印・旧いファイルとの差分の行数・題)
  - `new/flake.nix` — `git merge-file -p --diff3 -L 手元 -L 元の雛形 -L 今の雛形` の結果に、4 節の自動の解消を当てた
    もの (lock は置かない。compare が評価用の写しで作る)
  - `prepare.env` — ローカル flake の場所・旧いファイルの cksum・本体のパス・元の版と決め方
  - 元の雛形と今の雛形が同じ版なら「移すものは無い」と出して 0 で終わる (作業場所は作らない)
  - 終わりに、元の版と決め方、衝突の数 (自動で解いたもの・残ったものと、残ったものの `new/flake.nix` の行番号)、
    次に打つものを出す
- `compare`: 5 節
- `apply`: 7 節
- `id`: 引数の script (`-` なら stdin、省けば作業ツリーの setup-local-flake.sh) の印を出す
- `render`: その版の雛形を stdout に出す (調べる・テストのため)

### 4. 衝突の自動の解消

`git merge-file --diff3` の衝突のうち、次の形だけを解き、ほかは diff3 の印のまま残す。

- 元の行 B が空でなく、片側 S が「B の後ろに行を足しただけ」(S = B + X) か「B の前に行を足しただけ」(S = X + B)
- もう片側 O は、B で始まらず B で終わらない (O も B に足しただけなら、どちらを先に置くか決まらない)
- 解いた結果は O + X (後ろに足した) か X + O (前に足した)

この PC の衝突 (B = `# dotfiles.ccPages.port = 7778;`、手元 = コメントを外した行、今の雛形 = B + videoOffer の節) は
`dotfiles.ccPages.port = 7778;` + videoOffer の節になる。

### 5. compare (値を引き継げたかの確かめ)

1. 作業場所の `new/flake.nix` に diff3 の印 (`<<<<<<<`・`|||||||`・`=======`・`>>>>>>>` で始まる行) が残っていれば止まる
2. 基準 (`old/`、`--baseline` を渡せばそのディレクトリ) と `new/` の flake.nix を、評価用の写し
   (`<作業場所>/.eval/base`・`.eval/new`) に置き、lock は基準の lock (無ければ `old/flake.lock`) を写す。`old/` と
   `new/` は触らない。写しの lock を張り直す: 本体の `nix hash path --sri --type sha256 <本体の nix>` が lock に
   無ければ `nix flake update dotfiles --flake path:<写し>`、lock が無ければ `nix flake lock --flake path:<写し>`
3. それぞれを 1 回の `nix eval --raw path:<写し>#homeConfigurations --apply …` で評価し、ホストごとの
   `activationPackage.drvPath` と `config.warnings` を TSV で受ける (jq を使わない)
4. ホストの名前の集合と drvPath を比べて表にする。違うホストは、その `config.dotfiles` を平らにした
   「パス<TAB>値 (JSON)」で比べ、違う行を「旧い → 新しい」で出す (読めなければそう書いて続ける)。
   `config.dotfiles` が同じなのに drvPath が違えば、dotfiles の option の外 (足したホストの modules など) の違いと出す
5. setup がファイルの文字列から拾うホストの並び (setup.sh の `parse_hosts` と同じ sed。`sandbox` を除き、一番上が
   setup の既定の対象ホスト) を比べる。違えば「違う」に数える (drvPath が全部同じでも、既定のホストが黙って変わるため)
6. 警告は、基準だけにあるもの (移して消えた。改名を新しい名前へ移したときなど) と、移した flake にあるものを出す
7. 結果を `compare.result` (`new/flake.nix` の cksum・基準のディレクトリと cksum・基準が `old/` か・同じか) に書く。
   compare を始めるときに前の `compare.result` を消す (落ちた compare の前の結果で apply しない)
8. 終了コード: 0 = 全ホストが同じ、1 = 違うホストがある・ホストの集合か並びが違う、2 = 使い方の誤りなど、
   3 = 基準が今の本体で評価できない、4 = 移した flake が評価できない

### 6. 旧い flake が今の本体で評価できないとき

- compare は基準の評価が落ちたら、それをはっきり出して 3 で終わる:
  「旧い flake (基準) は今の本体 <path> で評価できない。本体で option が削除・改名された、型が変わったなどで、旧い
  local が今の本体に合っていない」と、nix の `error:` から始まる数行と、skill の該当の節の名前
- skill の手順 (Claude の判断):
  1. エラーから option の名前を拾い、本体の履歴で何が起きたかを調べる (`git log -p -S'<名前>' -- nix/home`・
     ADR・`base.nix` と `template.nix` の差)
  2. `old/` を基準のディレクトリへ写し (`old/` そのものは触らない)、評価が通るだけの最小の直し (旧名を新しい名前へ・
     削除された行を外す) を当てる。`new/flake.nix` にも同じ直しが入っているかを見る
  3. `compare <作業場所> --baseline <基準>` で比べ直す。同じなら、書式の移し替えは値を変えていない
  4. ユーザーに見せるときは、旧い flake が今の本体で評価できないこと・当てた直しとその意味 (値が変わるか)・
     setup --update の switch は移すまで落ちることを書く。基準が `old/` でないので、apply には `--accept-changes` が要る
- setup.sh は、switch が失敗し、ローカル flake の雛形が旧い (`check` が 1) ときに、失敗の案内のあとへ
  「ローカル flake は前の雛形から作られている。本体で option が削除・改名されていると、旧い local のままでは評価が
  止まる。値を引き継いで今の雛形へ移す: <script> prepare (Claude Code なら pjp-dotfiles-local-flake-migrate skill)」を出す

### 7. apply (書き換え)

- 次のどれかなら書かずに止まる:
  - `~/dotfiles/flake.nix` が `old/flake.nix` と違う (prepare のあとに書き換わった。prepare からやり直す)
  - `new/flake.nix` に diff3 の印が残っている
  - `compare.result` が無い・`new/flake.nix` の cksum が `compare.result` と違う (今の中身で compare を流していない)
  - compare が「同じ」でない、または基準が `old/` でない、のに `--accept-changes` が無い
- 退避: `flake.nix.bak-<YYYYmmddTHHMMSS>` と (あれば) `flake.lock.bak-<同じ日時>` を `~/dotfiles` に `cp -p` で置く
- `new/flake.nix` を同じディレクトリの一時ファイルへ写してから `mv` で置き換える。flake.lock は変えない
- 終わりに、退避の場所・戻すコマンド (`cp -p` 2 つ)・次にすること (同じなら switch は要らない。値の違いを受け入れた
  なら `~/dotfiles/setup --update`) を出す

### 8. setup 側

- setup-local-flake.sh
  - 書くときに `local-flake-migrate.sh id` で印を計算し、heredoc の `${template_id}` に入れる。計算できなければ止まる
  - 既にあって本体のパスも合うときは `check` を流し、1 なら `warn` で 3 行を出す (前の雛形から作られている・
    移し方 (`<script> prepare` と skill)・`--force` は値と足したホストを消すこと)。2 なら黙る
  - 今の `hostsWith` の警告は残し、直し方の文を「移し方 (上の warn) か、手で足したホストが無ければ `--force`」にする
  - 先頭のコメントに印のことを書く
- setup.sh
  - `post_notes` (手順が全部通ったとき): ローカル flake があり、`local-flake` の手順を選んでおらず、`check` が 1 なら、
    2 行の `note` を出す。今の `hostsWith`・`notion.profile` の案内とは別に、`hm_warnings_read` に関わらず出す
  - 失敗の案内: 6 節の最後
  - どちらも `local-flake-migrate.sh` が無い・`check` が 2 なら黙る

### 9. skill `pjp-dotfiles-local-flake-migrate`

- `nix/files/claude/skills/pjp-dotfiles-local-flake-migrate/SKILL.md`。補助のファイルは置かない (処理は本体の script)
- description は使う場面だけ: ローカル flake を今の雛形に合わせたいと言われたとき、setup が「前の雛形から作られて
  いる」と知らせたとき、本体を更新したら `~/dotfiles` 経由の switch が option が無い・削除されたで落ちたとき、
  `--force` で作り直したくなったとき
- 本文: 前提 (本体を先に新しくする・ローカル flake が指す本体の script を使う) → 手順 (status → prepare → 残った衝突を
  解く → compare → 差分を見せて確認 → apply → そのあと) → 衝突の解き方 → compare の結果の読み方 (6 節の手順を含む)
  → ユーザーに見せる確認の形 → 戻し方 → よくある誤り
- 確認の形 (apply の前にユーザーへ出すもの): 元の版と今の版・`diff -u` (長ければファイルのパスと要約)・変わる中身の
  まとめ (説明の書き換え・足された節・移った例・値の変化)・compare の結果・退避の場所と戻し方・「書き換えてよいか」

## テスト

- `nix/tests/local-flake-migrate.test.sh` (flake の checks に `scriptTest "local-flake-migrate" ./scripts`)。
  使い捨ての git repo に偽の setup-local-flake.sh の版を積み、写した local-flake-migrate.sh を流す
  - render: `${nix_dir}`・`${template_id}`・`\$` を描き、ほかの展開 (`$HOME`・`$(…)`・`` ` ``) は止まる
  - id: heredoc の中を変えると変わり、外を変えても変わらない
  - status / check: 印が同じ・違う・無い、ローカル flake でない
  - prepare: 印が無いときは差分の最小の版、印があるときはその版を元にする。自動で解く衝突 (後ろに足した・前に
    足した・片側が消した) と残す衝突 (両側が足した・同じ行を両側が直した)。同じ版なら「移すものは無い」
  - compare (偽の nix): 同じ・違う (config.dotfiles の差の表示)・ホストの集合が違う・基準が評価できない (3)・
    移した flake が評価できない (4)・印が残っている・`--baseline`・警告の差・`compare.result`
  - apply: 4 つの拒否と、退避・置き換え・戻すコマンドの表示
- `nix/tests/setup-local-flake.test.sh` (新設。`scriptTest "setup-local-flake" ./scripts`)
  - 作った flake.nix の印が `id` と同じで、`render --file` の出力と一致する (描き出しが本物の heredoc と合う)
  - 既にあり印が同じなら警告なし、違う・無いなら移し方の警告、`--force` で作り直す、別のパスを指すなら今の警告
- `nix/tests/setup-post-notes.test.sh` に足す: `--update` が通ったときの案内、switch が失敗したときの案内、
  印が同じなら出ない
- skill (writing-skills): subagent に skill なし (RED) と skill あり (GREEN) で、使い捨ての本体の clone と、この PC の
  flake の写しを使って同じ移行をさせる。GREEN では、旧い flake が評価できない場合 (本体の clone で option を消す) も流す
- 実物: この PC の `~/dotfiles/flake.nix` の写しで prepare → compare → apply (写しに対して) を流し、元の版・衝突・
  7 ホストの drvPath の一致を PR に載せる

## 文書

- `nix/README.md`: 「このマシンだけの設定 (`local`)」の箇条 (雛形が変わっても…) を書き換え、「雛形が新しくなったら」の
  小節を足す (印・setup の知らせ・local-flake-migrate.sh の使い方・skill)
- setup-local-flake.sh の先頭のコメント
- ADR 024 (雛形の版の印と、3-way merge と評価の比較で移すこと)

## こちらの判断 (ユーザーに確かめずに決めたもの)

- 印の計算は POSIX の cksum (`git hash-object` や `sha256sum` は使わない): setup は git や sha256sum が無い段階
  (macOS の素の環境など) でも走り、cksum は GNU と BSD で同じ値を出すため
- 印は heredoc の原文の値にする (描いたものの値にしない): マシンに依らず、印が自分を含んでも循環しないため
- 印の計算と照合は local-flake-migrate.sh にだけ置き、setup-local-flake.sh と setup.sh はそれを呼ぶ
- 退避は `~/dotfiles` の中 (`flake.nix.bak-<日時>`) に置く。見つけやすさを優先する (評価のたびに store へ写るが小さい)
- 自動で解く衝突は 4 節の 1 種類だけ。残りは Claude が解き、差分はユーザーが見る
- compare は jq を使わず、`nix eval --raw` で TSV を作って awk で比べる。比べるのは登録簿と足したホストの全部
- 警告 (`config.warnings`) も比べる。改名の警告で、手元の有効な行を新しい名前へ移す手がかりになるため
- apply は今の中身で compare を流したことを要り、同じでないなら `--accept-changes` を要る
- setup-local-flake.sh は印を計算できなければ止まる (印の無いファイルを新しく作らない)
- setup の照合 (`check`) が 2 を返す・script が無いときは黙る
- 失敗の案内は switch が失敗したときだけ出す
- ADR を起こす (024)。ローカル flake の形 (印の行) と、それを前提にした移し方を決めるため
- builder check の指摘 2 つを入れた: (1) compare は lock を張り直すので、`old/` を触らずに評価用の写しで評価する
  (5 節の 2)。(2) setup は `~/dotfiles/flake.nix` の文字列から既定の対象ホスト (一番上に足したホスト) を拾うので、
  drvPath が全部同じでも衝突の解き方でホストの並びが変わると既定が黙って変わる。compare でこの並びも比べる (5 節の 5)
- prepare の `candidates.tsv` は 1 行目に見出しを置く。`new/` には lock を置かない

## 実装に任せること

- 出力の文言と並び、引数の細部、awk の書き方
- `candidates.tsv` の列の並び
- テストの偽の nix の作り
