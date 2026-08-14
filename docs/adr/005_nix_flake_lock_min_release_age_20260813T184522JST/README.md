# ADR: flake.lock に入れる revision へ最小経過日数を課す

| 項目 | 内容 |
| --- | --- |
| ステータス | 提案 (Proposed) — レビュー中 |
| 日付 | 2026-08-13 (JST) |
| 決定者 | pollenjp |
| 前提 ADR | [001_home_manager_migration](../001_home_manager_migration_20260808T163454JST/README.md)（`nix flake update` を更新手段として据えた ADR。本 ADR はその更新手段を差し替える） |
| 運用手順 | [`nix/README.md`](../../../nix/README.md#新しすぎる-revision-を-pin-しない-minimumreleaseage-相当)（日常運用はこちら） |

---

## 1. 背景 (Context)

2025〜2026 年にかけて npm / PyPI で公開直後のバージョンを取り込ませる形の
供給網攻撃が続いた。pnpm は v11 で `minimumReleaseAge` を既定 1440 分（1 日）で
有効にしており、「**出たばかりのものを掴まない**」という緩和策が一般化した。

同じ考えを Nix 側にも入れたい。しかし `minimumReleaseAge` に相当する設定は
**Nix には無い**。

### なぜ「設定」にならないのか

Nix にはパッケージ単位のバージョン解決が無い。npm のようにパッケージごとに
候補バージョンを選ぶ層が存在せず、入るものは `flake.lock` が指す nixpkgs ツリー
**1 点**で決まる。したがって

> 新しすぎるパッケージを避ける ＝ 新しすぎる revision を pin しない

であり、粒度は「パッケージの公開からの経過日数」ではなく「**pin した revision の
経過日数**」になる。ここを制御するには `nix flake update` の上げ先を選び直すしかない。
`nix flake update` は常に追跡先の先端を取るため、素で使うと遅延は作れない。

### nixpkgs は npm と同じ危険度ではない

前提として、nixpkgs には npm に無い構造的な緩和が既に効いている。

| 仕組み | 効果 |
| --- | --- |
| 上流リリース → nixpkgs への PR → review → master → Hydra ビルド → チャンネル公開 | この経路自体が数日の遅延と人の目を挟む |
| ソース tarball を固定出力ハッシュで pin | 上流が同じバージョンを差し替えても**ハッシュ不一致でビルドが落ちる**（npm の再公開は素通り） |
| 実測のチャンネル公開間隔 | 1〜3 日（先端でも数日遅れの版が入る） |

残るのは「悪意あるバージョンが正規の手順で取り込まれる」「nixpkgs の commit 権限が
奪われる」経路で、ここには経過日数しか効かない。つまり**入れる価値はあるが、
npm ほど劇的には効かない**という位置づけになる。

### 遅延にはコストがある

遅延を伸ばすほど、**既知 CVE が未修正のまま残る期間も伸びる**。ワークステーション
では browser / curl / openssl のような日常的に踏むものの既知 CVE のほうが、
供給網攻撃より実害の確率が高い。長くすれば安全になるという種類の数字ではない。

## 2. 決定 (Decision)

1. `flake.lock` に入れる revision は、**公開から 7 日以上経ったもの**に限る。
   日数は `DOTFILES_MIN_RELEASE_AGE_DAYS` で変えられる（`0` で遅延なし）。
2. 対象は `nixpkgs` と `home-manager` の**両方**。片方だけ遅らせても、もう片方が
   先端に張り付いたままになる。
3. 上げ先の決定と `flake.lock` への書き込みは
   [`nix/scripts/flake-lock-age.sh`](../../../nix/scripts/flake-lock-age.sh) に置く。
   `setup.sh` の `flake-update` 手順はこれを呼ぶ。**素の `nix flake update` は使わない。**
4. `flake.nix` は `nixpkgs-unstable` を追ったままにし、pin は `flake.lock` にだけ書く。
   その結果**素で `nix flake update` を叩けば遅延は黙って外れる**ので、CI に
   `lock-age` ジョブ（`flake-lock-age.sh check`）を置いて気付けるようにする。

### 日数の根拠を input ごとに変える

| input | 何の時刻で測るか | なぜ |
| --- | --- | --- |
| `nixpkgs` | `releases.nixos.org` のチャンネル公開時刻（`git-revision` の `Last-Modified`） | 各公開は Hydra を通った commit なので binary cache が揃っている |
| `home-manager` | 既定ブランチの commit 時刻（GitHub API の `until=`） | home-manager にはチャンネルが無い |

**nixpkgs で「master の任意の commit を日付だけで選ぶ」のは採れない。** Hydra は
master の全 commit を評価しているわけではないので、チャンネル公開でない commit は
derivation が cache に無く、ほぼ全部ソースビルドになる。`nixpkgs-unstable` ブランチの
履歴は master の履歴そのもの（ブランチは Hydra を通った commit へ早送りされるだけ）
なので、`git log` から日付で選ぶ形も同じ罠を踏む。**公開の一覧から選ぶ**必要がある。

## 3. 変更点の詳細

| ファイル | 変更 |
| --- | --- |
| `nix/scripts/flake-lock-age.sh` | 新規。`resolve` / `update` / `check` の 3 動作 |
| `nix/scripts/setup.sh` | `step_flake_update` が素の `nix flake update` の代わりに上記を呼ぶ。手順名・`--help`・環境変数一覧を追随 |
| `.github/workflows/nix.yml` | `lock-age` ジョブを追加。`workflow_dispatch` に逃げ道の入力 `min_release_age_days` を追加 |
| `nix/flake.lock` | 新しい方針に合わせて pin を下げ直した（下記） |
| `nix/README.md` | 「新しすぎる revision を pin しない」節を追加。更新の表と手順を追随 |
| `docs/adr/001_.../textbook/05_daily_usage.md` | 手順書なので現行に追随（ADR README の方針どおり） |

### pin の下げ直し

方針の導入時点の `flake.lock` は下限 7 日を満たしていなかったので、`update` で下げた。

| input | 変更前 | 変更後 |
| --- | --- | --- |
| `nixpkgs` | `70ce234` (2026-08-06) | `104240a` (2026-08-03 公開 / 10 日前) |
| `home-manager` | `7834e82` (2026-08-06) | `a7c70cc` (2026-08-05 / 7 日前) |

### 依存を増やさない

`setup.sh` は **Nix が入る前にも走る**ので、依存できるのは bash 3.2 / coreutils /
curl だけ（`jq` は Nix が入れるもの）。`flake-lock-age.sh` は同じ制約に合わせてある。

- JSON（`flake.lock` / GitHub API）は **`jq` を使わず**、`nix eval` の
  `builtins.fromJSON` と `grep -oE` で読む
- `date` は GNU と BSD（macOS）の両方の書式を持つ（`-d` の有無で判定）
- `releases.nixos.org` の索引は JS で描画されるので、公開の一覧は
  S3 の `ListObjectsV2`（`nix-releases` バケット）を直接引く

## 4. 検討した代替案

| 案 | 採らなかった理由 |
| --- | --- |
| **安定版チャンネル（`nixos-26.05`）へ移る** | 遅延ではなく凍結。バージョンが半年据え置きになるので「最新よりちょっと遅れる」という要求とは別物。security backport は入るが、unstable の新しさを捨てる判断は本 ADR の範囲外 |
| **`flake.nix` に revision を直書きする**（`github:NixOS/nixpkgs/<rev>`） | 素の `nix flake update` が no-op になり fail-safe になる利点はあるが、追跡先が `flake.nix` から読めなくなり diff も 2 ファイルに散る。CI の番人で同じ事故を捕まえられるので採らなかった |
| **Renovate / Dependabot の `minimumReleaseAge`** | Renovate の nix manager は `nix flake update` を走らせるだけで、上げ先を「N 日前」に指定できない。CI 常駐を増やす割に効かない |
| **Determinate Secure Packages** | nixpkgs の審査済み subset を SLA 付きで提供する商用サービス。仕組みは経過日数による隔離ではなく能動的な CVE 修正で、方向が逆（速く直す）。個人の dotfiles には過剰 |
| **master の commit を日付で選ぶ** | binary cache が揃わずソースビルドになる（「2. 決定」の注記） |
| **観測した公開を台帳に記録して熟成させる** | 公開時刻が `Last-Modified` で直接取れるので台帳は不要。定期実行しないと台帳が埋まらない欠点もある |

## 5. 影響 (Consequences)

### 良くなること

- 公開直後の revision を掴まなくなる。取り込みまでに最低 7 日の観測期間ができる
- 上げ先が「Hydra を通ったチャンネル公開」に限定されるので、binary cache が揃う
  revision しか入らない（素の `nix flake update` と同じ性質を保てる）
- 遅延が外れたことに CI で気付ける

### 注意が必要なこと

- **既知 CVE の未修正期間が最大 7 日伸びる。** 緊急時は
  `DOTFILES_MIN_RELEASE_AGE_DAYS=0` で先端へ上げ、`lock-age` が落ちるのは
  意図どおりとして扱う（`workflow_dispatch` で下限 `0` を渡せば通せる）
- **`flake.nix` だけ見ても遅延は判らない。** pin は `flake.lock` にしかない
- `check` の判定に使う `lastModified` は **commit 時刻**であって公開時刻ではない。
  Hydra の遅れ（実測 1〜2 日）の分だけ判定は緩い側に出る
- 未認証の GitHub API は 60 req/hour。1 回の実行で 1 本しか投げないので通常は
  問題にならないが、CI では `GITHUB_TOKEN` があれば使う
- unstable の系列は半年ごとに変わる（`26.11pre` → `27.05pre`）。分岐直後は新しい
  系列に十分古い公開が無いので、`flake-lock-age.sh` は 1 つ前の系列まで見る
- **この遅延が効くのは Nix 管理の範囲だけ。** mise が入れる言語ランタイムや
  npm / uv のプロジェクト依存は対象外で、2025〜2026 年の攻撃はむしろそちら側に
  多い。pnpm の `minimumReleaseAge` などは別途こちらで設定する必要がある

## 6. 検証 (Verification)

すべて Determinate Nix 3.21.9 (nix 2.34.8) / WSL2 で実測。

### `--override-input` が lock に書かれるか（この方式の前提）

nix 2.25 のマニュアルは `--override-input` が `--no-write-lock-file` を含意すると
書いているが、`nix flake update` 経由では**書き込まれる**ことを使い捨ての flake で
確認した。`flake.nix` 側は `ref: nixpkgs-unstable` のまま、`locked.rev` だけが
指定した revision になる。複数 input の同時指定も効く。

```
• Updated input 'home-manager':
    'github:nix-community/home-manager/0668fdb' (2026-08-13)
  → 'github:nix-community/home-manager/7834e82' (2026-08-06)
• Updated input 'nixpkgs':
    'github:NixOS/nixpkgs/044bfe7' (2026-08-12)
  → 'github:NixOS/nixpkgs/104240a' (2026-08-03)
```

### 公開時刻が取れるか

`channels.nixos.org/nixpkgs-unstable` は該当ディレクトリへ 302 するので、そこから
系列名（`nixpkgs-26.11pre`）が取れる。S3 の `ListObjectsV2` は系列の公開を 81 件返し、
各 `git-revision` の `Last-Modified` が公開時刻そのものだった（例:
`nixpkgs-26.11pre1004746.f9d8b6595035` → `Mon, 25 May 2026 20:47:05 GMT`）。

公開間隔が一定でないため、下限 7 日は 9 日前の公開に当たった（8/4〜8/7 に公開が無い）。
**下限どおりの日数になるわけではなく、下限以上の直近が選ばれる**。

### script の動作

| 確認 | 結果 |
| --- | --- |
| `resolve`（既定 7 日） | `104240a` / `nixpkgs-26.11pre1046984` / 公開 2026-08-03 (9 日前) |
| `resolve`（`=0`） | 先端 `044bfe7`（0 日前）を選ぶ |
| `resolve`（`=120`） | 走査上限に当たったことを明示して失敗（1 つ前の系列まで広げた上で） |
| `check`（導入前の lock） | `home-manager` が 6 日前で NG → 終了コード 1 |
| `check`（`update` 後） | nixpkgs 10 日前 / home-manager 7 日前で OK |
| `check`（`=abc`） | 整数でない値を弾いて終了コード 1 |
| `check`（空文字） | 既定 7 に落ちる（CI が `workflow_dispatch` 以外で空を渡すため） |
| `setup.sh --dry-run --steps flake-update` | `flake-lock-age.sh update` を表示するだけ |

### 新しい pin で設定が壊れていないか

```
$ nix flake check --all-systems --no-build ./nix
✅ checks.x86_64-linux.home-pollenjp@wsl-no-1password
✅ checks.aarch64-linux.home-pollenjp@aarch64-linux
✅ checks.x86_64-linux.home-sandbox
（24 件すべて通過）
```

`shfmt -d` / `shellcheck` は `nix/` 配下の `*.sh` すべてで通過。

## 7. 移行・運用手順

日常運用は [`nix/README.md`](../../../nix/README.md#新しすぎる-revision-を-pin-しない-minimumreleaseage-相当)
を参照。要点だけ。

```sh
# 更新する (setup 経由でも同じ)
./nix/scripts/flake-lock-age.sh update
~/dotfiles/setup --flake-update --update

# 選ばれる revision を見るだけ
./nix/scripts/flake-lock-age.sh resolve

# 今の lock を検査する (CI が回しているものと同じ)
./nix/scripts/flake-lock-age.sh check

# 日数を変える / 遅延を外す
DOTFILES_MIN_RELEASE_AGE_DAYS=14 ./nix/scripts/flake-lock-age.sh update
DOTFILES_MIN_RELEASE_AGE_DAYS=0  ./nix/scripts/flake-lock-age.sh update
```

遅延を外した commit は CI の `lock-age` が落ちる。通したいときは
`workflow_dispatch` の `min_release_age_days` に `0` を入れて再実行する。
