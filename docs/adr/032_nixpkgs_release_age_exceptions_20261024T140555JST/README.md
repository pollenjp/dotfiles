# ADR: nixpkgs の猶予の日数を設定値にし、期間付きの例外 (全体・一部 nixpkgs・一部 upstream) を nix/release-age.nix に持つ

| 項目 | 内容 |
| --- | --- |
| ステータス | 承認 (Accepted) — 方針は 2026-10-24 にユーザーが承認 (集約ハブの会話)。文面は PR でレビュー |
| 日付 | 2026-10-24 (JST) |
| 決定者 | pollenjp |
| 関連 ADR | [005_nix_flake_lock_min_release_age](../005_nix_flake_lock_min_release_age_20260813T184522JST/README.md)（flake.lock の 7 日。この ADR が日数を設定値にし、例外を足す）、[006_nix_closure_sbom_osv_scan](../006_nix_closure_sbom_osv_scan_20260823T004634JST/README.md)（閉包のスキャン。例外で入れた package もスキャンに乗る）、[030_mise_release_age_overrides](../030_mise_release_age_overrides_20261023T010148JST/README.md)（mise が入れるツールの遅延の上書き。こちらは mise 本体を含む nixpkgs の側） |
| 運用手順 | [`nix/README.md`「猶予の日数と例外」](../../../nix/README.md#猶予の日数と例外-release-agenix) |
| 設計 | [`docs/superpowers/specs/2026-10-24-nixpkgs-release-age-exceptions-design.md`](../../superpowers/specs/2026-10-24-nixpkgs-release-age-exceptions-design.md) |

---

## 1. 背景 (Context)

### やりたかったこと

2026-10 の eMudhra の中間 CA の侵害 (CVE-2026-111943) で、mise の修正版 2026.10.17 (2026-10-21 公開) を入れたくなった。
mise は nixpkgs から入れている (home-manager の `programs.mise`) が、nixpkgs の master・nixpkgs-unstable の mise は 2026.10.3 の
ままで、PR NixOS/nixpkgs#577218 (mise: 2026.10.3 -> 2026.10.17) は review を待っていた。nixpkgs が追いついても、
`flake-lock-age.sh` (ADR 005) は公開から 7 日たつまでその revision を選ばない。逃げ道は全体を先端へ上げる `--min-age-days 0` だけで、
CI の `lock-age` が赤くなる。ユーザーの言葉では次のとおり。

> nixpkg の一部だけはupstreamにしたいとかあるいは ミニマムリリースエイジの時みたくあのドットファイルズプライベート側に何日間は最新のものにするとかそこからは 何日以前のコミットにするみたいな 指定を入れたいな。nixpkg の commit hash をupdate する仕組みをこれを気に整えるってことかな。

> nixpkg 系は普段は7日前猶予を設定 (ここは minimum release age と同様に設定値で指定したい) し、最新の脆弱性チェックはCIで回す。
> ただし今回のようにセキュリティパッチが最新に近いやつに入ることもあると思う。そのとき
> - 全体を特定の日付のリリース時点に合わせる
> - 特定のpackageのみ特定の日付のリリース時点に合わせる (他は minimum release age 指定ど同じ時点のpkgs)

置き場所は dotfiles に寄せる案に「ok」、mise 2026.10.17 を release の build 済みの binary で足す案に「足す」と答えた。

### 前提

- `flake-lock-age.sh` は root の直下の input ごとに revision を選ぶ。nixpkgs は releases.nixos.org のチャンネルの公開時刻から
  (binary cache が揃っているため)、ほかの github input は commit 時刻から。CI の `lock-age` が `check` を流す (ADR 005)
- CI の `closure-scan` は home の閉包を PR・push と毎朝スキャンする (ADR 006)。脆弱性の確かめはこれに任せる
- home-manager の評価は pure で、今日の日付を読めない (ADR 030 の §2.C)
- mise を nixpkgs の外から取る手: `overrideAttrs` で版と `cargoHash` を替えると、pin の nixpkgs の `buildRustPackage` が元の引数の
  `cargoHash` を読むので落ちる。jdx/mise の flake (tag) は使えるが binary cache が無く PC ごとに build になる。release の静的リンクの
  musl 版を `fetchurl` と sha256 で固定すれば build は要らない

## 2. 決定 (Decision)

### A. 日数と例外は `nix/release-age.nix` の 1 か所に置く

| 欄 | 中身 |
| --- | --- |
| `minimumReleaseAgeDays` | 普段の猶予 (日)。既定 7 |
| `exceptions.all` | 1. 全体。項目は `date`・`reason` |
| `exceptions.fromNixpkgs` | 2. 一部 (nixpkgs から)。項目は `packages` (top-level の名前の list)・`date`・`reason` |
| `exceptions.fromUpstream` | 3. 一部 (upstream から)。項目は `package`・`version`・`reason`。中身は `nix/pkgs/upstream/<package>.nix` |

- 型と必須の欄は `nix/lib/release-age.nix` が `lib.evalModules` で確かめる。知らない欄・暦に無い日付・空の `reason`・負の日数・
  入れ子の名前・pkgs に無い名前・同じ package を 2 回・upstream のファイルが無い・その版と `version` が違う、は評価で止まる
- 例外は dotfiles 全体 (登録した全 PC と CI) に効く。ホストごとの例外は作らない (`flake.lock` は全 PC で共有している)
- 暦の日付の型は `nix/lib/calendar-date.nix` に出し、`dotfiles.mise.releaseAgeOverrides` (ADR 030) と共用する

### B. 日付は「この日 (Asia/Tokyo) の終わりまでの公開を使う」と読む

その日の 23:59:59 +09:00 (= 14:59:59 UTC) までの公開を使う。ADR 030 の上書きと同じく Asia/Tokyo の日で読む。

### C. 全体の例外は flake-lock-age.sh が pin を動かし、check が通す

- `update`・`resolve`: `date` の日の終わりが猶予 (今 − N 日) より新しければ、nixpkgs (nixpkgs-unstable を追う input。
  `nixpkgs-exceptions` を除く) をその日の終わりまでの最新の公開から選ぶ。今より先へは上げない。ほかの github input は猶予のまま
- `check`: 猶予を満たさない pin も、`lastModified` がその日の終わりまでなら「OK (例外 (全体) <date>)」で通す。CI の `lock-age` も
  同じ設定を読むので、承認した例外で赤くならない

### D. 一部 (nixpkgs から) の pin は flake の input `nixpkgs-exceptions`

- `nix/flake.nix` に nixpkgs-unstable を追う input として足す。pin は `flake-lock-age.sh` が決める: 項目の最も新しい `date` の日の
  終わりまでの最新の公開が、普段の pin (`nixpkgs`) より新しければそれ、そうでなければ `nixpkgs` と同じ revision。項目が複数でも
  pin は 1 本にまとめる
- 同じ revision なら取り直すものは無い。`lib/release-age.nix` も、消し時を過ぎていない項目があるときだけこの input を読む
- `check` は、その日の終わりまでの pin と、`nixpkgs` と同じ revision を通す
- 足した日には `flake-lock-age.sh update --input nixpkgs-exceptions` で、`nixpkgs` と同じ revision で lock に足した
  (`nixpkgs`・`home-manager` の pin は動かしていない)

### E. 一部の例外は home の pkgs の overlay で当て、ほかの package から使われないアプリに限る

- `lib/release-age.nix` が system ごとに overlay を作り、`lib/mk-home.nix` が home の pkgs に `appendOverlays` で当てる。効いている
  項目が無ければ素の `legacyPackages` のまま (普段の評価を変えない)
- overlay なので `programs.<名前>` や `home.packages` を書き換えずに差し替わる (mise なら `programs.mise` の既定の package)
- 使えるのは top-level の名前 (`pkgs.<名前>`) で、ほかの package から使われないアプリだけ。ライブラリ (openssl・nss・cacert・
  `python3Packages.certifi` など) を差し替えると、依存側が組み直されて binary cache が外れ、新旧の pin の版が混ざる。これは全体で扱う
- flake の check (`release-age-state`) が、例外を当てた home と当てない home の `home.packages` を同じ添字で比べ、差し替えた名前で
  ない package の drvPath が変わっていれば (差し替えたものを使っていれば)、その名前を出して落ちる

### F. 消し時は pin の日時と package の版で決め、home-manager の warnings に出す

| 例外 | 何もしなくなる (消し時) |
| --- | --- |
| 全体・一部 (nixpkgs から) | 普段の pin (`nixpkgs`) の commit の日時 (`lastModifiedDate`) が、`date` の日の終わりを越えた |
| 一部 (upstream から) | 普段の pin の nixpkgs のその package の版が、`version` 以上になった |

- 今日の日付は読まない (home-manager の評価は今日の日付を読めない)。pin が動くまでは消し時にならず、`date` + 猶予の日数のあとの
  `update` で pin が `date` を越えたときに出る
- ほかに、一部 (nixpkgs から) で `nixpkgs-exceptions` が普段の pin より新しくないあいだは「まだ何もしていない」、一部 (upstream から)
  でその system の配布物が無いときは「nixpkgs のまま」を出す
- 文は「nixpkgs の例外」で始める。setup は今までどおり switch の後に警告のまとめへ写す (`hm_warnings_to_summary`)。CI の `check`
  ジョブの「warnings が空」は、この文だけは落とさず `::warning::` の annotation にする。何もしなくなった例外に害は無く、消すのは PR

### G. 最初の例外: mise 2026.10.17 を release の build 済みの binary で入れる

- `exceptions.fromUpstream` に `mise` 2026.10.17。理由は CVE-2026-111943 の修正版であることと、nixpkgs#577218 を待つ間の一時しのぎ
- `nix/pkgs/upstream/mise.nix`: release の tar.xz (`linux-x64-musl`・`linux-arm64-musl`・`macos-arm64`) と補完 (`mise.bash`・
  `mise.fish`・`mise.zsh`) を、GitHub が asset ごとに出す digest で固定する (tar.xz の digest は release の `SHASUMS256.txt` とも同じ)。
  nixpkgs の mise と同じく `bin/mise`・man・補完・`lib/mise/.disable-self-update` を置き、install の後に `mise --version` を見る。
  tar.xz の fish の `vendor_conf.d/mise-activate.fish` は入れない (activate は `programs.mise` がする)

### H. flake-lock-age.sh の口

- 設定は `--config FILE` か、script の隣の `../release-age.nix`。`nix run` で他の repo から呼んだときは、今までどおり 7 日で例外なし
- 日数は `--min-age-days` > `FLAKE_MIN_RELEASE_AGE_DAYS` > 設定 > 7 (どれが効いたかを見出しの行に出す)
- `--input NAME` で、その input だけを選ぶ。lock に無い input は flake.nix から読み、先端を掴まない
- 日付の日の終わりは bash の算術で UNIX 秒にする (GNU と BSD の date の違いに寄らない)。今の時刻は `FLAKE_LOCK_AGE_NOW` で差し替えられる

## 3. 変更点の詳細

| ファイル | 変更 |
| --- | --- |
| `nix/release-age.nix` | 新規。日数と例外の設定。最初の例外 mise 2026.10.17 |
| `nix/lib/release-age.nix` | 新規。設定の検証、system ごとの overlay と消し時の警告 |
| `nix/lib/calendar-date.nix` | 新規。`home/options.nix` から暦の日付の型を出した |
| `nix/lib/mk-home.nix` | overlay を home の pkgs に当て、警告を warnings に出す |
| `nix/pkgs/upstream/mise.nix` | 新規。mise 2026.10.17 の release の binary |
| `nix/flake.nix`・`nix/flake.lock` | input `nixpkgs-exceptions`。checks に `release-age-state`・`flake-lock-age-test` |
| `nix/scripts/flake-lock-age.sh` | 設定の日数・全体と一部 (nixpkgs から) の例外・`--config`・`--input`・lock に無い input |
| `nix/tests/` | `release-age.nix` (fixtures/release-age)・`flake-lock-age.test.sh` |
| `.github/workflows/nix.yml` | 「warnings が空」で例外の警告を annotation にする。`min_release_age_days` の説明 |
| `nix/README.md` ほか | 「猶予の日数と例外」の節。setup の help・`pjp-dotfiles-update` skill・ADR 001 の textbook の日数の書き方 |
| ADR 005・006 | 冒頭の表にこの ADR へのポインタ。006 の運用手順に例外を足した |

## 4. 検討した代替案

| 案 | 採らなかった理由 |
| --- | --- |
| 例外を dotfiles-private に置き、ホストごとに変えられるようにする | `flake.lock` は全 PC で共有しているので、ホストごとの pin と合わない。ユーザーも dotfiles に寄せる案を選んだ |
| `--min-age-days 0` で全体を先端へ上げるだけ | 1 つの修正のために全部を先端へ上げ、CI の `lock-age` も赤くなる |
| 一部 (nixpkgs から) の pin を rev と narHash の data で持ち、`builtins.fetchTree` で取る | lock と CI の `lock-age` の仕組みの外に出て、script が data を書き換える口が増える |
| 消し時を `flake-lock-age.sh` や setup が今日の日付で決める | home の評価 (overlay を当てるか) は今日の日付を読めないので、判定がずれる。pin の日時と版なら両方で同じに決まる |
| 消し時に CI を落とす | 何もしなくなった例外に害は無い。消すのは PR で、そのあいだ CI を赤くする理由が無い |
| 一部の例外を `programs.<名前>.package` や `home.packages` の書き換えで当てる | package ごとに当てる場所を探すことになる。overlay なら既定の package がそのまま差し替わる |
| 一部の例外をライブラリにも許す | 依存側が組み直されて binary cache が外れ、新旧の pin の版が混ざる。全体の例外で扱う |
| 項目ごとに一部の例外の pin を持つ | nixpkgs を何本も取ってくることになる。最も新しい日付の 1 本にまとめる |
| mise を `overrideAttrs` で版と `cargoHash` を替える | pin の nixpkgs の `buildRustPackage` が元の引数の `cargoHash` を読むので落ちる |
| mise を jdx/mise の flake (tag v2026.10.17) から取る | binary cache が無く、PC ごとに build が要る |

## 5. 影響 (Consequences)

### 良くなること

- セキュリティパッチのために、全体・一部の package だけを日付で区切って新しくできる。CI の `lock-age` も通る
- 例外は理由とともに 1 か所に残り、要らなくなれば何もしなくなって、setup の警告のまとめと CI の annotation が消し時を知らせる
- 例外で入れた package も、CI の `closure-scan` (home の閉包) に乗る
- 普段 (効いている一部の例外が無いとき) の評価と取ってくるものは変わらない

### 注意が必要なこと

- 一部の例外の確かめ (`release-age-state`) が比べるのは `home.packages` だけ。systemd の unit や home-manager が書く設定ファイルが
  差し替えた package を参照していても見ない (mise では、`pjp-mise-prune` や shell の activate が新しい mise を使うのが望む形)
- upstream から取った package には、nixpkgs の build がしていること (テスト・パスの差し替え) が無い。mise なら、nixpkgs の版は
  `git`・`bash`・`env`・`direnv` を store のパスに差し替えているが、release の binary は PATH から探す (公式の installer で入れたときと
  同じ)。補完の `usage` は 2026.10.17 では要らない
- 消し時の判定に使う `lastModifiedDate` は commit の日時で、公開の日時より古い側に出る。公開で選ぶ `update` より、消し時を言うのは
  少し遅れる (早めに言うことは無い)
- `flake.lock` に input が 1 つ増える。ローカル flake の lock は setup が今までどおり張り直す (`sync_local_flake_lock`)
- `flake-lock-age.sh` は設定を読むために `nix eval` を 1 回多く呼ぶ (設定が無ければ呼ばない)

## 6. 検証 (Verification)

- `nix/tests/release-age.nix` (`release-age-state`): 偽の inputs と偽の upstream の package で、日の境目 (14:59:59 UTC と 15:00:00 UTC)・
  3 種類の効き方と消し時・`nixpkgs-exceptions` を読まないこと・書き誤り。実の設定で mise が home の pkgs で差し替わり、
  `home.packages` のほかの package が使っていないこと
- `nix/tests/flake-lock-age.test.sh` (`flake-lock-age-test`): 偽の curl (公開と commit の表) と nix の包みで、日数の優先・全体の例外
  (境目を含む)・`nixpkgs-exceptions` の選び方・`--input`・lock に無い input・`check` の通し方
- `nix flake check ./nix` (x86_64-linux の build) と `nix flake check --all-systems --no-build ./nix`
- sandbox の home を build し、`home-path/bin/mise --version` が `2026.10.17`、補完 (bash・fish・zsh)・man・
  `.disable-self-update` が並び、`.bashrc` と fish の設定の activate が新しい mise を指すことを見た
- `closure-scan.sh scan` (CI と同じ) を流した
- CI の「warnings が空」の中身を、`nixpkgs の例外` の文とほかの文を混ぜた JSON・例外の文だけ・空で流し、混ぜたものだけ落ちることを見た

## 7. 移行・運用手順

例外を足す・消す手順は [`nix/README.md`「猶予の日数と例外」](../../../nix/README.md#猶予の日数と例外-release-agenix)。要点だけ。

```sh
# 全体: nix/release-age.nix の exceptions.all に { date; reason; } を足して
./nix/scripts/flake-lock-age.sh update

# 一部 (nixpkgs から): exceptions.fromNixpkgs に { packages; date; reason; } を足して (普段の pin は動かさない)
./nix/scripts/flake-lock-age.sh update --input nixpkgs-exceptions

# 一部 (upstream から): nix/pkgs/upstream/<package>.nix を書き、exceptions.fromUpstream に { package; version; reason; } を足す
#   (flake.lock は変わらない)

# 今の pin が通るか (CI の lock-age と同じ)
./nix/scripts/flake-lock-age.sh check ./nix ./nix/files/claude/skills/pjp-d3js \
  ./nix/files/claude/skills/pjp-drawio ./nix/files/claude/skills/pjp-plantuml
```

merge の後、各 PC で `~/dotfiles/setup --self-update --update` (mise 2026.10.17 が入る)。消し時は setup の警告のまとめ
(`nixpkgs の例外 …`) と CI の annotation に出るので、PR で項目を消す (upstream なら `nix/pkgs/upstream/<package>.nix` も)。
