# 新しすぎる revision を pin しない

`flake.lock` に入れる revision を「公開から 7 日以上経ったもの」に限る遅延。
npm / pnpm の `minimumReleaseAge` に相当する。

決定の記録は dotfiles の
[ADR 005](https://github.com/pollenjp/dotfiles/tree/main/docs/adr/005_nix_flake_lock_min_release_age_20260813T184522JST)。
ここは**他のリポジトリへ入れるときに要る分だけ**を書く。

## なぜ設定ではなく script なのか

Nix にはパッケージ単位のバージョン解決が無い。npm のようにパッケージごとに候補
バージョンを選ぶ層が存在せず、入るものは `flake.lock` が指す nixpkgs ツリー **1 点**
で決まる。したがって

> 新しすぎるパッケージを避ける ＝ 新しすぎる revision を pin しない

であり、粒度は「パッケージの公開からの経過日数」ではなく「**pin した revision の
経過日数**」になる。`nix flake update` は常に追跡先の先端を取るので、遅延は外から
作るしかない。`minimumReleaseAge` に相当する設定は **Nix には無い**。

## nixpkgs は「チャンネル公開の一覧」から選ぶ

**master の任意の commit を日付だけで選ぶのは採ってはいけない。** Hydra は master の
全 commit を評価しているわけではないので、チャンネル公開でない commit は derivation が
binary cache に無く、**ほぼ全部ソースビルドになる**。`nixpkgs-unstable` ブランチの履歴は
master の履歴そのもの（ブランチは Hydra を通った commit へ早送りされるだけ）なので、
`git log` から日付で選ぶ形も同じ罠を踏む。

そのため測り方が input ごとに変わる。

| input | 何の時刻で測るか |
| --- | --- |
| `nixpkgs`（`nixpkgs-unstable` を追うもの） | `releases.nixos.org` のチャンネル公開時刻（`git-revision` の `Last-Modified`） |
| その他の GitHub input | 追跡先の commit 時刻（GitHub API の `until=`） |
| `follows` / `path:` などの input | 対象外（自分の revision を持たない） |

判別は script が `flake.lock` を読んで自動で行うので、呼ぶ側で input を並べる必要は無い。

## 新しいリポジトリへ入れる

1. `flake.nix` は**追跡先を指したままにする**（`nixpkgs-unstable` など）。
   revision の直書きはしない。pin は `flake.lock` にだけ置く
2. lock を更新するときは素の `nix flake update` を使わず、こちらを通す

   ```sh
   nix run 'github:pollenjp/dotfiles?dir=nix#flake-lock-age' -- update
   ```

3. **CI に番人を置く。** これが無いと、素の `nix flake update` を 1 回叩いた時点で
   遅延が黙って外れる

   ```yaml
   lock-age:
     runs-on: ubuntu-latest
     steps:
       - uses: actions/checkout@<pin>
       - uses: DeterminateSystems/nix-installer-action@<pin>
       - run: nix run 'github:pollenjp/dotfiles?dir=nix#flake-lock-age' -- check
   ```

4. `flake.lock` を commit する

リポジトリ内に flake が複数あるなら、ディレクトリを並べて一度に見られる。
**flake を足したら CI の並びにも足すこと**（黙って対象から漏れる）。

```sh
nix run 'github:pollenjp/dotfiles?dir=nix#flake-lock-age' -- check ./nix ./tools/foo
```

## 日数を変える / 遅延を外す

```sh
nix run "${FLA}" -- --min-age-days 14 update
nix run "${FLA}" -- --min-age-days 0  update   # 遅延なし = 先端
```

環境変数 `FLAKE_MIN_RELEASE_AGE_DAYS` でも同じ（CI から渡すときはこちら）。

緊急の CVE 修正を先端から入れたときは CI の `check` が落ちるが、**それは意図どおり**。
記録として残すか、下限を下げて再実行する。

## 効かない範囲・限界

- **Nix 管理の依存にしか効かない。** mise が入れる言語ランタイムや npm / uv の
  プロジェクト依存は対象外で、2025〜2026 年の供給網攻撃はむしろそちら側に多い。
  pnpm の `minimumReleaseAge` などは別途そちらで設定する
- **既知 CVE の未修正期間が最大 7 日伸びる。** ワークステーションでは browser /
  curl / openssl の既知 CVE のほうが供給網攻撃より実害の確率が高い。7 日はその
  折り返し点として選んだ値で、長くすれば安全になる種類の数字ではない
- **`flake.nix` だけ見ても遅延は判らない。** pin は `flake.lock` にしかない
- `check` の判定に使う `lastModified` は **commit 時刻**であって公開時刻ではない。
  Hydra の遅れ（実測 1〜2 日）の分だけ判定は緩い側に出る。先端への事故を捕まえる
  用途には足りる
- 下限どおりの日数になるわけではない。公開間隔は一定でないので、**下限以上の直近**が
  選ばれる（下限 7 日で 9 日前の公開に当たる、など）

## ハマりどころ

- **nixpkgs の追跡先を `nixpkgs-unstable` から変えると script が止まる。**
  チャンネル公開の一覧から選ぶ形が崩れると binary cache の揃わない revision を
  掴むので、わざと落としてある
- unstable の系列は半年ごとに変わる（`26.11pre` → `27.05pre`）。分岐直後は新しい
  系列に十分古い公開が無いので、script は 1 つ前の系列まで遡る
- 未認証の GitHub API は 60 req/hour。CI では `GITHUB_TOKEN` があれば使われる
- `flake.lock` がまだ無いリポジトリでは先に `nix flake lock` を実行する
