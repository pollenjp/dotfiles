# ADR: 閉包を SBOM 化して OSV ベースでスキャンし、pin と先端の差分を照合する

| 項目 | 内容 |
| --- | --- |
| ステータス | 提案 (Proposed) — レビュー中 |
| 日付 | 2026-08-23 (JST) |
| 決定者 | pollenjp |
| 前提 ADR | [005_nix_flake_lock_min_release_age](../005_nix_flake_lock_min_release_age_20260813T184522JST/README.md)（delay pin。本 ADR はその遅延が新しく作るリスクを塞ぐ） |
| 運用手順 | [`nix/README.md`](../../../nix/README.md#閉包のスキャンと-pin先端の差分-遅延の補完)（日常運用はこちら） |

---

## 1. 背景 (Context)

### delay pin が新しく作るリスク

ADR 005 で `flake.lock` の pin に最小経過日数 7 日を課した。この遅延は
「出たばかりのものを掴まない」＝**未発覚の侵害を誰かが先に踏む時間を稼ぐ**ための
ものだが、発覚済みの侵害に対しては**逆に働く**。具体的にはこうなる。

| 日 | 出来事 |
| --- | --- |
| day 1 | cli A の vX.Y.Z が上流 (GitHub Release / npm など) でリリースされる |
| day 2 | nixpkgs に vX.Y.Z が取り込まれ、チャンネル公開・binary cache に載る |
| day 3 | vX.Y.Z がサプライチェーン侵害だったと発覚。上流はリリースを削除し vX.(Y+1).Z を出す |
| day 4 | 上流から消えても、day 2 時点の nixpkgs ツリーには vX.Y.Z が残ったまま |
| day 9 | 7 日前の revision へ pin して `flake.lock` を作る（＝ day 2 のツリー）→ **発覚済みの vX.Y.Z が入る** |

nixpkgs はソース tarball を固定出力ハッシュで pin しているので、上流の削除や
差し替えの影響を受けずに**過去のツリーを忠実に再現できてしまう**（tarball は
`cache.nixos.org` にミラーされている）。再現性という長所が、ここでは「発覚済みの
侵害バージョンを下限日数のあいだ固定し続ける」短所として出る。先端を追っていれば
day 3 以降の修正版へ飛べたはずのものが、pin では侵害版に留まる。

### 発覚済みなら advisory に載る — ただし載る場所が問題

「発覚済み」であることが遅延との違いで、発覚した侵害は脆弱性データベースに載る。
だから **pin した結果として実際に入る閉包**を advisory と照合すれば、この窓は
検知に変えられる。問題はどのデータベースを見るか。

- **vulnix は NVD (CVE) ベース。** 一方「npm や GitHub Release に悪意ある
  バージョンが混入した」タイプの事件は **CVE が採番されないか、大幅に遅れる**
  ことが多い。この種の侵害は主に **GitHub Advisory (GHSA) / OSV** で追跡され、
  OSV には即日〜数日で載るが NVD には載らない・数週間遅れる、が実態
- つまり「delay pin + vulnix」は、守りたかった脅威（発覚済みの侵害バージョン）に
  対して、いちばん重要な最初の数日〜数週間で検知できない可能性が高い。CVE が
  枯れてから効く網なので、無意味ではないが主目的とずれる

よって **OSV / GHSA を見るスキャナが本命、vulnix は補助線**という編成にする。
導入時の実測でも vulnix の findings には CPE 誤マッチ（`git` に Jenkins Git
Plugin の CVE が当たる等）が混ざっており、単体でゲートを張れる精度ではない（§6）。

### advisory にもまだ載っていない窓

発覚から advisory 掲載までの間も、**nixpkgs 側の対応**（バージョン bump・revert・
`knownVulnerabilities` 追加）が advisory より先に入ることがよくある。つまり
「pin と現在のチャンネル先端の間で、自分の閉包に入るパッケージに変更が入って
いないか」を見れば、advisory 未採番の窓もある程度塞げる。ただし版が動くこと自体は
日常（通常の更新も同じ形）なので、機械では侵害対応と区別できない。ここは
**自動 fail ではなく人間が読むレポート**にする。

### それでも残る窓

「発覚したが advisory にも nixpkgs にも未反映」「そもそも未発覚」の期間は、
どの構成でも残る。役割分担はこう整理する。

| 窓 | 担当 |
| --- | --- |
| 未発覚 | delay pin（ADR 005）。誰かが先に踏んで発覚する時間を稼ぐ |
| 発覚 〜 nixpkgs 対応 | （残る。短いことを期待するしかない） |
| nixpkgs 対応 〜 advisory 掲載 | pin↔先端の差分レポート（本 ADR） |
| advisory 掲載以降 | 閉包スキャン（本 ADR）。毎日の定期実行で pin 更新を待たず検知 |

## 2. 決定 (Decision)

全体は次の 4 点構成。1 は ADR 005 で導入済みで、本 ADR は 2〜4 を足す。

> **delay pin (7 日) + 閉包の SBOM 化 + OSV ベースのスキャン + pin 更新時の先端 diff 確認**

1. **delay pin** — ADR 005 のまま（`flake-lock-age.sh`）
2. **閉包の SBOM 化** — 実際に入る runtime 閉包をビルドし、`sbomnix` で
   CycloneDX / SPDX / csv を成果物として残す。lockfile の静的解析ではなく
   **実物（store path）を照合する**ので間接依存も拾えるし、SBOM を残しておけば
   過去の閉包に後から出た advisory を照合し直せる（`vulnxscan --sbom`）
3. **OSV ベースのスキャン** — `vulnxscan`（sbomnix 同梱。**OSV + Grype + vulnix**
   の束）でスキャンし、whitelist に無い findings があれば CI を落とす。
   whitelist（[`nix/vulnxscan-whitelist.csv`](../../../nix/vulnxscan-whitelist.csv)）は
   「安全と確認した」印ではなく**増分検知の基準線**。閉包には既知 CVE が常に
   数十件あるので（導入時点で 67 件）、全 findings で落とすとゲートは初日から
   赤いままになる。落ちたときの対応は「pin を動かして直るか見る」か「理由を
   comment に書いて whitelist へ足す」の 2 択で、受け入れは git 管理の csv への
   追記だから **PR の diff がそのまま監査線**になる
4. **pin↔先端の差分レポート** — pin と現在のチャンネル先端の両方で閉包を組み、
   `nix store diff-closures` で入るパッケージの版差分を出す。**差分があっても
   落とさない**（pin を更新する PR のレビュー材料）

補足の決定:

- **スキャナ自身も pin された nixpkgs から取る。** script は sbomnix が PATH に
  無ければ `nix shell --inputs-from <flake> nixpkgs#sbomnix` で入り直す。
  スキャナも外部ツールである以上、その供給網にも同じ遅延ポリシーを効かせる
- **スキャンは PR / push に加えて毎日の定期実行でも回す。** advisory は pin より
  後から出るので、commit の無い期間も現在の pin が指す閉包を照合し続ける
- **対象の閉包は `homeConfigurations.sandbox`**（x86_64-linux）。パッケージ集合は
  全ホスト共通（`nix/home/modules/packages.nix` に集約されていて、ホスト差は
  設定側にしか無い）ので代表として使う。skill 側 flake（`pjp-drawio` /
  `pjp-plantuml`）の閉包と buildtime 閉包は今回の対象外（§5）
- **比較先は git master の HEAD ではなくチャンネル先端。** master は Hydra を
  通っていない commit を含み binary cache が揃わないし、将来の pin が辿り着く
  先もチャンネル公開だけ（ADR 005 と同じ理由）

## 3. 変更点の詳細

| ファイル | 変更 |
| --- | --- |
| `nix/scripts/closure-scan.sh` | 新規。`scan`（SBOM 化 + vulnxscan + whitelist 照合。新規 findings で終了コード 1）と `baseline`（今の findings を whitelist へ追記）の 2 動作 |
| `nix/scripts/closure-head-diff.sh` | 新規。pin と先端で閉包を組んで `nix store diff-closures`。差分の有無では落ちない |
| `nix/vulnxscan-whitelist.csv` | 新規。`baseline` で生成した 67 件（詳細は下）。列は `"vuln_id","package","comment"`（vuln_id は正規表現・完全一致、package は完全一致） |
| `.github/workflows/nix.yml` | `closure-scan` ジョブ（PR / push / workflow_dispatch / **毎日の schedule**。summary へ表、SBOM と findings を artifact へ）と `head-diff` ジョブ（`nix/flake.lock` の動いた PR のみ）を追加。schedule では他ジョブを回さない。concurrency の group へ `event_name` を足した（schedule と push が同じ ref を共有して互いを取り消すため） |
| `nix/README.md` | 「閉包のスキャンと pin↔先端の差分」節を追加 |
| `docs/adr/001_.../textbook/05_daily_usage.md` | pin 更新 PR で CI が出す 2 つのレポートを追記（手順書なので現行に追随） |
| `nix/files/claude/skills/pjp-nix-flake/references/lock-age.md` | 「効かない範囲・限界」に「発覚済みの侵害バージョンを固定し続ける」を追記し、本 ADR を指す |

### sbomnix の採用確認（メンテ状況）

採用前に確認した（2026-08-23 時点）。

| 確認 | 結果 |
| --- | --- |
| nixpkgs（pin `104240a`）の sbomnix | 1.8.0。`vulnxscan` / `sbomnix` / `nixgraph` 等を同梱し、grype / vulnix も wrap 済み |
| upstream (tiiuae/sbomnix) | archived ではない。最終 push 2026-08-22（前日）、最新リリース v1.8.0（2026-06-09）で nixpkgs と一致 |

### whitelist の初期値（baseline 67 件）

`closure-scan.sh baseline` で生成し、確認できたものは comment に理由を書いた。

| 分類 | 件数 | comment |
| --- | --- | --- |
| CPE 誤マッチ（確認済み） | 8 | `git` への Jenkins Git Plugin の CVE 6 件（OSV で確認）、`zlib` への Cloudflare fork 版の CVE 1 件、`fish` への IRC 暗号化プラグイン FiSH の CVE 1 件（NVD で確認） |
| OSS-Fuzz の finding | 8 | `OSV-*` 系列である旨 |
| その他の既知 CVE | 51 | 「この時点の既知として受け入れ。理由は棚卸しで追記」。glibc / gnutls / openssl / vim など、nixpkgs 側でも未修正のもの |

**baseline は安全宣言ではない。** 51 件の個別の棚卸し（修正版の有無、該当条件）は
別作業として残っている。ゲートの目的は今後の**増分**を人間の判断に回すこと。

## 4. 検討した代替案

| 案 | 採らなかった理由 |
| --- | --- |
| **vulnix 単体**（delay pin + vulnix） | NVD ベースなので、サプライチェーン侵害の主戦場（OSV / GHSA）が見えない。発覚済み侵害への応答時間が合わず、主目的とずれる（§1） |
| **flake.lock / 依存リストの静的解析** | 閉包を見ないと間接依存を取りこぼす。実物（store path）から SBOM を作る形なら、入るものと照合対象が必ず一致する |
| **Grype や osv-scanner を単体で使う** | nix の閉包から CPE / purl 付きの SBOM を作る部分が別途要る。sbomnix はそこが本体で、vulnxscan は OSV / Grype / vulnix をまとめて呼んで結果を 1 つの表に畳む。単体ツール構成は同じものの自作になる |
| **whitelist なしで全 findings を fail** | 閉包には既知 CVE が常に数十件ある（導入時点 67 件）。初日から赤いままのゲートは形骸化する |
| **先端 diff で自動 fail** | 版が動くこと自体は日常で、侵害対応と機械では区別できない。fail させると常に赤 → 無視される。人間が読むレポートに留める |
| **比較先を git master の HEAD にする** | binary cache が揃わない（ほぼ全部ソースビルド）。将来の pin が辿り着く先もチャンネル公開（ADR 005 と同じ理由） |
| **buildtime 閉包までスキャンする** | toolchain 全体が入って findings のノイズが桁で増える。まず実際にディスクへ載る runtime 閉包から。必要になったら `--buildtime` で広げられる |
| **定期スキャンを週次にする** | advisory 掲載から検知までの遅れが最大 7 日＝遅延と同じ長さになり本末転倒。毎日なら ≤1 日。public リポジトリなので CI 分は無料 |
| **eval だけで pin↔先端の差分を取る**（ビルドせず drv を列挙） | runtime の依存はビルド産物を走査して決まるので、eval だけでは buildtime 閉包（超集合）しか出せずノイズが増える。両側ともチャンネル公開でビルド＝ほぼダウンロードなので、実物の runtime 閉包を比べる |

## 5. 影響 (Consequences)

### 良くなること

- **発覚済みの侵害バージョン（advisory 掲載後）を毎日検知できる。** delay pin が
  作った「発覚済みを固定し続ける」窓が、最大 1 日の検知遅れまで縮む
- 新規 CVE の増分が PR / 定期実行で見える。受け入れの判断が whitelist の diff
  として履歴に残る
- SBOM が CI の artifact として残る。過去の閉包に後から出た advisory を
  `vulnxscan --sbom` で照合し直せる
- pin を更新する PR に「何が動くか」の一覧が付く。レビューが「見覚えの無い
  動きだけコミットログを見る」作業になる

### 注意が必要なこと

- **whitelist は基準線であって安全宣言ではない。** baseline 51 件の棚卸しは別作業
- **vulnix / Grype の CPE 誤マッチは今後も出る**（導入時点で 8 件確認）。新規
  findings の一部は false positive の切り分け作業になる。それでも「増分だけ見れば
  よい」状態の方が、見ないより明確に良い
- `nix store diff-closures` は**版とサイズの変化しか出さない**。同じ版のまま
  ビルドだけ変わる対応は映らない。ただし `knownVulnerabilities` が付いた場合は
  先端側のビルドが insecure で**止まる**ので、ジョブの失敗として見える
- スキャン対象は sandbox（x86_64-linux）の runtime 閉包だけ。**skill 側 flake
  （electron を含む pjp-drawio など）、buildtime 閉包、darwin の閉包は見ていない。**
  広げるなら ADR 005 が適用先を広げたのと同じ形で別途（whitelist の運用コストと
  相談）
- vulnxscan がスキャナ内部の失敗を握りつぶす形（例: ネットワーク断で 0 件に
  見える）は、この構成では検知できない。終了コードが非ゼロになる失敗は CI で
  見える
- grype の DB・OSV / NVD への照会で**毎回ネットワークアクセスが要る**（CI 実測
  で全体 5 分弱）。オフラインでは回らない
- 定期実行の失敗に気付く経路は GitHub の workflow 失敗通知
- **この網も Nix 管理の範囲だけ。** mise / npm / uv 側の依存には効かない
  （ADR 005 と同じ注意）

## 6. 検証 (Verification)

すべて Determinate Nix 3.21.9 (nix 2.34.8) / WSL2 で実測（2026-08-23 JST）。

### スキャン本体

| 確認 | 結果 |
| --- | --- |
| sandbox 閉包の規模 | 1.3 GiB / 368 store paths |
| `vulnxscan`（whitelist なし） | 1 分 30 秒で findings 77 行（重複を除いて 67 の vuln_id×package、25 パッケージ）。内訳は Grype / OSV / vulnix の列で出る |
| whitelist の一致仕様 | `vuln_id` は正規表現の完全一致、`package` は完全一致。一致した行は console の表から消え、`vulns.csv` に `whitelist` / `whitelist_comment` 列が付く（試験用 whitelist で vim 9 件・git 2022 系 10 行が消えることを確認） |
| `baseline` | 67 件を追記（変種の重複は dedupe）。直後の `scan` は「whitelist に無い findings はありません」で終了コード 0 |
| ゲートの赤経路 | whitelist から vim の行（9 件）を除いた複製で `scan` → 表に 9 件出て終了コード 1、対応 2 択の案内 |
| whitelist が無いときの `scan` | `baseline` で作るよう案内して終了コード 1（`baseline` はヘッダだけの新規作成から通る） |
| sbomnix が PATH に無いとき | `nix shell --inputs-from <flake> nixpkgs#sbomnix` で自動で入り直して続行（印で再入は 1 回だけ） |
| CPE 誤マッチの確認 | OSV API で CVE-2021-21684 / CVE-2022-30947 / 36882 / 36883 / 36884 / 38663 = Jenkins Git Plugin、CVE-2023-6992 = Cloudflare fork 版 zlib。NVD API で CVE-2007-1397 = IRC 暗号化プラグイン FiSH。いずれも閉包の git / zlib / fish 本体ではない |

### pin↔先端の差分

| 確認 | 結果 |
| --- | --- |
| pin `104240a`（8/3 公開）↔ 先端 `391b592`（8/20 公開） | 10 パッケージの版差分（audit / fzf / glib / herdr / libgit2 / llhttp / mise / publicsuffix-list / python3 / tpm2-tss）。レポートは ANSI を剥いだ形で `head-diff.txt` へ。終了コード 0 |
| pin が先端と同じとき | 「pin はチャンネル先端と同じです」でビルドせず終了コード 0（先端へ lock した使い捨て flake で確認） |
| 差分が空のとき | pin `104240a` の hello 閉包 ↔ 先端で「版差分はありません」（store path は変わっても版が同じなら出ない、の実例でもある） |
| `--override-input` が lock を書かないこと | `nix build` 経由では "not writing modified lock file" の警告どおり書かれない（`--no-write-lock-file` も明示） |

### 静的検査

| 確認 | 結果 |
| --- | --- |
| `shfmt -d` / `shellcheck` | `nix/` 配下の `*.sh` 全 20 ファイル（新規 2 本を含む）で通過 |
| `nixfmt --check` | 通過（`flake.nix` は変更していない） |
| actionlint | 追加ジョブに指摘なし（既存 lint ジョブの意図的な single quote への SC2016 のみ） |

## 7. 移行・運用手順

日常運用は [`nix/README.md`](../../../nix/README.md#閉包のスキャンと-pin先端の差分-遅延の補完)
を参照。要点だけ。

```sh
# CI と同じスキャン (whitelist に無い findings があれば非ゼロ)
./nix/scripts/closure-scan.sh scan

# findings を意図して受け入れる (whitelist へ追記 → comment に理由 → commit)
./nix/scripts/closure-scan.sh baseline

# pin と先端で何が動くかを見る (pin 更新 PR は CI が summary に貼る)
./nix/scripts/closure-head-diff.sh
```

CI のゲート（`closure-scan` ジョブ）が落ちたら:

1. **pin を動かして直るか見る** — `flake-lock-age.sh resolve / update`。修正が
   下限日数より新しい側にしか無いなら、`--min-age-days` を下げて先端から入れる
   判断まで含む（ADR 005 の「遅延を外す」）
2. **意図して受け入れる** — `baseline` で追記し、comment に理由を書いて commit

whitelist の行は消してよい（該当パッケージが閉包から消えた・CVE が修正されたなど。
残っていても実害は無いが、基準線は小さいほど読める）。
