# ADR: mise の遅延を option で決め、期間付きの上書きを dotfiles-private の nix/shared/ の list で持ち、上限の日時を setup が mise に写す

| 項目 | 内容 |
| --- | --- |
| ステータス | 承認 (Accepted) — 方針は 2026-10-22 にユーザーが承認 (集約ハブの会話 TKT-320)。文面は PR でレビュー |
| 日付 | 2026-10-23 (JST) |
| 決定者 | pollenjp |
| チケット | [TKT-323](https://app.notion.com/p/mise-minimum_release_age-option-list-TKT-320-40179149a66f81e29005ed26cc2fed48)（dotfiles 側）。dotfiles-private の最初の項目は TKT-324。集約は [TKT-320](https://app.notion.com/p/dotfiles-minimum-release-age-flake-dotfiles-private-40179149a66f81ce9b20f8443aeaf1b7) |
| 関連 ADR | [005_nix_flake_lock_min_release_age](../005_nix_flake_lock_min_release_age_20260813T184522JST/README.md)（flake.lock の 7 日。この ADR の対象外）、[026_dotfiles_private_hosts](../026_dotfiles_private_hosts_20261020T215857JST/README.md)（dotfiles-private の `nix/hosts/`。この ADR が `nix/shared/` を足す）、[023_claude_video_offer_host_option](../023_claude_video_offer_host_option_20261018T121637JST/README.md)（option の値を `~/.local/state/dotfiles/` の JSON に置き、script が読む形。この ADR も同じ形を使う） |
| 運用手順 | [`nix/README.md`「遅延 (minimum_release_age) を期間付きで緩める」](../../../nix/README.md#遅延-minimum_release_age-を期間付きで緩める) |
| 設計 | [`docs/superpowers/specs/2026-10-22-mise-release-age-overrides-design.md`](../../superpowers/specs/2026-10-22-mise-release-age-overrides-design.md) |

---

## 1. 背景 (Context)

### やりたかったこと

setup (`nix/scripts/bootstrap-mise.sh`) は `--update` のたびに `mise settings set minimum_release_age 9d` を書いていた。
出たばかりの版を掴まないための遅延だが、脆弱性の修正版はすぐ入れたい (2026-10 の eMudhra の中間 CA の侵害では、uv・go などの
修正版が出た日に入れたかった)。手で `mise settings set minimum_release_age 0d` としても、次の `--update` で 9d に戻る。
ユーザーの言葉では次のとおり。

> ~/dotfiles/setup でいれるやつで minimum release age 的なやつを指定するものがあると思うけど、あれを flake.nix 系から指定できるようにしたい。
> 脆弱性が発見されたばかりで たとえば  mise とかは mise0 を使ったものを install して使いたい。
> しかし、  `~/dotfiles/setup --update` するたびに戻るのは嫌だ。
>
> ただ、また一方で、この制約を7日後には解消してほしい要求もある。
> 今回の設定は dotfiles-private 側に入れると思うが、特定の日付の期間なら上書きをする設定をlistで保持しておけるような形が嬉しいかもしれない。
> 指定期間をすぎたらいらなくなるのでどこかのタイミングでその項目を list かなにかから削除する感じになると思うが。

> 7日間0dayはやはりなんか変だな。たとえば7日間の間は今日この日のバージョンになるようにするなどがよい。つまり今日は 0day だが明日実行したら遅延は1day、明後日は2day、....としていき、デフォ minimum release age (今回は9day) まではこの感じでやる。それ以降は override 無しのときと同じ。

> 遅延0dayの期間を 3日間設けるなども設定できたらいいな。

- 戻ってほしくないのは入れた版ではなく mise の設定の方。mise0 で入れた uv 0.13.5 は、9d のまま `mise use -g`・
  `mise install`・`mise up` を打っても 0.13.0 に戻らなかった (隔離した mise 2026.8.6 で実測)
- 期間中は、別の repo の `mise install`・`mise up` でも新しい版を取りたい (ユーザーに確認済み)。1 回だけなら mise0 で足りる
- 脆弱性への対応は、登録した全 PC に効かせたい

### mise の性質 (実測。mise 2026.8.6)

| 値 (`minimum_release_age` か `MISE_MINIMUM_RELEASE_AGE`) | `mise latest uv` |
| --- | --- |
| `9d` | 0.13.0 |
| `2026-10-22T09:00:00+09:00` (= 00:00 UTC) | 0.13.4 |
| `2026-10-22` (日付だけ。その日を含む)・`2026-10-22T23:59:59+09:00` | 0.13.5 |
| `2026-10-24T23:59:59+09:00` (未来) | 0.13.5 (その時までは 0d と同じ) |

- `~/.config/mise/conf.d/*.toml` の `[settings] minimum_release_age` は `config.toml` の値に負ける
- `mise settings set` は値を検めない (`not-a-date` もそのまま書く)

## 2. 決定 (Decision)

### A. 遅延と上書きを option にする

`home/options.nix` に足す。

| option | 既定 | 中身 |
| --- | --- | --- |
| `dotfiles.mise.minimumReleaseAge` | `"9d"` | 遅延。日の単位 (`[0-9]+d`) だけ (上書きが終わる日を日で数えるため) |
| `dotfiles.mise.releaseAgeOverrides` | `[ ]` | 上書きの list。項目は `from` (必須。暦にある `YYYY-MM-DD`。2026-02-30 などは評価で止める)・`zeroDays` (1 以上。既定 1)・`reason` (既定 `""`) |

### B. 上書きは「この日までに出た版を取る」上限で持つ

項目の上限 = from + zeroDays − 1 の日の終わり (`T23:59:59+09:00`)。その日までは遅延 0d と同じで、その後は上限を据え置いたまま
遅延が 1 日ずつ伸び、上限 + 既定を過ぎると上書きが無いときと同じに戻る。写す値は上限の日時 1 つで、伸びていく遅延は mise が守る。

| 日 (既定 9d) | `zeroDays = 1` | `zeroDays = 3` |
| --- | --- | --- |
| 10/22 (from) | 0d | 0d |
| 10/24 | 約 2d | 0d |
| 10/27 | 約 5d | 約 3d |
| 10/31 の終わり | 上書きが終わる | 約 7d |
| 11/2 の終わり | | 上書きが終わる |

### C. 始まり・終わりは setup が実行時に決める (Nix ではない)

home-manager は値を `~/.local/state/dotfiles/mise-release-age.json` に置くだけにする (評価は pure で今日の日付を読めない)。
`bootstrap-mise.sh` が `--update` のたびに今日 (Asia/Tokyo) と比べ、上書き中 (from の日 ≤ 今日 ≤ 上限の日 + 既定の日数) の項目の
うち上限がいちばん新しいものを書き、無ければ既定を書く。

- 今日は UNIX 秒に 9 時間を足して日に割る (夏時間の無い Asia/Tokyo。tzdata が無くても同じ日になる)。時刻帯が UTC のマシンでも
  同じ日に切り替わる
- 毎日の timer は置かない。流さない日が続いても mise には上限が残るだけで、ずれるのは新しい版を取らない側 (守りは緩まない)。
  次の `--update` で既定に戻る
- 上書きのあいだは 1 行で知らせる。入っている tool は上げない (新しい版は `mise up` で入れる)
- 状態ファイルが無い・形が違う・jq が無いときは、警告して 9d を書く。守りを緩めない側に倒し、setup は止めない
  (`bootstrap-mise.sh` は order 10 で先頭なので、止めると後ろの bootstrap が走らない)

### D. 終わった項目は写さず、setup の警告のまとめで消すよう促す

自動では消さない (list は dotfiles-private の Nix のファイルなので、消すのは PR)。写さないので、消し忘れても害は無い。

### E. dotfiles-private の `nix/shared/*.nix` を登録した全ホストに足す

`lib/private-hosts.nix` (`privateHosts`) が、各ホストのファイルに渡す `mkHome` を包み、`nix/shared/*.nix` (home-manager の module) を
`modules` の前に足す (ファイル名の順。拾い方は `hosts/` と同じ)。1 台だけならホストのファイルの `modules` に書く (list はつながる。
順は module system が決めるので、bootstrap は順に依らない)。`nix/shared/` が無い clone と本体の stub では何も足さない。
ローカル flake に足したホスト (`tmp`) と登録簿の型には足さない。

### F. claude も上限の方が新しいあいだは上限で入れる

`claude` は 1d (既定がそれより短ければ既定) に縮めて入れている。上書きの上限の方が新しい版を取るあいだ (上限の日の翌日まで) は、
上限で入れる。

## 3. 変更点の詳細

| ファイル | 変更 |
| --- | --- |
| `nix/home/options.nix` | `dotfiles.mise.*` と、暦にある日付の型 `calendarDate` |
| `nix/home/modules/mise-release-age.nix` | 状態ファイル `mise-release-age.json` を置く |
| `nix/scripts/bootstrap-mise.sh` | 状態ファイルと今の時刻から書く値を jq で決める。上書き中の 1 行・まだ始まっていない項目の 1 行・終わった項目の警告。テストは `BOOTSTRAP_MISE_NOW` で今を差し替える |
| `nix/lib/private-hosts.nix` | `nix/shared/*.nix` を全ホストの modules の前に足す |
| `nix/tests/` | `mise-release-age.nix`・`bootstrap-mise.test.sh`・`private-hosts.nix` (shared/ のケースと fixtures) |
| `nix/README.md` ほか | 「遅延 (minimum_release_age) を期間付きで緩める」の節、dotfiles-private の `nix/shared/` の読み方 |
| ADR 026 | 冒頭の表に、この ADR への後続 ADR の行を足した (§2.B の「素の mkHome で呼ぶ」に shared/ の module が加わる) |

dotfiles-private には、最初の項目 `nix/shared/mise-release-age.nix` (`{ from = "2026-10-22"; zeroDays = 3; … }`。mise 全体) を別の PR
(TKT-324) で足す。

## 4. 検討した代替案

| 案 | 採らなかった理由 |
| --- | --- |
| 期間中ずっと 0d (from と until を持つ) | ユーザー: 「7日間0dayはやはりなんか変」。取る版を日付に固定し、遅延が伸びる形にした |
| tool ごとの上書き (conf.d の `minimum_release_age_excludes`) | tool ごとに効く (実測) が 0d にしかできず、日付に固定する形と揃わない。要るようになったら別に足す |
| conf.d に `minimum_release_age` を書く | `config.toml` の値に負ける (実測) |
| 始まり・終わりを Nix の評価で決める | home-manager の評価は pure で、今日の日付を読めない |
| 毎日の timer で写し直す | 絶対日時を写せば mise が守る。流さない日のずれは新しい版を取らない側だけ |
| 終わった項目を自動で list から消す | list は dotfiles-private の Nix のファイル。消すのは PR |
| flake.lock の 7 日 (`DOTFILES_MIN_RELEASE_AGE_DAYS`) も上書きする | public の本体の lock を全 PC で共有するので、PC ごとの上書きと合わない。1 回だけ外すなら今の環境変数で足りる |
| 今日を `TZ=Asia/Tokyo date` で読む | tzdata が無いと黙って UTC になる |
| 読めない状態ファイルで `exit 1` する (`bootstrap-claude-env.sh` の形) | 先頭の手順なので、止めると後ろの bootstrap が走らない。9d を書けば守りは緩まない |

## 5. 影響 (Consequences)

### 良くなること

- `--update` で遅延が戻らずに、期間を区切って緩められる。期間が過ぎれば、次の `--update` で何もしなくても既定に戻る
- 登録した全 PC に 1 か所 (`nix/shared/`) から効かせられる

### 注意が必要なこと

- 反映は `~/dotfiles/setup --update` (switch だけでは `config.toml` に届かない)。入っている tool は上げない (`mise up` で入れる)
- `nix/shared/` に書く option は、全 PC の本体が持つものだけにする。`--update` は dotfiles-private を取るが本体は進めないので、
  本体の新しい option を書くと、本体が古い PC の switch が「option が無い」で止まる (本体が `nix/shared/` を読む前の PC では、
  `nix/shared/` は読まれないだけで止まらない)
- `private-host.sh compare` は、`nix/shared/` の値を新しい形にだけ当たる違いとして出す (登録で増える値。README の「登録する」)
- 状態ファイルが無い・壊れているときは 9d を書く (`minimumReleaseAge` を 9d より長くした PC でも 9d)

## 6. 検証 (Verification)

- `nix/tests/mise-release-age.nix` (`mise-release-age-state`)・`bootstrap-mise.test.sh` (`bootstrap-mise-test`)・`private-hosts.nix`
  (`private-hosts-state`)。`nix flake check ./nix`
- mise の性質は隔離した mise 2026.8.6 で確かめた (§1 の表)
- 文字列の store path (flake = false の input の形) で渡しても `nix/shared/` が当たることを `nix eval` で確かめた

## 7. 移行・運用手順

上書きを足す (登録した全 PC なら dotfiles-private の `nix/shared/<名前>.nix`、1 台だけならそのホストの `modules`):

```nix
{
  dotfiles.mise.releaseAgeOverrides = [
    {
      from = "2026-10-22";
      zeroDays = 3;
      reason = "脆弱性の修正版を入れる";
    }
  ];
}
```

merge の後に `~/dotfiles/setup --update`。新しい版は `mise up` (tool を絞るなら `mise up uv`) で入れる。終わった項目は setup の
警告のまとめ (`[bootstrap-mise]`) に出るので、PR で list から消す。
