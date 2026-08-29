---
name: pjp-dotfiles-update
description: dotfiles の依存 (`nix/flake.lock`) を更新して home-manager switch まで通すときに使う。
  「dotfiles を更新して」「flake.lock を上げて switch して」「setup --flake-update --update を
  走らせて」と言われたときに読む。**閉包スキャンが whitelist に無い findings で落ちたときの
  切り分けと、pin を動かすか whitelist へ受け入れるかの 2 択の扱い**を含む。findings の
  リスク受容と遅延を外す判断は必ずユーザーに持っていく。**他の** repo に flake を用意する /
  lock を更新する話は pjp-nix-flake skill の側。
---

# pjp-dotfiles-update

dotfiles 本体の依存を上げて switch まで通す手順。落ちる場所がほぼ 1 箇所に決まって
いて、そこが**人間の判断を要求するゲート**なので、その扱いがこの skill の中身。

## 実行

```sh
~/dotfiles/setup --flake-update --update
```

- `~/dotfiles/setup` は本体の `nix/scripts/setup.sh` への symlink
- 走る手順は `ssh-config` → `flake-update` → `switch` → `bootstrap-*`
  （`--update` プリセットに `--flake-update` を足した形）。`bootstrap-*` は
  どれも冪等で、`switch` の**後**に走る（`jq` / `mise` が要るため）
- **`--update` はメニューを通らないので対話は無い。** sudo も要らない
  （`chsh` はプリセットに入らない）
- 閉包の build と grype DB のダウンロードがあるので数分〜十数分かかる。
  背景実行して出力を追う
- 何が走るか見るだけなら `--dry-run`

## flake-update の中で起きること

1. `flake-lock-age.sh update ./nix` — **公開から 7 日以上経った** revision へ pin
   （ADR 005 の遅延。素の `nix flake update` は使わない）
2. **その完了時に `closure-scan` が自動で挟まる**（ADR 006）。本体には whitelist が
   あるので `scan` モード = **ゲート**として働く
3. `sync_local_flake_lock` — `~/dotfiles` 側の lock を張り直す
4. `switch`

日数を変えるなら `DOTFILES_MIN_RELEASE_AGE_DAYS=N`（setup.sh が
`FLAKE_MIN_RELEASE_AGE_DAYS` へ橋渡しする）。

## ⚠️ ゲートが落ちたときの状態

`closure-scan scan` は whitelist に無い findings があると終了コード 1。手順ループは
失敗した時点で `break` する（`nix/scripts/setup.sh:1613`）。このとき:

| | 状態 |
| --- | --- |
| `nix/flake.lock` | **すでに書き換わっている**（repo が dirty） |
| `~/dotfiles/flake.lock` | 未同期（`sync_local_flake_lock` へ到達していない） |
| `switch` | **走っていない**（結果表で「未実行」に出る） |

**素で再実行しても同じところで止まる。** lock はもう下限を満たす直近を指しているので、
`update` は（その間に新しい公開が下限を越えていなければ）同じ revision を選び直すだけで、
同じ findings で同じゲートに当たる。**findings を片付けるまで前へ進まない。**

`--no-scan` で飛ばすことは選択肢に入れない。この照合は「発覚済みの侵害バージョンを
下限日数のあいだ固定し続ける」という遅延固有のリスクを塞ぐために入れたもので
（ADR 006）、飛ばすと遅延だけが残る。

## findings を読む

`closure-scan` は成果物のディレクトリを出力に出す。**既定は `mktemp -d` なので毎回
変わる。出力から拾う。**

```
成果物: /tmp/tmp.XXXXXXXX
  new-findings.txt   <- whitelist に無い findings ("vuln_id<TAB>package")
  vulns.csv          <- 全件。whitelist / whitelist_comment 列つき
  report.txt         <- 表示された表 (CI の summary もこれ)
  sbom.csv / sbom.cdx.json / sbom.spdx.json
```

貼り直したり後から読み返すなら、場所を固定して単体で回す（ゲートせず表示だけの
`report` を使う。`scan` は CI と同じで落ちる）。

```sh
./nix/scripts/closure-scan.sh report --out-dir /tmp/closure-scan-out
```

## 切り分け

`new-findings.txt` の各行を A / B のどちらかへ寄せる。

### A. CPE 誤マッチ（実在しない）

vulnix / Grype はパッケージ名から CPE を引くので、**同名の別製品**の CVE を拾う。
導入時点で 8 件確認されており（ADR 006）、whitelist に実例が残っている。

| findings | 実際 |
| --- | --- |
| `CVE-2007-1397` / `fish` | IRC 暗号化プラグイン FiSH の CVE。fish shell ではない |
| `CVE-2021-21684` / `git` | Jenkins Git Plugin の CVE。git 本体ではない |

判定は advisory 本文の影響製品 / CPE を読んで、閉包に入っているパッケージと
一致するか見る。**「名前が同じ」を一致の根拠にしない。**

### B. 実在する CVE

さらに次を調べる。

- **pin を動かして直るか** — `flake-lock-age.sh resolve` が選ぶ先で修正版に届くか。
  pin と先端の版差分は `closure-head-diff.sh`
- **修正が下限日数より新しい側にしか無いか** — あるなら「遅延を外すか」の話になる
- **到達性** — ワークステーションで実際に踏む経路があるか。閉包内のどこに居るかは
  `sbom.csv`

## 2 択と、ユーザーに聞く線

対応は 2 つしかない（ADR 006 §7、`closure-scan.sh` のエラーメッセージも同じ）。

1. **pin を動かす** — `flake-lock-age.sh resolve` / `update`。修正が下限より新しい側に
   しか無いなら `--min-age-days N` を下げる判断まで含む
2. **意図して受け入れる** — `closure-scan.sh baseline` で whitelist へ追記し、comment に
   理由を書いて commit

> ⚠️ **どちらも、実行する前にユーザーへ持っていく。**
> whitelist は ADR 006 が明言しているとおり「安全と確認した」印ではなく**増分検知の
> 基準線**で、追記は**リスク受容の意思表示**。`--min-age-days` を下げるのは ADR 005 の
> 遅延を意図して外す判断。どちらも人間が決めること。

### Claude がやること

切り分けと提案まで。

- `new-findings.txt` の**全件**を A / B に分ける。A は「どの製品の CVE か」まで書く
- B は pin を動かして直るか / 下限を下げないと直らないかを調べる
- 表にして出し、**そこで止まる**

出す形（例）:

| findings | 判定 | 根拠 | 推奨 |
| --- | --- | --- | --- |
| `CVE-20xx-xxxx` / `foo` | 誤マッチ | 別製品 Foo Server の CVE。閉包の foo は CLI | 受け入れ |
| `CVE-20xx-yyyy` / `curl` | 実在 / High | 修正は 8.x.y。下限 7 日では届かない | 判断を要求 |

### 承認を得るまでやらないこと

- `closure-scan.sh baseline`（whitelist への追記）
- `--min-age-days` を下げた `update`
- `--no-scan`
- `flake.lock` を手で戻す / `git checkout` で捨てる（更新を無かったことにするのも判断）

承認が出たら実行する。`baseline` が書く comment は

```
"baseline (YYYY-MM-DD): この時点の既知として受け入れ。理由は棚卸しで追記"
```

という定型なので、**承認で出た理由に書き換えてから** commit する。定型のまま残すと
基準線が読めなくなる（既存 67 件の棚卸しが宿題として残っているのと同じ状態を増やす）。

## 片付け

findings を片付けたら、止まった手順から先へ通す。同じコマンドをもう一度で通る
（ゲートが緑になっているはず）。

```sh
~/dotfiles/setup --flake-update --update
```

スキャンをもう一度待ちたくない場合は、先に単体で緑を確認してから switch だけ。

```sh
./nix/scripts/closure-scan.sh scan   # 緑を確認
~/dotfiles/setup --steps switch
```

そのあと `flake.lock` と whitelist を commit する（**ユーザーの指示があったときだけ**）。

```sh
git -C "$(ghq root)/github.com/pollenjp/dotfiles" add nix/flake.lock nix/vulnxscan-whitelist.csv
```

`post_notes` も促してくる。**未 commit のままだと以後 `u` / `--self-update` が本体を
更新しなくなる**（未 commit の変更があるマシンでは pull しない設計）。

## 関連

- `nix/README.md` 「依存 (flake.lock) の更新」「閉包のスキャンと pin↔先端の差分」— 日常運用
- ADR 005 — 新しすぎる revision を pin しない（遅延）の決定
- ADR 006 — 閉包の SBOM 化 + OSV / GHSA 照合の決定。whitelist の性格、初期 67 件、
  誤マッチ 8 件、CI のジョブ構成
- `pjp-nix-flake` skill — **他の** repo に flake を用意する / lock を更新する側
