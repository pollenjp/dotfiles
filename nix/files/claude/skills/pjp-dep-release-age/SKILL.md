---
name: pjp-dep-release-age
description: 依存パッケージを入れる・更新する・プロジェクトを scaffold する・パッケージマネージャを
  選ぶときに読む。npm install / pnpm add / yarn add / bun add / uv add / pip install /
  cargo add を打つ前、package.json や pyproject.toml や lockfile を作る/更新するとき、
  サプライチェーン攻撃対策や minimumReleaseAge・cooldown の話が出たときに使う
---

# 依存の公開 7 日ルール (minimumReleaseAge)

**公開から 7 日未満のバージョンに依存しない。** 乗っ取られたパッケージの汚染版は
公開直後に踏むのが典型経路で、7 日は「コミュニティが気付いて撤回される」までの
猶予。nix flake の pin 遅延 7 日ルール (pjp-nix-flake) と同じポリシーの npm/PyPI 版。

適用は 2 段:

1. **マネージャ選定**: release-age gate に対応したものを選ぶ (下表)。
   JS で選べるなら pnpm (除外設定あり・v11 はデフォルト有効)。npm しか使えない
   環境でも 11.10+ なら設定できる (ただし除外が無い)
2. **設定**: 7 日相当の値を必ず入れる。「対応マネージャを使うだけ」では pnpm 11 の
   デフォルト 1 日にしかならない

## 設定一覧 (7 日の値, 2026-09 時点)

| マネージャ | 設定 | 場所 | 7 日の値 (単位注意) |
|---|---|---|---|
| pnpm 11 (10.16+) | `minimumReleaseAge` / 除外 `minimumReleaseAgeExclude` | `pnpm-workspace.yaml` (10.x は `.npmrc`) | `10080` (分) |
| npm 11.10+ | `min-release-age` (**除外設定なし**) | `.npmrc` | `7` (日) |
| yarn 4.10+ | `npmMinimalAgeGate` / 除外 `npmPreapprovedPackages` | `.yarnrc.yml` | `10080` (分) |
| bun 1.3+ | `[install] minimumReleaseAge` / 除外 `minimumReleaseAgeExcludes` | `bunfig.toml` | `604800` (秒) |
| uv | `exclude-newer` (相対指定) / 個別 `exclude-newer-package` | `pyproject.toml` の `[tool.uv]` | `"1 week"` |
| cargo | **未対応** (RFC 3923 が進行中) | — | lockfile 更新時に版の公開日を目視 |
| nix flake | pjp-nix-flake の flake-lock-age | — | 7 日 (そちらを読む) |

対応状況は動きが速い。表と違う挙動を見たら公式 docs を確認してから直す。

pnpm の例:

```yaml
# pnpm-workspace.yaml
minimumReleaseAge: 10080 # 7 日 (分単位)。公開直後の汚染版を掴まない
```

## 既存プロジェクトへの導入

ゲートを入れた時点で今の依存が 7 日未満だと、解決が止まるか警告が出続ける。
**警告を残したまま使い続けない。** anchor を「7 日以上経った最新」まで下げて
解決し直す:

```sh
pnpm view <pkg> time --json | jq  # 各版の公開日時を見る
# package.json の指定を 7 日以上前の最新版に下げて、lockfile を作り直す
```

## 例外 (緊急の CVE 修正など)

7 日待てない事情があるときだけ、そのパッケージを除外設定に足す (上表)。
**遅延を外す判断はユーザーに確認してから。** 伸ばすほど既知 CVE の修正も
遅れるので、7 日より長くする方向も自明な改善ではない。

## 罠

- **bun**: `bun.lock` に載っている版はゲートを素通りする (oven-sh/bun#30525)。
  導入時は lockfile を作り直す
- **npm**: 除外設定が無いので、緊急時は一時的に `min-release-age=0` にして
  戻すしかない (これもユーザー確認案件)
- **ツール自体も同じ原則**: pnpm や node 本体を mise / nix で入れるときも
  出たての major (.0 直後) を避けて 1 つ前の系列を pin する
