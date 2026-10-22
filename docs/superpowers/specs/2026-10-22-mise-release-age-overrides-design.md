# mise の遅延 (minimum_release_age) を期間付きで緩める — 設計 (TKT-323)

- チケット: [TKT-323](https://app.notion.com/p/mise-minimum_release_age-option-list-TKT-320-40179149a66f81e29005ed26cc2fed48)
  (集約ハブの会話は [TKT-320](https://app.notion.com/p/dotfiles-minimum-release-age-flake-dotfiles-private-40179149a66f81ce9b20f8443aeaf1b7))
- 方針は 2026-10-22 にユーザーが承認した (集約ハブの会話 TKT-320)。この文書はその書き写しと、実装で決めた細部
  (最後の「実装で決めた細部」)
- dotfiles-private の最初の項目 (`nix/shared/mise-release-age.nix`) と README は、同じ日に dotfiles-private の PR で足す
  (この PR の option と privateHosts の読み方に従う)

## 何のためか

- setup (`nix/scripts/bootstrap-mise.sh`) は `--update` のたびに `mise settings set minimum_release_age 9d` を書く。
  脆弱性の修正版をすぐ入れたいとき、手で `mise settings set minimum_release_age 0d` としても、次の `--update` で 9d に戻る。
- ユーザーが望むのは、期間中は **mise の設定そのもの** を緩めておき、別の repo の `mise install`・`mise up` でも
  新しい版を取り続けること (ユーザーに確認済み)。
- 入れた版が戻るのではない: mise0 (`MISE_MINIMUM_RELEASE_AGE=0d mise`) で入れた uv 0.13.5 は、9d のまま
  `mise use -g` / `mise install` / `mise up` を打っても 0.13.0 に戻らなかった (隔離した mise 2026.8.6 で実測)。
- 上書きは dotfiles-private に list で持ち、期限が来たら自動で既定に戻る。期限が過ぎた項目は、どこかで list から消す。

ユーザーの依頼 (原文):

> ~/dotfiles/setup でいれるやつで minimum release age 的なやつを指定するものがあると思うけど、あれを flake.nix 系から指定できるようにしたい。
> 脆弱性が発見されたばかりで たとえば  mise とかは mise0 を使ったものを install して使いたい。
> しかし、  `~/dotfiles/setup --update` するたびに戻るのは嫌だ。
>
> ただ、また一方で、この制約を7日後には解消してほしい要求もある。
> 今回の設定は dotfiles-private 側に入れると思うが、特定の日付の期間なら上書きをする設定をlistで保持しておけるような形が嬉しいかもしれない。
> 指定期間をすぎたらいらなくなるのでどこかのタイミングでその項目を list かなにかから削除する感じになると思うが。

> 7日間0dayはやはりなんか変だな。たとえば7日間の間は今日この日のバージョンになるようにするなどがよい。つまり今日は 0day だが明日実行したら遅延は1day、明後日は2day、....としていき、デフォ minimum release age (今回は9day) まではこの感じでやる。それ以降は override 無しのときと同じ。

> 遅延0dayの期間を 3日間設けるなども設定できたらいいな。

## 振る舞い (ユーザーが決めたこと)

- 上書きの項目は「この日の版まで取る」日付で持つ。「7 日間ずっと 0d」はしない (ユーザー: 「7日間0dayはやはりなんか変」)。
- 上書きを始めた日 (from) は 0d。翌日は 1d、翌々日は 2d …と、取る版の上限を from の日に固定したまま遅延が伸び、
  既定 (9d) に追いついたら、上書きが無いときと同じに戻る。
- 0d を続ける日数 `zeroDays` も指定できる (ユーザー: 「遅延0dayの期間を 3日間設けるなども設定できたらいい」)。
  zeroDays = 3 なら from から 3 日 (from の日を含む) は 0d、その次の日から 1d、2d …と伸びる。
- 上限の日 = from + zeroDays − 1 の日 (その日の終わりまでに出た版を取る)。
- 上書きは mise 全体に効かせる (tool ごとにはしない)。

例 (既定 9d):

| 日 | zeroDays = 1 | zeroDays = 3 |
| --- | --- | --- |
| 10/22 (from) | 0d | 0d |
| 10/24 | 約 2d | 0d |
| 10/27 | 約 5d | 約 3d |
| 10/31 の終わり | 上書きが終わる | 約 7d |
| 11/2 の終わり | | 上書きが終わる |

## 仕組み

### mise の性質 (実測。mise 2026.8.6)

- `minimum_release_age` は絶対日付・日時を受け付ける。`mise settings set minimum_release_age 2026-10-22` で、その日の
  01:35 UTC に出た uv 0.13.5 も取った (日付だけならその日を含む)。`2026-10-22T09:00:00+09:00` (= 00:00 UTC) なら 0.13.4 まで。
- 未来の日付 (`2026-10-24`) を入れると、その日までは 0d と同じに新しい版を取った (`mise up --dry-run` も新しい版を入れると出た)。
- よって、写す値は「取る版の上限の日時」1 つで済み、0d の期間も伸びていく遅延も mise 自身が守る。
- `~/.config/mise/conf.d/*.toml` の `[settings] minimum_release_age` は `config.toml` の値に負ける。だから
  `config.toml` に書く (このキーは今も bootstrap-mise.sh が持っている)。
- `MISE_MINIMUM_RELEASE_AGE` 環境変数にも絶対日付を渡せる。

### option (dotfiles の `nix/home/options.nix`)

- `dotfiles.mise.minimumReleaseAge`: 既定 `"9d"`。今 bootstrap-mise.sh に直書きしている値を option にする。
- `dotfiles.mise.releaseAgeOverrides`: list。各項目:
  - `from` (必須, `YYYY-MM-DD`): 上書きを始める日
  - `zeroDays` (省略時 1, 1 以上の整数): 0d を続ける日数 (from の日を含む)
  - `reason` (省略時 ""): setup の出力と警告に出す理由
- 書式 (`YYYY-MM-DD`・zeroDays ≥ 1) は Nix の評価で検める (今日の日付は使わない)。

### 値の受け渡し

- home-manager が `~/.local/state/dotfiles/mise-release-age.json` に option の値を置く
  (`git-via-gh.json` などと同じ今ある形)。home-manager の評価は pure なので今日の日付を読めず、終わったかどうかは
  Nix の中では判定できない。判定は実行時にする。

### 写す (bootstrap-mise.sh)

- `mise settings set minimum_release_age 9d` の直書きを、JSON から決めた値を書く形に替える。
- 各項目の上限 = (from + zeroDays − 1) の日の終わり。日付は Asia/Tokyo で読む (時刻帯が UTC のマシン
  (dev-3shake の VM) でも同じ日に切り替わるように)。mise へは時刻帯付きの日時で渡す (例: `2026-10-24T23:59:59+09:00`)。
- from が今日 (Asia/Tokyo) より先の項目は写さない。
- 上限 + 既定 (minimumReleaseAge) を過ぎた項目は「終わった」項目で、写さない。
- 残った項目のうち上限がいちばん新しいものを `minimum_release_age` に書く。残りが無ければ既定を書く。
- 既定の書式は mise の duration (`9d` など)。上限 + 既定の計算に要る範囲で読めればよい (少なくとも日の単位 `d`)。
- 写す script を timer で毎日流すことはしない。写さない日が続いても mise には上限の日時が残り、ずれるのは
  「新しい版を取らない」側だけで、守りは緩まない。次の `setup --update` で既定に戻る。
- 上書きのあいだは、setup の出力に「上書き中 (理由・上限・終わる日)。mise up で新しい版を入れられる」と 1 行出す。
  setup はほかの tool を勝手に upgrade しない。
- claude の行 (`MISE_MINIMUM_RELEASE_AGE=1d mise use -g claude@latest`) は、上書きの上限の方が新しい版を取るあいだは、
  上書きの上限を使う (env に上限の日時を渡す)。
- 対話シェルの `mise0` / `mise1` などの alias / abbr は変えない。

### 警告 (setup の警告のまとめ)

- 終わった項目が list に残っていれば、項目ごとに (from・zeroDays・reason・終わった日) を出し、
  定義した場所 (dotfiles-private の `nix/shared/` かホストのファイル) から消すよう促す。
- 終わった項目は写さないので、消し忘れても害は無い。

### list を置く場所 (dotfiles-private)

- 脆弱性への対応は登録した全 PC に効かせたいので、dotfiles-private の `nix/shared/*.nix` (home-manager の module) を、
  登録した全ホスト (`nix/hosts/*.nix`) に足す。dotfiles の `nix/lib/private-hosts.nix` (`privateHosts`) を広げる
  (各ホストへ渡す `mkHome` を包み、`modules` に shared の module を足す、など)。
- `nix/shared/` が無い clone・本体の空の stub (`nix/private-stub`) でも評価が通ること。
- 1 台だけに効かせたいときは、そのホストのファイルの `modules` に同じ option を書く (list はつながる)。
- 最初の項目 (dotfiles-private の `nix/shared/mise-release-age.nix`):
  `{ from = "2026-10-22"; zeroDays = 3; reason = "<脆弱性の修正版を入れる>"; }` (mise 全体。ユーザーが選んだ)。

## やらないこと

- flake.lock の 7 日 (`DOTFILES_MIN_RELEASE_AGE_DAYS`): public の本体の lock を全 PC で共有するので、PC ごとの上書きとは
  合わない。1 回だけ外すなら今の環境変数で足りる。
- tool ごとの上書き: conf.d の `minimum_release_age_excludes` は tool ごとに効く (実測) が 0d にしかできず、日付に固定する
  形と揃わない。要るようになったら別の会話で足す。
- 終わった項目を自動で list から消すこと: list は dotfiles-private の Nix のファイルなので、消すのは PR にする。
- 毎日の timer (上の「写す」)。

## 指揮役が決めたこと

- 日付は Asia/Tokyo で読む。
- setup はほかの tool を勝手に upgrade しない (1 行の案内だけ)。
- claude の 1d より上書きの方が新しい版を取るあいだは、claude にも上書きの上限を使う。
- timer をやめた (ずれるのは安全な側だけのため)。

## 実装で決めた細部

承認のあとに、実装する側 (TKT-323) で決めたこと。振る舞いは上のとおりで、ここは形の細部。

- 状態ファイルの形: `{"minimumReleaseAge": "9d", "releaseAgeOverrides": [{"from": "2026-10-22", "zeroDays": 3, "reason": "…"}]}`。
  option の名前のまま。項目は既定を埋めた 3 つの欄だけを書く (module の `nix/home/modules/mise-release-age.nix`)
- `minimumReleaseAge` は日の単位 `d` だけを受け付ける (`[0-9]+d`)。上限 + 既定を日で数えられ、`w`・`mo` の長さで迷わない
- `from` は形 (`YYYY-MM-DD`) だけでなく、暦にある日か (`2026-02-30` を通さない) も評価で検める。bootstrap の jq は
  無い日を黙って翌月へ繰り越すため
- 日の数え方: Asia/Tokyo は夏時間が無いので、今の UNIX 秒に 9 時間を足して日に割る (tzdata の無い環境でも同じ日になる)。
  判定はすべて日付どうしで比べる。from の日 ≤ 今日 ≤ 上限の日 + 既定の日数 のあいだを「上書き中」とする
- claude は、上限が「今 − min(1d, 既定)」より新しいあいだ (今日 ≤ 上限の日 + min(1, 既定の日数)) だけ上限を使う。
  既定が 0d なら claude も 0d (claude だけ遅延を縮める、の向きを保つ)
- 状態ファイルが無い・形が違う・jq が無いときは、警告して既定と同じ `9d` を書く (守りを緩めない側に倒し、setup は止めない)
- まだ始まっていない項目は、警告ではなく 1 行の案内にする
- テストは今の時刻を `BOOTSTRAP_MISE_NOW` (UNIX 秒) で差し替える (`bootstrap-windows-ssh-config.sh` の
  `BOOTSTRAP_SSH_CHECK_TIMEOUT` と同じ名前の付け方)
- `nix/shared/` から拾うファイルは `nix/hosts/` と同じ決まり (`.nix` で終わり、`.` で始まらない、ディレクトリでない)。
  名前の順に、ホストのファイルの `modules` より前に足す (list は shared の項目が先)
- 一覧の写し (`nix/README.md` の「足したホストに書く値」の表) には足さない (登録した PC は `nix/shared/` に書き、
  足したホスト (`tmp`) は `modules` に書けばよいので、mise の節に書く)
