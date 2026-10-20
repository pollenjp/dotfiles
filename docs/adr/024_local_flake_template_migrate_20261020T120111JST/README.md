# ADR: ローカル flake の雛形に版の印を入れ、雛形が変わったら値を引き継いで 3-way merge で移し、評価して確かめる

| 項目 | 内容 |
| --- | --- |
| ステータス | 承認 (Accepted) — 方針は 2026-10-20 にユーザーが承認。文面は PR でレビュー |
| 日付 | 2026-10-20 (JST) |
| 決定者 | pollenjp |
| チケット | [TKT-228](https://app.notion.com/p/flake-dotfiles-flake-nix-flake-nix-skill-3ff79149a66f812da559fe8f48e8e2d5) |
| 関連 ADR | [002_nix_hosts_and_local_flake](../002_nix_hosts_and_local_flake_20260810T153848JST/README.md)（ローカル flake を git 管理外に置く決定。この ADR はその雛形の更新の扱いを足す）、[022_one_password_outside_wsl](../022_one_password_outside_wsl_20261018T105655JST/README.md)（旧名を `mkRenamedOptionModule` で新しい名前へ渡す決まり） |
| 運用手順 | [`nix/README.md`「雛形が新しくなったら」](../../../nix/README.md#雛形が新しくなったら) |
| 設計 | [`docs/superpowers/specs/2026-10-20-local-flake-migrate-design.md`](../../superpowers/specs/2026-10-20-local-flake-migrate-design.md) |

---

## 1. 背景 (Context)

`~/dotfiles/flake.nix` は `nix/scripts/setup-local-flake.sh` が heredoc の雛形から 1 度だけ作る、git 管理外の
マシン固有のファイル (ADR 002)。既にあれば触らず、`--force` は作り直すので、`local` に書いた値と手で足した
ホストが消える。

雛形は 2026-08-10 から 2026-10-19 までに 24 版ある (説明の書き換え・option の節の追加・例の移動)。既存のファイルは
古い形のまま残り、気づく仕組みは `hostsWith` と `notion.profile` を grep する 2 つの警告だけだった。ユーザーは
「気づかないまま旧い形で動いているやつもありそうかも」と言う。

本体で option が改名されたときは、旧名を新しい名前へ渡す決まり (ADR 022) なので、旧い `local` は警告を出しつつ動く。
削除されたとき・型が変わったときは、旧い `local` のままでは評価が止まる。setup.sh は手順が失敗すると残りの手作業を
出さないので、そのときは「古い雛形」の案内も見えなかった。

この変更を作った PC の実物では、`~/dotfiles/flake.nix` は 87922f9 版 (870b317 と同じ中身) の雛形から作られ、利用者が
変えたのは 4 行だった。最新の雛形 (a662c76) と 3-way merge すると 3 か所は機械的に移り、`ccPages.port` の行の
直後に videoOffer の節が足された所だけが隣接の衝突になった。

## 2. 決定 (Decision)

### A. 雛形の先頭に「雛形の版」の印を置く

```nix
# 雛形の版: <8 桁の 16 進>
#   雛形が新しくなると setup が知らせる。値を引き継いで今の雛形へ移すには
#   (Claude Code なら pjp-dotfiles-local-flake-migrate skill):
#     <本体>/nix/scripts/local-flake-migrate.sh prepare
```

- 印は heredoc の**原文** (展開する前) の POSIX cksum の CRC を 8 桁の 16 進にしたもの。原文にマシンごとのパスは
  入らないので、同じ版ならどのマシンでも同じ値になる。印の行は原文では `${template_id}` のままなので、印が自分を
  含んでも循環しない。heredoc の外 (script の処理) を直しても変わらない
- 計算と照合は `local-flake-migrate.sh` の `id`・`check` だけが持ち、setup-local-flake.sh (書くとき) と setup.sh
  (知らせるとき) はそれを呼ぶ。`id` と `check` は bash・awk・cksum だけで動く

### B. 印が今の雛形と違えば、setup が移し方を知らせる

| いつ | どこに |
| --- | --- |
| 手順が全部通ったとき (`--update` など) | 残りの手作業 |
| `--steps local-flake` を流したとき | setup-local-flake.sh の警告 (警告のまとめにも載る) |
| switch が落ちたとき | 失敗の案内のあと。本体で option が削除・改名されると旧い `local` のままでは評価が止まることも書く |

印の無いファイル (印を入れる前の雛形から作ったもの) も「違う」に数える。既存のマシンは一度ずつ知らせが出る。

### C. 値を引き継いで移すのは `nix/scripts/local-flake-migrate.sh`

| コマンド | すること |
| --- | --- |
| `status` / `check` | 印が今の雛形と同じか (`check` は setup のための静かな版) |
| `prepare` | 元の雛形を決め、手元・元の雛形・今の雛形を `git merge-file --diff3` で 3-way merge して作業場所に置く |
| `compare` | 旧い flake と移した flake を同じ本体・同じ lock で評価し、全ホストの `activationPackage.drvPath` と、setup が拾うホストの並びを比べる |
| `apply` | 退避 (`flake.nix.bak-<日時>`・`flake.lock.bak-<日時>`) を取ってから書く |

- **元の雛形**は、印があればその版。無ければ setup-local-flake.sh の履歴の各版を描き、旧いファイルとの差分が最も
  小さい版 (`--base <rev>` で選び直せる)。各版は `git show` で取り出した script から heredoc の原文を awk で抜き、
  bash の展開 (`${nix_dir}`・`${template_id}`・`\$` `` \` `` `\\`) を真似て描く。古い版の script は実行しない
  (古い版は `DOTFILES_LOCAL_DIR` を知らず、`~/dotfiles` に書きうる)。ほかの展開があれば描かずに止まる
- **衝突**のうち「片側が元の行の前後に足しただけ」のもの (コメントを外した行の直後に雛形が節を足した、など) は
  script が解く。両側が同じ所を直したものは diff3 の印のまま残し、Claude (かユーザー) が解く
- **確かめ方**は drvPath の一致。一致すれば home-manager の世代の中身が同じ (値を全部引き継げた) なので、switch も
  要らない。違えば、違うホストの `config.dotfiles` の差を「旧い → 新しい」で出す。drvPath に出ない「setup が
  文字列から拾うホストの並び」(一番上が既定の対象ホスト) も比べる
- 旧い flake が今の本体で評価できないときは、compare がそう出して 3 で終わる。評価が通るだけの直しを当てた基準を
  作り、`--baseline` で比べ直す
- apply は、prepare のあとに `~/dotfiles/flake.nix` が書き換わった・衝突の印が残る・今の中身で compare を流して
  いない、なら書かない。compare が同じでない (基準を直したときも) なら `--accept-changes` を要る

### D. 手順と判断は skill `pjp-dotfiles-local-flake-migrate` が教える

`nix/files/claude/skills/pjp-dotfiles-local-flake-migrate/SKILL.md`。ローカル flake が指す本体の script を呼ぶ
(skill は switch のときに store へ写るので、本体を pull しただけでは古い skill が残る)。**書き換える前に差分を
見せてユーザーの確認を取る**ことを禁止の形で書く。

## 3. 変更点の詳細

| ファイル | 変更 |
| --- | --- |
| `nix/scripts/local-flake-migrate.sh` | 新設 (status・check・prepare・compare・apply・id・render) |
| `nix/scripts/setup-local-flake.sh` | 雛形の先頭に印の行と案内。既にあるときに `check` で照合して警告。`hostsWith` の警告の直し方に移し方を足す |
| `nix/scripts/setup.sh` | 残りの手作業と、switch が落ちたときの案内に、旧い雛形の知らせ (`local_flake_stale`)。`hostsWith` の案内も移し方を先に書く |
| `nix/files/claude/skills/pjp-dotfiles-local-flake-migrate/SKILL.md` | 新設 |
| `nix/tests/local-flake-migrate.test.sh`・`nix/tests/setup-local-flake.test.sh` | 新設 (flake の checks に足した) |
| `nix/tests/setup-post-notes.test.sh` | 旧い雛形の知らせのケース。引数に `nix/scripts` のディレクトリを受ける |
| `nix/README.md` | 「雛形が新しくなったら」の節 |

## 4. 検討した代替案

| 案 | 採らなかった理由 |
| --- | --- |
| 印を付けず、setup が毎回履歴から元の版を探して知らせる | setup のたびに git の履歴を描き直すことになり重い。git の無い段階 (Nix を入れた直後) でも動く照合にしたい |
| 印を版の番号にする (雛形を直すたびに手で上げる) | 上げ忘れる。原文の cksum なら直すと必ず変わる |
| 印を git の commit にする | 走っている script は自分の commit を知らない (作業ツリーに commit していない変更もある)。heredoc の外を直しても変わってしまう |
| 印を `git hash-object` や `sha256sum` で計算する | setup は git や sha256sum が無い段階 (macOS の素の環境など) でも走る。POSIX の cksum は GNU と BSD で同じ値を出す |
| 雛形の元の写し (pristine copy) を `~/dotfiles` に置く | 置くファイルが増える。印なら 1 行で、元の版は履歴から確実に引ける |
| 値を抜き出して新しい雛形に差し込む (local の値を評価で取り出す) | local が関数の形 (`{ lib, ... }: …`) だと取り出せず、手で書いたコメントや足したホストの形が落ちる。3-way merge なら手で書いたものを残せる |
| 古い版の setup-local-flake.sh を実行して描く | 古い版は `DOTFILES_LOCAL_DIR` を知らず、`~/dotfiles` に書きうる |
| setup の中で自動で移す | git 管理外のユーザーのファイルなので、差分を見せて確認を取ってから書く。衝突や値の違いは人の判断が要る |
| 雛形を heredoc から別のファイルへ出す | 履歴の各版を描くときに置き場所が 2 通りになる。今回の目的には要らない |
| 1 ホストだけ評価して確かめる | local は登録簿の全ホストに当たる。全部を 1 回の評価でまとめて比べても 20〜60 秒 |

## 5. 影響 (Consequences)

良くなること:

- 雛形が変わったことに、`setup --update` のたびに気づける (説明だけの変更でも)
- 値と手で足したホストを残したまま、今の雛形の形 (説明・例・新しい option の節) へ移せる。値を引き継げたことを
  drvPath の一致で確かめられる
- 本体で option が削除されて switch が落ちたときに、原因の見当 (旧い local) と直し方がその場で出る

注意が必要なこと:

- 雛形を直すたびに (説明だけでも)、移すまで各マシンで知らせが出る
- 既存のマシンの `~/dotfiles/flake.nix` には印が無いので、全マシンで一度は知らせが出る
- 印の行を消した・書き換えたファイルは「印なし」として扱い、差分の最小で元の版を決める
- 浅い clone では古い版が履歴に無く、元の版を外すことがある (prepare がそう出す)
- compare は本体と lock を写しで評価するので、本体の lock が新しい nixpkgs を指していれば取得が走る

## 6. 検証 (Verification)

- `nix/tests/local-flake-migrate.test.sh` (64 件)・`nix/tests/setup-local-flake.test.sh` (9 件)・
  `nix/tests/setup-post-notes.test.sh` (30 件) を手元と flake の checks (サンドボックス) で流して通った
- 描き方: 履歴の 24 版を render で描くと、別のやり方 (awk と sed) で描いたものと 1 バイトも違わなかった。
  今の版は、setup-local-flake.sh が実際に書く flake.nix と render --file の出力が同じ (テストで確かめる)
- 実物 (この変更を作った PC の `~/dotfiles/flake.nix` の写し): prepare は元の雛形を 87922f9 (差分 8 行。870b317 も 8 行で同じ
  中身) に決め、衝突 1 件 (`ccPages.port` の直後の videoOffer の節) を自動で解いて残り 0 件。compare は登録簿の
  7 ホストの drvPath が全部同じ (41 秒)。`ccPages.port` を 7779 に変えると 7 ホストとも違い、
  `ccPages.port: 7778 → 7779` だけが出た
- skill: skill なしの subagent は確認を取らずに書き換え、drvPath を 1 ホストでしか比べなかった。skill を読ませた
  subagent の結果は PR に書く

## 7. 移行・運用手順

各マシンで、本体を新しくしたあと (setup が「前の雛形から作られています」と知らせたら):

```sh
m=~/ghq/github.com/pollenjp/dotfiles/nix/scripts/local-flake-migrate.sh
$m status
$m prepare --out /tmp/lfm
$m compare /tmp/lfm
diff -u ~/dotfiles/flake.nix /tmp/lfm/new/flake.nix
$m apply /tmp/lfm
```

Claude Code に任せるなら `pjp-dotfiles-local-flake-migrate` skill (差分を見せて確認を取ってから書く)。
