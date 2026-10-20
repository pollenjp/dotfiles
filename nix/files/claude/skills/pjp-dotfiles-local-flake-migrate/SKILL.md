---
name: pjp-dotfiles-local-flake-migrate
description: dotfiles のローカル flake (`~/dotfiles/flake.nix`) を、本体の setup-local-flake.sh が今書く雛形の形に
  合わせ、値 (local に書いた option・手で足したホスト・手で書いた module) は旧いファイルから引き継ぐときに使う。
  「ローカル flake を最新の雛形に合わせて」「~/dotfiles/flake.nix が古い形のまま」と言われたとき、setup が
  「flake.nix は前の雛形から作られています」と知らせたとき、本体を更新したら `~/dotfiles` 経由の switch が
  「option が無い・削除された」で落ちるようになったとき、`setup-local-flake.sh --force` で作り直したくなったとき
  (作り直すと値が消える) に読む。flake.lock を上げて switch する話は pjp-dotfiles-update の側。
---

# pjp-dotfiles-local-flake-migrate

`~/dotfiles/flake.nix` は setup-local-flake.sh が heredoc の雛形から 1 度だけ作る、**git 管理外**のファイル。
雛形が新しくなっても古い形のまま残り、`--force` で作り直すと local に書いた値と手で足したホストが消える。

決まった処理は本体の `nix/scripts/local-flake-migrate.sh` が持つ。元の雛形を履歴から引いて 3-way merge し、
旧い flake と移した flake で全ホストの drvPath を比べ、退避してから書く。この skill は、手順と、script が決めない
判断 (残った衝突・評価の違い・確認の取り方) を教える。

## 書き換える前に、必ず差分を見せて確認を取る

`apply` (~/dotfiles/flake.nix を書き換える) は、下の「確認の形」でユーザーに見せ、良いと言われてから流す。

- 「直して」「移して」と頼まれていても同じ。頼まれたのは直すことで、どう変わるかはまだ見せていない
- compare が「全ホストで同じ」でも同じ。説明 (コメント) の書き換えや例の移動は drvPath に出ない
- 退避を取るから書いてよい、にはならない。git 管理外なので、戻せるのは退避だけで、ユーザーは何が変わったかを知らない

skill を読まずに同じ移行をさせた subagent は、こう言って確認を取らずに書き換えた:
「ファイルが明示的に頼まれていたので、確認は挟まずにバックアップを取ってから書き換えた」。これをしない。

## 前提

1. **本体を先に新しくしてある** (`git pull` か `~/dotfiles/setup --self-update`)。旧い本体のまま今の雛形へ移すと、
   新しい行の option が本体に無くて評価が止まる
2. **ローカル flake が指す本体の script を使う**。skill は switch のときに store へ写るので、本体の script の方が今の
   雛形と同じ版で動く。パスは `inputs.dotfiles.url` の `path:` から引く:

   ```sh
   sed -n 's|^[[:space:]]*inputs\.dotfiles\.url[[:space:]]*=[[:space:]]*"path:\([^"]*\)".*|\1|p' ~/dotfiles/flake.nix
   # → <本体>/nix 。script は <本体>/nix/scripts/local-flake-migrate.sh
   ```

   以下の `<m>` はこのフルパス。`bash <m> <コマンド>` で流す (Bash tool はシェルの変数を次の呼び出しへ持ち越さない)
3. 作業場所は Claude の scratchpad の中に作る (`--out`)。`~/dotfiles` の中には作らない
   (script の一時ファイルは `${TMPDIR:-/tmp}` に作り、終わると消す)
4. `~/dotfiles/flake.lock` が古い・別のパスを指していても触らない。compare は写しで張り直して評価し、apply は lock を
   変えない (setup が switch の前に張り直す)

## 手順

1. `bash <m> status` — 「同じ版」なら移すものは無い。終わり。印が同じでも「dotfiles-private の入力: … → …」と出たら
   (clone の `nix/` ができたのに本体の stub を指している、など)、prepare がその 1 行を指し直す
2. `bash <m> prepare --out <scratchpad>/local-flake-migrate-<日時>` — 出力の「元の雛形」と「衝突」を読む
   - 元の雛形は、旧いファイルの「# 雛形の版:」の印の版 (印を入れる前の雛形なら、履歴で差分が最も小さい版)
   - 「近い版」が同じ行数で並んでも、印が同じなら雛形の中身が同じなので、選び直さなくてよい
   - 印の違う版が僅差で並び、どちらを元にするかで結果が変わりそうなら、各版を
     `bash <m> render --rev <rev> --nix-dir <本体>/nix` で描いて旧いファイルとの差を見て決め、`--base <rev>` を付けて
     新しい作業場所で prepare し直す
3. 残った衝突があれば、`<作業場所>/new/flake.nix` で解く (「衝突の解き方」)。`old/` は触らない
4. `bash <m> compare <作業場所>` — 結果ごとの扱いは「compare の読み方」
5. 「確認の形」でユーザーに見せ、書き換えてよいかを聞く。答えが来るまで次へ進まない
6. 承認されたら `bash <m> apply <作業場所>` (値の違いを受け入れたときだけ `--accept-changes`)
7. apply が出す退避の場所と戻すコマンドをユーザーに伝える。compare が「同じ」なら switch は要らない。
   値の違いを受け入れたとき・旧い flake で switch が落ちていたときは、反映に `~/dotfiles/setup --update` が要る
   (流してよいかはユーザーに聞く)

## 衝突の解き方

prepare は「片側が元の行の前後に足しただけ」の衝突 (コメントを外した行の直後に、雛形が新しい節を足した、など) を
自動で解く。残るのは両側が同じ所を直したもの。

- 手元の有効な行 (値) を残し、雛形が足した・直した説明と節を取り込む
- 雛形の変更が option の改名を映しているなら (例: tmp の例の `wsl.onePassword.enable` が `wsl` の外の
  `onePassword.enable` へ移った)、手元の有効な行も新しい名前へ移す。compare の「移して消えた」警告に改名の警告が
  出れば当たり
- 雛形が節ごと消し、手元がその中の行を有効にしていたら、本体でその option が削除された見込みが高い。本体の履歴
  (`git -C <本体> log -p -S'<option の名前>' -- nix/home nix/lib`) で確かめ、削除なら行を外す (残すと評価が止まる)。
  compare は 3 になるので、下の「旧い flake が評価できないとき」で比べ直す
- 既定と同じ値をあえて書いた行 (例: `dotfiles.claude.gitViaGh.enable = true;`) は消さない。書いた意図はユーザーに
  しか分からない。気づいたら確認のときに一言添える
- 「# 雛形の版:」の行は今の雛形のものにする (setup が次から知らせなくなる)
- 手で足したホストの並びを変えない (一番上が setup の既定の対象ホスト。compare も並びを比べる)

## compare の読み方

| 終了コード | 意味 | すること |
| --- | --- | --- |
| 0 | 全ホストの drvPath と、setup が拾うホストの並びが同じ | 確認へ。drvPath には home-manager が置くもの全部 (bootstrap が settings.json へ流す値の JSON も) が入るので、ほかの値を比べ直さなくてよい |
| 1 | 違うホストがある・ホストの集合か並びが違う | 下の「違いが出たとき」 |
| 3 | 旧い flake が今の本体で評価できない (全ホストか、一部のホスト) | 下の「旧い flake が評価できないとき」 |
| 4 | 移した flake が評価できない (全ホストか、一部のホスト) | new/flake.nix の誤り (構文・option の名前)。出力のエラーを読んで直し、compare し直す |
| 2 | 使い方の誤り・衝突の印が残っている | 出力のとおり直す |

- 比べるのは登録簿と手で足したホストのうち、検証専用の `sandbox` を除いたもの (setup も対象にしない)
- 今の雛形は dotfiles-private の `nix/` を読む (ADR 025)。移した flake だけにある dotfiles-private のホストは「dotfiles-private のホスト
  (移した flake だけ。比べない)」と出て、違いに数えない。ただし **この PC のホスト** (`<user>@<短い hostname>`) は、移したあと setup が
  `--host` なしで選ぶようになる (値はローカル flake の local ではなく、そのファイルから来る) ので、違いに数えて 1 になる。登録の仕上げなら
  意図どおり (pjp-dotfiles-register-host の手順 6)。そうでなければ、確認のときに「setup の選ぶホストが変わる」と書いて聞く
- 旧い flake でも移した flake でも評価が落ちるホストは、比べずに「両方で評価が落ちる」と出る (ほかが同じなら 0)。
  setup の対象のホスト (`~/dotfiles/flake.nix` で一番上に足したホストか、`<user>@wsl` などの推測) でなければ気に
  しなくてよい。対象なら、旧い local がそのホストで落ちているので、確認のときに書く

### 違いが出たとき (1)

出力の `config.dotfiles の違い (基準 → 移した)` を読み、どちらかに分ける。

- 衝突の解き方の誤り (手元の値を落とした・取り違えた) → new/flake.nix を直して compare し直す
- 雛形が意図して入れた変化 (今の雛形が、既定と違う値の有効な行を足した。前は無かったので本体の既定で動いていた)
  → 「今の動きのまま (前の値を書く)」か「雛形どおり」かを、推奨と理由を添えてユーザーに聞く。雛形どおりにするなら、
  確認のときに値が変わると書き、apply に `--accept-changes` を付ける
- `config.dotfiles は同じ` なのに drvPath が違う → 手で足したホストの modules など、dotfiles の option の外の違い。
  new/flake.nix と old/flake.nix の差分のうち、コメントでない行を見る

### 旧い flake が評価できないとき (3)

本体で option が削除された・型が変わった (改名は旧名を新しい名前へ渡す決まりなので、たいてい警告で済む) ときと、
local の値が登録簿のホストの持つ値とぶつかる (`conflicting definition values`) ときに出る。落ちたホストが setup の
対象なら、このマシンの `~/dotfiles/setup --update` の switch も、移すまで同じ所で落ちる。

1. 出力の nix のエラー (落ちたホストを評価し直した、最後の `error:` の行から。全文は出力にある `.eval/*.err`) から
   option の名前を拾う
2. 本体で何が起きたかを調べる: `git -C <本体> log -p -S'<option の名前>' -- nix/home nix/lib`、`docs/adr/`、
   `<作業場所>/base.nix` と `template.nix` の差
3. 基準を作る: `old/flake.nix` を作業場所の外の新しいディレクトリへ写し、評価が通るだけの最小の直し
   (削除された行を外す・新しい名前へ移す) だけを当てる。`old/` そのものは触らない (apply が「書き換わった」で止まる)。
   flake.lock は写さなくてよい (compare が `old/` の lock を使う)
4. new/flake.nix にも同じ直しが入っているかを見て、`bash <m> compare <作業場所> --baseline <基準>` で比べ直す。
   0 なら、書式の移し替えは値を変えていない
5. 確認のときに、旧い flake が今の本体では評価できないこと、当てた直しとその意味 (その値はどうなるか) を書く。
   前の値は `old/flake.nix` に書いてあり、本体の既定は前の commit の `git show <rev>:nix/home/options.nix` で読める
   (旧い本体で旧い flake を評価し直すことはできない。path: の入力は narHash で lock されるため)。値が変わる・消える
   ものは、どうするか (本体どおりにする・別の書き方で残す・本体を見直す) を推奨と理由を添えて聞く。別の書き方は、
   消えた option が前に何を作っていたか (前の commit の module) を読み、同じものを local に書く形を探す。基準が
   `old/` でないので、apply には `--accept-changes` が要り、反映には `~/dotfiles/setup --update` が要る

## 確認の形

apply の前に、この順で出す。

1. 何をするか: `~/dotfiles/flake.nix` を、元の雛形 (版と日付) から今の雛形の形へ移す
2. 変わる中身のまとめ: 説明の書き換え・足された節・移った例・「# 雛形の版:」の行・値の変化 (無ければ「値は変わらない」)
3. compare の結果 (例: 全 6 ホストで drvPath が同じ。home-manager の世代の中身は変わらないので、switch は要らない)
4. 差分: `diff -u ~/dotfiles/flake.nix <作業場所>/new/flake.nix` の全文。長ければ要点と、全文を読めるファイルのパス
5. 退避と戻し方: apply が `~/dotfiles/flake.nix.bak-<日時>` と `flake.lock.bak-<日時>` を置き、戻すのは `cp -p` の 2 つ
6. 問い: 「この内容で ~/dotfiles/flake.nix を書き換えてよいですか」(残っている判断があれば、選択肢ごと並べる)

## 戻し方

apply が出す `cp -p` の 2 つ (`flake.nix.bak-<日時>` と `flake.lock.bak-<日時>` を元の名前へ写す) で、移す前の
ファイルに戻る。移したあとに switch していなければ、それで終わり。`~/dotfiles/setup --update` を流したあとなら、
戻してからもう一度流すと前の値の世代になる (compare が「同じ」だったなら、世代の中身はもともと同じ)。動いているのを
確かめたら、退避は消してよい。

## よくある誤り

| やりがちなこと | どうするか |
| --- | --- |
| 「直して」と頼まれたので、確認を取らずに書く | 差分を見せて確認を取ってから apply |
| `setup-local-flake.sh --force` で作り直す | 値と足したホストが消える。prepare から移す |
| 1 ホストだけ評価して確かめた気になる | local は全ホストに当たる。compare が全ホストと並びを見る |
| 退避を作業場所に置く | ユーザーが見つけられない。apply が `~/dotfiles` に置く |
| 雛形の各版を perl や sed で自前に描く | prepare が描く (古い版の script を実行しない) |
| `old/flake.nix` を直して compare する | 基準は別のディレクトリに作り、`--baseline` で渡す |
| 本体を更新する前に移す | 新しい雛形の option が旧い本体に無い。先に本体を新しくする |

## 関連

- `nix/README.md`「雛形が新しくなったら」— 印・setup の知らせ・script の使い方
- ADR 024 — 雛形の版の印と、3-way merge と評価の比較で移すことの決定
- `pjp-dotfiles-update` skill — flake.lock を上げて switch まで通す側
