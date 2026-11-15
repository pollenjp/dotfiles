# 閉包スキャンの findings (dotfiles の `nix/`)

flake.lock を上げる `update` (`nix/scripts/flake-lock-age.sh update "$PWD/nix"`) の最後に、閉包スキャン
(`nix/scripts/closure-scan.sh`。ADR 006) が自動で挟まる。dotfiles の `nix/` には whitelist (`nix/vulnxscan-whitelist.csv`) が
あるので、スキャンは `scan` モード = ゲートとして働き、whitelist に無い findings があると終了コード 1 で落ちる。ここが人の判断を
要るゲートで、その扱いがこのファイルの中身。

## ゲートが落ちたときの状態

| | 状態 |
| --- | --- |
| worktree の `nix/flake.lock` | すでに書き換わっている (作業ツリーが dirty) |
| PR | まだ出していない。出すと CI の閉包スキャン (`nix` の `closure-scan`) も同じ findings で落ちる |

- 素で打ち直しても同じところで止まる。lock はもう猶予を満たす直近を指していて、`update` は (その間に新しい公開が猶予を越えて
  いなければ) 同じ revision を選び直し、同じ findings で同じゲートに当たる。findings を片付けるまで前へ進まない
- `--no-scan` で飛ばすことは選択肢に入れない。この照合は「発覚済みの侵害バージョンを猶予のあいだ固定し続ける」という遅延に
  固有のリスクを塞ぐために入れたもので (ADR 006)、飛ばすと遅延だけが残る
- 閉包の build と grype の DB の取得があるので、数分〜十数分かかる。裏で流して出力を追う

## スキャナ (sbomnix) を組めずに止まったとき

`closure-scan` が「sbomnix を組めませんでした。試した pin:」で止まったら、findings ではなくスキャナの用意で落ちている (ADR 040)。
新しい pin でも、git の履歴の前の pin (新しい順に 3 つまで) でも sbomnix を組めなかった。ゲートの判定に届いていないので、
下の 2 択の話ではない。

- 並んだ pin とわけ (最初に組めなかった derivation か、`flake.lock を読めない: …` の nix のエラー) を出す。前の pin がどれも
  「読めない」なら、pin ではなく script か nix の側の問題なので、そのわけを添えて報告する
- 組める版の sbomnix を PATH に置けば、それで照らす (PATH にあれば組まない)。遅延を守った pin (前に入れた `flake.lock` の nixpkgs の
  rev) から取り、どの rev から取ったかを報告に書く。lock はもう書けているので、スキャンだけを流し直す:

  ```sh
  nix shell 'github:NixOS/nixpkgs/<前に入れた rev>#sbomnix' --command ./nix/scripts/closure-scan.sh scan
  ```

退いて照らせたとき (「sbomnix を対象の pin で組めなかったので、…で照らします」の警告が出て、ゲートまで届いたとき) は、ふだん
どおり findings を読む。

## findings を読む

`closure-scan` は成果物のディレクトリを出力に出す。既定は `mktemp -d` なので毎回変わる。出力から拾う。

```
成果物: /tmp/tmp.XXXXXXXX
  new-findings.txt   <- whitelist に無い findings ("vuln_id<TAB>package")
  vulns.csv          <- 全件。whitelist / whitelist_comment 列つき
  report.txt         <- 上に出した findings の表 (whitelist に無いものと受け入れた件数。vulns.csv から作る。CI の summary もこれ)
  scanner.txt        <- 照らした sbomnix と、どの pin から取ったか (退いたなら組めなかった pin も)
  sbom.csv / sbom.cdx.json / sbom.spdx.json
```

貼り直したり後から読み返したりするなら、場所を固定して単体で流す (ゲートせず表示だけの `report` を使う。`scan` は CI と同じで落ちる)。

```sh
./nix/scripts/closure-scan.sh report --out-dir <scratchpad>/closure-scan-out
```

## 切り分け

`new-findings.txt` の各行を A か B へ寄せる。

### A. CPE の誤マッチ (実在しない)

vulnix・Grype はパッケージ名から CPE を引くので、同名の別製品の CVE を拾う。導入の時点で 8 件見つかっており (ADR 006)、
whitelist に実例が残っている。

| findings | 実際 |
| --- | --- |
| `CVE-2007-1397` / `fish` | IRC の暗号化プラグイン FiSH の CVE。fish shell ではない |
| `CVE-2021-21684` / `git` | Jenkins の Git Plugin の CVE。git 本体ではない |

判定は advisory の本文の影響製品・CPE を読み、閉包に入っているパッケージと一致するかを見る。「名前が同じ」を一致の根拠にしない。

### B. 実在する CVE

さらに次を調べる。

- **pin を動かして直るか**: `flake-lock-age.sh resolve` が選ぶ先で修正版に届くか。pin と先端の版の差分は `closure-head-diff.sh`
- **修正が猶予より新しい側にしか無いか**: あるなら「期間付きの例外を足すか (`nix/release-age.nix`。全体・一部 nixpkgs・一部
  upstream。`nix/README.md` の「猶予の日数と例外」)・遅延を外すか」の話になる
- **到達性**: ワークステーションで実際に踏む経路があるか。閉包のどこに居るかは `sbom.csv`

## 2 択と、ユーザーに聞く線

対応は 2 つしかない (ADR 006 §7。`closure-scan.sh` のエラーの文も同じ)。

1. **pin を動かす**: `flake-lock-age.sh resolve`・`update`。修正が猶予より新しい側にしか無いなら、`nix/release-age.nix` に期間付きの
   例外を足すか、`--min-age-days N` を下げる判断まで含む。例外は全体 (nixpkgs 全体を日付まで)・一部 nixpkgs (その package だけを
   日付までの nixpkgs から)・一部 upstream (nixpkgs に修正版がまだ無い package を upstream の配布物から)。一部の例外は、ほかの
   package から使われないアプリだけ (ライブラリは全体)
2. **意図して受け入れる**: `closure-scan.sh baseline` で whitelist へ追記し、comment に理由を書いて commit

> ⚠️ **どちらも、実行する前にユーザーへ持っていく。**
> whitelist は ADR 006 が明言しているとおり「安全と確かめた」印ではなく増分検知の基準線で、追記はリスク受容の意思表示。
> `--min-age-days` を下げるのは ADR 005 の遅延を意図して外す判断で、例外を足すのはそれを日付と範囲で区切って外す判断。
> どれも人が決めること。

### Claude がすること

切り分けと提案まで。

- `new-findings.txt` の全件を A と B に分ける。A は「どの製品の CVE か」まで書く
- B は、pin を動かして直るか・猶予を外さないと直らないかを調べる
- 表にして出し、そこで止まる (会話ならユーザーに聞く。定期実行なら PR の本文とチケットに書いて終わる)

出す形 (例):

| findings | 判定 | 根拠 | 推奨 |
| --- | --- | --- | --- |
| `CVE-20xx-xxxx` / `foo` | 誤マッチ | 別製品 Foo Server の CVE。閉包の foo は CLI | 受け入れ |
| `CVE-20xx-yyyy` / `curl` | 実在 / High | 修正は 8.x.y。猶予 7 日では届かない | 判断を要求 |

### 承認を得るまでしないこと

- `closure-scan.sh baseline` (whitelist への追記)
- `--min-age-days` を下げた `update`
- `nix/release-age.nix` への例外の追加
- `--no-scan`
- `flake.lock` を手で戻す・`git checkout` で捨てる (更新を無かったことにするのも判断)

承認が出たら実行する。`baseline` が書く comment は

```
"baseline (YYYY-MM-DD): この時点の既知として受け入れ。理由は棚卸しで追記"
```

という定型なので、**承認で出た理由に書き換えてから** commit する。定型のまま残すと基準線が読めなくなる (既存 67 件の棚卸しが
宿題として残っているのと同じ状態を増やす)。

## 片付けたら

- 同じ `update` を打ち直すか、`./nix/scripts/closure-scan.sh scan` で緑を確かめてから、`flake.lock` (と whitelist・
  `nix/release-age.nix`) を PR に入れる
- whitelist への受け入れ・例外の追加・猶予を外した上げは、人の判断を受けて足す commit。依存の更新の skill の決まり (会話で受けた
  判断を足す commit・PR の分け方) に従う
- この PC への反映は merge の後にユーザーが打つ (SKILL.md の「反映」)
