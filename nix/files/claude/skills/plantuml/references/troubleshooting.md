# うまく出ないとき

## フォント

`flake.nix` が `FONTCONFIG_FILE` を store の fonts.conf に向けている。これが無いと、
**日本語フォントを持たない環境で豆腐（□□□）になる。**

### `-static` でなければならない

`fontDirectories` に渡しているのは `pkgs.noto-fonts-cjk-sans-static`。
**`-static` を外してはいけない。**

`pkgs.noto-fonts-cjk-sans`（`-static` 無し）が配るのは**可変フォント**
`NotoSansCJK-VF.otf.ttc` で、**OpenJDK はこれを描画できず日本語が全て豆腐になる。**
図の生成自体は成功し、エラーも警告も出ないので気付きにくい。

`-static` の方は `NotoSansCJK-Regular.ttc`（静的）を配るので描ける。

drawio skill が可変フォントのままなのは Chromium にその制約が無いためで、
**同じフォント指定を skill 間でコピーしてはいけない。**

紛らわしいのは、fontconfig からは可変フォントも普通に見えていること。

```sh
fc-match -s :lang=ja | head -1
#=> NotoSansCJK-VF.otf.ttc: "Noto Sans CJK JP" "Regular"   ← 見えている
```

**`fc-match` が返すことは JDK が描けることを意味しない。** 切り分けるなら
fontconfig ではなく、JDK が実際に開いたファイルを見る。

```sh
nix shell nixpkgs#strace --command strace -f -e trace=openat -o tr.log \
  plantuml -charset UTF-8 -tpng -o /tmp/o 01_order.puml
grep -o '"[^"]*\.\(ttf\|otf\|ttc\)"' tr.log | sort -u
```

- 開いているのが `*-VF.*` → 可変フォント。`-static` な派生に変える
- CJK フォントを 1 つも開いていない → `fontDirectories` に入っていない
- 起動時に `SunFontManager` の例外で落ちる → フォントが 1 つも見つかっていない

### 手元の結果は他環境の根拠にならない

**厄介なのは、手元では効いていなくても気付けないこと。** `makeFontsConf` は
`/usr/share/fonts` を残すうえ、**JDK は fontconfig とは別に `/usr/share/fonts` を
直接見る**。ホストに Noto CJK があれば、設定が間違っていても同じ絵が出る。

確かめるには、ホストのフォントが見えない nix サンドボックスで書き出す。

```nix
# test.nix （sample.puml を隣に置く）
let
  pkgs = import <nixpkgs> { };
  fontsConf = pkgs.makeFontsConf {
    fontDirectories = [ pkgs.noto-fonts-cjk-sans-static pkgs.dejavu_fonts ];
  };
in
pkgs.runCommand "font-test" { nativeBuildInputs = [ pkgs.plantuml ]; } ''
  export HOME=$TMPDIR
  mkdir -p "$out"
  export FONTCONFIG_FILE=${fontsConf}   # これを外すと豆腐になる
  cp ${./sample.puml} in.puml
  plantuml -charset UTF-8 -tpng -o "$out" in.puml
''
```

```sh
nix-build test.nix --no-out-link
```

出てきた PNG を目で見る。`FONTCONFIG_FILE` の行を消すと豆腐になることも確かめておくと、
テスト自体が効いていることの確認になる。

- **PNG は fonts.conf が必須**（ラスタライズする）
- **SVG も入れておく。** 表示は閲覧側のフォント次第だが、PlantUML は出力時に
  フォントメトリクスで文字幅を計算するため、無いとレイアウトがずれる

### JDK が探索結果をキャッシュする

JDK は `~/.java/fonts/<version>/fcinfo-*.properties` に探索結果を残す。
フォント設定を変えて試すときは `HOME` も差し替えないと**前回の結果を引く**
（「変えたのに何も変わらない」の原因はたいていこれ）。

```sh
HOME=$(mktemp -d) plantuml -tpng -o /tmp/o 01_order.puml
```

## graphviz

シーケンス図とアクティビティ図以外（クラス図・コンポーネント図・状態遷移図など）は
レイアウトに graphviz を使う。

nixpkgs の `plantuml` は graphviz を同梱していて `GRAPHVIZ_DOT` も設定済みなので、
**`sudo apt install graphviz` は要らない。** 導通確認はこれで出る。

```sh
plantuml -testdot
#=> Installation seems OK. File generation OK
```

`Error: No dot executable found` が出るなら、この skill の flake を通さずに
素の `plantuml` を叩いている。`scripts/plantuml-export.sh` を使うか
`nix develop ~/.claude/skills/plantuml` に入る。

## レイアウトが崩れる

- ラベルが長いと図が横に伸びる。`\n` で折るか、`participant "..." as X` で
  短い別名を付ける
- 要素の並び順は宣言順に依存する。`participant` を先に並べておくと安定する
- クラス図で線が交差するときは `hide empty members` や `left to right direction` を試す

いずれも**目で見ないと判らない**。`-f png` で書き出して確認する。

## 出力先が散らばる

`plantuml` の `-o` は **`.puml` からの相対**として解釈される。サブディレクトリの
`.puml` を混ぜると出力もそこへ散らばる。`scripts/plantuml-export.sh` は `-o` を
絶対パスへ直してから渡しているので、この症状は出ない。素で叩くときは注意する。
