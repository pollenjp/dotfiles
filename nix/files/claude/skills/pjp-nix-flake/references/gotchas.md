# flake のハマりどころ

## `.env` を読む (mise の `_.file` の置き換え)

`mise.toml` の `[env] _.file = { path = ".env", redact = true }` に相当するものは
flake に無いので、`shellHook` で明示的に読む。

```nix
shellHook = ''
  if [ -f .env ]; then
    set -a
    . ./.env
    set +a
  fi
'';
```

- **自動発火しない。** mise は `cd` した時点で env を張り替えるが、`nix develop` は
  明示的に入る必要がある。同じ体験が欲しければ direnv（dotfiles の home-manager が
  nix-direnv と一緒に入れる。`nix/home/modules/direnv.nix`）で、
  `echo 'use flake' > .envrc && direnv allow`。1 つの flake に devShell を並べ、ディレクトリ
  ごとに `use flake ../..#ch01` のように選ぶこともできる。nix-direnv が devShell を `.direnv/`
  に cache して GC root も張るので、入るたびに評価し直さず、GC でも消えない。
  `flake.nix`・`flake.lock` 以外の、flake.nix から読むファイルを変えたら `direnv reload`
  （か `.envrc` に `watch_file <ファイル>`）
- **秘密の値は `.envrc` に書かない。** dotfiles の global gitignore は `.envrc` を無視しない
  （repo に置いて共有するため。`!.envrc` は要らない）。秘密は global gitignore が無視する
  `.env` に置き、`.envrc` から `dotenv_if_exists` で読む（`.env` が無ければ何もしない。
  `nix develop` で入るときは上の shellHook で読む）。commit しない手元だけの `.envrc` は、
  その repo の `.git/info/exclude` に書く。`.direnv/` は global gitignore が無視する
- **`redact = true` 相当は無い。** あれは mise 自身の出力から値を伏せる機能で、
  シェルに入った後の環境変数はどちらにせよ素で見える
- 相対パスで読むので、**プロジェクトルートで `nix develop` すること**

## git 管理下では追跡済みファイルしか見えない

flake は git リポジトリ内では **追跡済みファイルしか見ない。** `flake.nix` を
`git add` しないと "file not found" で落ちる。

逆に **git リポジトリでないディレクトリでは、ディレクトリ全体を `/nix/store` へ
コピーする。** `/nix/store` は誰でも読めるので、`.env` が git 管理外になっていると
トークンがそこに残る。`.gitignore` で必ず外すこと。

## 差分ビルドは無い

mise の `sources` / `outputs = { auto = true }` に相当するものは無く、毎回すべてを
作り直す。対象を絞りたいときはファイルを明示する。

## mise からの移行

| 旧 (`mise.toml`) | 新 (flake) |
| --- | --- |
| `[tools]` の言語ランタイム | `devShells.default` の `packages` |
| `[env]` の直書き | `mkShellNoCC` の `shellHook` で `export` |
| `[env] _.file = { path = ".env" }` | `shellHook` で `set -a; . ./.env; set +a`（上記） |
| `[tasks]` | script として `scripts/` へ切り出し、devShell へ入り直させる |
| `sources` / `outputs`（差分ビルド） | 相当なし |
| ツールの版を env var で固定 | `flake.lock` が固定する。**明示の版指定は要らない** |

ツール固有の移行（PlantUML / drawio）は、それぞれの skill の
`references/from-mise.md` に対応表がある。
