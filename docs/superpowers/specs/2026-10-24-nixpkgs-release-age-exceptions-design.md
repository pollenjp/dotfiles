# nixpkgs の猶予と例外 (設計)

- 日付: 2026-10-24
- 出どころ: 集約ハブの会話でユーザーが承認した設計の書き写し。最後の「実装で決めた細部」は、実装で決めたこと
- 決定の記録は ADR 032

## なぜ

- 2026-10 の eMudhra の中間 CA の侵害 (CVE-2026-111943) で、mise の修正版 2026.10.17 (2026-10-21 公開) を入れたくなった。
  - nixpkgs の master・nixpkgs-unstable の mise は 2026.10.3 のままで、PR NixOS/nixpkgs#577218 (mise: 2026.10.3 -> 2026.10.17) は review 待ち。
  - nixpkgs が追いついても、flake-lock-age は公開から 7 日たつまで、その revision を選ばない。
  - 今の逃げ道は全体を先端へ上げる `--min-age-days 0` だけで、CI の lock-age が赤くなる (nix/README.md「遅延を外す」)。
- mise のツールには、期間付きで遅延を緩める口がすでにある (ADR 030。dotfiles.mise.releaseAgeOverrides)。nix の側にも、同じ考えの口を作る。

ユーザーの依頼 (原文):

> このPCのmiseも挙げないとじゃない？ nix が未対応？

> nixpkg の一部だけはupstreamにしたいとかあるいは ミニマムリリースエイジの時みたくあのドットファイルズプライベート側に何日間は最新のものにするとかそこからは 何日以前のコミットにするみたいな 指定を入れたいな。nixpkg の commit hash をupdate する仕組みをこれを気に整えるってことかな。

> nixpkg 系は普段は7日前猶予を設定 (ここは minimum release age と同様に設定値で指定したい) し、最新の脆弱性チェックはCIで回す。
> ただし今回のようにセキュリティパッチが最新に近いやつに入ることもあると思う。そのとき
> - 全体を特定の日付のリリース時点に合わせる
> - 特定のpackageのみ特定の日付のリリース時点に合わせる (他は minimum release age 指定ど同じ時点のpkgs)

置き場所の問い (例外も N も dotfiles に寄せる案) への答えは「ok」、最初の例外として mise 2026.10.17 を release の build 済みの
binary で足すか (公開 3 日で、7 日の猶予を外す) への答えは「足す」。

## ゴール

- 普段は、nixpkgs (と flake の github input) を、チャンネルの公開から N 日たった revision に pin する。N は設定値で持つ。
- セキュリティパッチが新しい revision にしか無いとき、理由を書いた例外で、次のどれかを選べる。
  1. 全体: nixpkgs 全体の pin を、日付 D までの公開にする
  2. 一部 (nixpkgs から): 指定した package だけを、日付 D までの公開の nixpkgs から取る。ほかは普段の pin のまま
  3. 一部 (upstream から): 指定した package だけを upstream から取る (nixpkgs のどの公開にも修正版がまだ無いとき)
- 例外は、要らなくなったら何もしなくなり、消し時を警告で知らせる。黙って残り続けない。
- 最初の例外として、mise 2026.10.17 を upstream の release の build 済みの binary で入れる。

## ゴールでないこと

- ホストごとに違う例外 (dotfiles-private に置く口) は作らない。例外は dotfiles 全体に効く。
- 例外を自動で登録しない (要るかは CI の closure-scan と人が決める)。
- mise のツールの遅延の口 (ADR 030。dotfiles-private の nix/shared/mise-release-age.nix) は変えない。
- nixos-config など、dotfiles の外の flake は対象にしない。

## やってはいけないこと (これになったら失敗)

- 例外が、消し時の警告も無く残り続ける。
- 承認済みの例外のせいで、CI (lock-age) が赤くなる。
- 例外が無いとき (普段) に、nixpkgs をもう 1 本取ってくるなど、普段の道が重くなる。
- review も Hydra も通っていない fork の commit から取る。

## ユーザーが決めたこと

1. 普段は N 日の猶予で選び、N は mise の minimumReleaseAge と同じく設定値で持つ (既定 7)。
   - flake-lock-age の update・check と、CI の lock-age が同じ値を読む。
   - 今の `--min-age-days` と環境変数 `FLAKE_MIN_RELEASE_AGE_DAYS` は、その場だけの上書きとして残す。
2. 脆弱性の確かめは CI で回す (今の closure-scan。毎朝 6:00 の定期実行と PR・push)。
3. 例外は上の 3 つの取り方。
4. 設定 (N) と例外の list は、dotfiles の 1 か所に置く。
   - 全体の例外は dotfiles の nix/flake.lock を動かすので、CI の lock-age も同じ設定を読んで、例外の分だけ新しい pin を通す。
   - 例外で入れた package も CI の closure-scan に乗る。
5. 最初の例外として mise 2026.10.17 を入れ、7 日の猶予を外す (公開から 3 日)。取り方は release の build 済みの binary。

## 設計で決めたこと (実装で直してよい)

- 日付の例外は「この日付までの公開を使う」という下限として持つ。
  - 日付は Asia/Tokyo の日の終わりで読む (ADR 030 の上書きと同じ)。
  - 普段の pin が D を越えたら (おおよそ D + N 日のあと)、例外は何もしなくなる。
- upstream の例外は、普段の pin の nixpkgs のその package の版が、例外の版以上になったら何もしなくなる。
- 何もしなくなった例外は、setup と CI が警告で知らせる。CI は落とさない。
  - 判定は、なるべく pure な評価で決められる形にする (今日の日付ではなく、pin の日時と package の版で決まるため)。
    home-manager の評価は今日の日付を読めない (home/modules/mise-release-age.nix の冒頭)。
- 一部 (nixpkgs から) の例外用の nixpkgs の pin は、効いている項目の最も新しい日付で 1 本にまとめる。
  - 効いている項目が無いときは、普段の pin と同じ revision にして、取ってくるものを増やさない。
- mise は release の静的リンクの musl 版を使う (jdx/mise の flake を tag で取って build する案は採らない。binary cache が無く、PC ごとに build が要るため)。
- 一部の例外 (nixpkgs から・upstream から) は、pkgs の overlay で当てる。ただし、使えるのは「ほかの package から使われないアプリ」に限る。
  - overlay にすると、`programs.<名前>` や `home.packages` の側を書き換えずに済む (mise なら `programs.mise` の既定の package がそのまま差し替わる)。
  - 依存されるもの (openssl・nss・cacert・python3Packages.certifi のようなライブラリ) を一部の例外で差し替えると、依存側が組み直されて binary cache が外れ、新旧の pin の版が混ざる。これらは「全体」の例外で扱う。
  - 受けるのは top-level の attr (pkgs.<名前>) だけにする。入れ子の package set (python3Packages.x など) は受けない。
  - 決まりは README と例外の欄の説明に書く。評価や CI で「ほかに使われていないか」を確かめられる手があれば足す (例: 例外の前後で home の世代の閉包を比べ、変わった drv がその package とその依存だけかを見る)。

## 最初の例外: mise 2026.10.17

- 出どころ: https://github.com/jdx/mise/releases/tag/v2026.10.17
  - Linux: `mise-v2026.10.17-linux-x64-musl.tar.xz`・`mise-v2026.10.17-linux-arm64-musl.tar.xz` (静的リンクなので、Ubuntu でも NixOS でも patchelf なしで動く)
  - dotfiles が build する system に macOS があれば、その asset も使う。asset の無い system では、nixpkgs の mise のまま警告を出す。
- sha256 は GitHub が asset ごとに出す digest で固定する (`gh api repos/jdx/mise/releases/tags/v2026.10.17` の assets[].digest)。
- 中身は mise の公式の installer (mise.run) が入れるものと同じ配布物で、信頼の置き場所は jdx/mise の GitHub の release になる。
- nixpkgs の build がしていること (テスト・bash/fish/zsh の補完の同梱) は無くなる。補完を作れるなら作る。
- home-manager の `programs.mise` は既定の package (pkgs.mise) を使っているので、overlay で pkgs.mise を差し替えれば `programs.mise` の設定は変えずに済む見込み。
- 理由の欄には、CVE-2026-111943 の修正版であること・nixpkgs#577218 を待つ間の一時しのぎであることを書く。

## 今の作り (設計した時点の事実)

- nix/scripts/flake-lock-age.sh: root の直下の input ごとに revision を選ぶ。nixpkgs は releases.nixos.org のチャンネル (nixpkgs-unstable) の公開時刻から選び (binary cache が揃っているため)、ほかの github input は commit 時刻で選ぶ。`resolve`・`update`・`check`。既定 7 日。update は閉包のスキャン (closure-scan.sh) を差し込む。
- CI (.github/workflows/nix.yml): `lock-age` ジョブが `flake-lock-age.sh check` を流す (flake のディレクトリを列挙。足し忘れに注意と README にある)。`closure-scan` ジョブは PR・push と毎朝の定期実行。workflow_dispatch に `min_release_age_days` がある。
- setup (nix/scripts/setup.sh): `--flake-update` の手順で本体の flake.lock を上げる。ローカル flake (~/dotfiles/flake.nix。dotfiles と dotfiles-private を path の input で持つ) の lock も張り直す。
- ADR 030 と home/modules/mise-release-age.nix・nix/scripts/bootstrap-mise.sh: mise の遅延の上書き。終わった項目を setup の警告のまとめに出す形がある。

## 実装に任せたこと

- 設定のファイル名と欄の名前、flake-lock-age が設定を読む方法。
- 例外用の pin の持ち方 (flake の input にするか、rev と hash を持つ data にするか)。
- overlay をどこで当てるか。
- CI の job の直し方と、警告の出し方。
- 設計の文書の置き場所。
- README の書き足し (普段の設定・3 つの例外の書き方・消し時)。

## 実装で決めた細部

### 設定: `nix/release-age.nix`

- Nix の attrset 1 つ。欄は次のとおり。型と必須の欄は `nix/lib/release-age.nix` が `lib.evalModules` で確かめる
  (知らない欄・暦に無い日付・空の reason・負の日数は評価で止まる。CI の flake check も落ちる)。

  | 欄 | 中身 |
  | --- | --- |
  | `minimumReleaseAgeDays` | 普段の猶予 (日)。既定 7 |
  | `exceptions.all` | 1. 全体。項目は `date` (YYYY-MM-DD)・`reason` |
  | `exceptions.fromNixpkgs` | 2. 一部 (nixpkgs から)。項目は `packages` (top-level の attr の名前の list)・`date`・`reason` |
  | `exceptions.fromUpstream` | 3. 一部 (upstream から)。項目は `package`・`version`・`reason`。中身は `nix/pkgs/upstream/<package>.nix` |

- 暦にある日付の型は `nix/lib/calendar-date.nix` に出し、`dotfiles.mise.releaseAgeOverrides` の `from` と共用する。
- 一部の例外で同じ package を 2 回書く・pkgs に無い名前・入れ子の名前 (`.` を含む)・`nix/pkgs/upstream/<package>.nix` の版と
  `version` が違う、も評価で止める。

### 一部 (nixpkgs から) の pin: flake の input `nixpkgs-exceptions`

- `nix/flake.nix` に `nixpkgs-unstable` を追う input として足す。lock の narHash と CI の lock-age にそのまま乗る
  (rev と hash を持つ data にすると、script が data を書き換える口が増え、CI の仕組みの外に出る)。
- pin は flake-lock-age.sh が決める: 項目の最も新しい date までの最新の公開が、普段の pin (input `nixpkgs`) より新しければ
  それ、そうでなければ普段の pin と同じ rev。同じ rev なら取り直すものは無く、評価も効いている項目が無ければこの input を読まない。
- この PR では `flake-lock-age.sh update --input nixpkgs-exceptions` で lock に足し、普段の pin は動かしていない。

### 消し時の判定 (Nix の評価。pure)

| 例外 | 何もしなくなる (消し時) | ほかの警告 |
| --- | --- | --- |
| 全体 | 普段の pin の commit の日時 (`lastModifiedDate`。UTC) が、date の日 (Asia/Tokyo) の終わりを越えた | — |
| 一部 (nixpkgs から) | 同じ | 例外の pin が普段の pin より新しくないあいだは「まだ何もしていない」 |
| 一部 (upstream から) | 普段の pin の nixpkgs のその package の版が、version 以上になった | その system の配布物が無ければ nixpkgs のまま |

- commit の日時は公開の日時より古い側に出るので、公開で選ぶ update より判定は少し遅れる (消し時を早めに言うことは無い)。

### overlay と警告の出し方

- `nix/lib/release-age.nix` が system ごとに overlay と警告を作り、`nix/lib/mk-home.nix` が home の pkgs に `appendOverlays` で
  当てる。効いている項目が無ければ素の `legacyPackages` のまま (普段の評価は変わらない)。
- 警告は home-manager の `warnings` に、先頭が「nixpkgs の例外」の文で出す。setup は今までどおり switch の後に警告のまとめへ写す
  (`hm_warnings_to_summary`)。CI の check ジョブの「warnings が空」は、この文だけは落とさず `::warning::` の annotation にする。
- 一部の例外がほかの package から使われていないかは、flake の check (`release-age-state`) で、例外を当てた home と当てない home の
  `home.packages` の drvPath を比べて確かめる (差し替えた package のほかに変わったものがあれば落ちる)。

### flake-lock-age.sh

- 設定は `--config FILE` か、script の隣の `../release-age.nix` (dotfiles の checkout から打つとき)。nix run で他の repo から
  呼んだときは、今までどおり既定の 7 日だけ。
- 日数は `--min-age-days` > `FLAKE_MIN_RELEASE_AGE_DAYS` > 設定の `minimumReleaseAgeDays` > 7。
- update / resolve:
  - 全体の例外の date が普段の猶予より新しければ、nixpkgs (と、ほかの nixpkgs-unstable を追う input) の上限を date の日の終わりに上げる。
  - `nixpkgs-exceptions` を上の決まりで選ぶ。
  - `--input NAME` で、その input だけを選ぶ (くり返せる)。lock に無い input は flake.nix から読む (新しい input を足しても先端を掴まない)。
- check: 猶予を満たさない pin も、全体の例外の date の日の終わりまでの nixpkgs、一部の例外の date の日の終わりまでの
  `nixpkgs-exceptions`、普段の pin と同じ rev の `nixpkgs-exceptions` は通し、どの例外で通したかを pin の行に出す
  (`OK (例外 (全体) <date>)`)。例外の項目ごとの消し時は home の評価の警告が出す (script で同じ判定を持たない)。
  update / resolve は、選ぶときの項目ごとの状態 (効いている・何もしない) を出す。
- 今日 (Asia/Tokyo) より先の date は止める (打ち間違いで、その日まで猶予が外れたままになるため。check も update も)。
- `--input` を付けても、lock に無い github の input は一緒に選ぶ (nix flake update が lock に無い input を先端で足すため)。
- 日付の日の終わりは、bash の算術で日付から UNIX 秒にする (GNU と BSD の date の違いに寄らない)。今の時刻は `FLAKE_LOCK_AGE_NOW`
  (UNIX 秒) で差し替えられる (テスト用)。

### mise 2026.10.17 (`nix/pkgs/upstream/mise.nix`)

- release の tar.xz (Linux は musl 版、macOS は macos-arm64) と補完の asset (`mise.bash`・`mise.fish`・`mise.zsh`) を、GitHub の
  digest で固定する。2026.10.17 の補完は `mise __complete_word__` を直に呼ぶので、nixpkgs の版のような `usage` の差し替えは要らない。
- nixpkgs の mise と同じく `bin/mise`・man・bash/fish/zsh の補完・`lib/mise/.disable-self-update` を置く。tar.xz の
  `share/fish/vendor_conf.d/mise-activate.fish` は入れない (activate は home-manager の `programs.mise` がする。入れると 2 回になる)。
- install の後に `mise --version` を見る。strip も patchelf もしない (静的リンク。macOS の署名を崩さない)。
