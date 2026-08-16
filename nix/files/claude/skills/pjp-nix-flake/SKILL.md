---
name: pjp-nix-flake
description: repo や script が手元に無い外部ツールを要求するときの用意の仕方。
  「この repo に nix flake を用意して」「devShell を作って」「依存ツールを入れて」
  「mise から flake へ移したい」と言われたとき、script を足してそれが未インストールの
  コマンドを使うとき、`pip install` / `npm install -g` / `apt install` / `brew install`
  を打ちたくなったときに読む。flake / mise / system の選択順、`flake.nix` の骨組み、
  script から devShell へ自動で入り直すパターン、`flake.lock` を必ず commit する理由、
  `.env` の読み込みや git 追跡まわりのハマりどころを含む。
---

# pjp-nix-flake

script や repo が、手元に無い外部ツールを要求するときの用意の仕方。

## 選択順

1. **nix flake** — その skill / repo に `flake.nix` と `flake.lock` を置き、devShell に入れる
2. **mise** — flake が過剰なとき。`mise.toml` の `[tools]` に書く
3. **system へ直接入れる** — 1 も 2 も不可能なときだけ

**`pip install` / `npm install -g` / `sudo apt install` / `brew install` は実行しない。**
3 を選ぶ場合は、1 と 2 が不可能な理由を述べて**確認を取ってから**にする。

ここで決めているのは **その script / repo に閉じた依存**。自分のグローバル環境に
何を入れるか（グローバル CLI は Nix、言語ランタイムは mise）は別の話で、dotfiles の
ADR 001 決定 6 に従う。

## 使い方

```sh
nix develop                    # devShell に入る
nix develop --command <cmd>    # 1 コマンドだけ実行する
nix flake update               # 版を上げる (flake.lock が書き変わる)
```

## `flake.nix` の骨組み

`systems` は使う環境に合わせる。**`x86_64-darwin` は nixpkgs 26.11 でサポートが
切れている**ので含めない。

```nix
{
  description = "<repo> の依存ツール";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs =
    { nixpkgs, ... }:
    let
      inherit (nixpkgs) lib;

      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = lib.genAttrs systems;
    in
    {
      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt);

      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShellNoCC {
            packages = [
              pkgs.nodejs_24
              pkgs.uv
            ];
          };
        }
      );
    };
}
```

## `flake.lock` は必ず commit する

版を固定しているのは `flake.lock`。`PLANTUML_VERSION` のような明示の版指定は要らない。

特に **store へコピーされる場所（skill など）では lock が無いと動かない。** store は
read-only なので、nix がその場で lock を書こうとして失敗する。

```sh
nix flake update
git add flake.lock
```

## script から devShell へ入り直す

呼ぶ側に `nix develop` を意識させないためのパターン。**印を付けて 1 回だけにする**
（devShell に入っても道具が揃わない場合の無限ループ防止）。

```bash
#!/usr/bin/env bash
set -eu -o pipefail

repo_root=$(
  cd -- "$(dirname -- "$0")/.." &>/dev/null
  pwd -P
)

have() { command -v "$1" &>/dev/null; }

if ! have <tool>; then
  if [[ -z ${<TOOL>_REEXEC:-} ]] && have nix; then
    export <TOOL>_REEXEC=1
    exec nix develop "${repo_root}" --command "$0" "$@"
  fi
  echo "<tool> が見つかりません。nix があれば devShell へ自動で入り直します。" >&2
  exit 1
fi
```

⚠️ **`~/.claude/skills/<名前>` のような store への symlink では、この形は動かない。**
`$0` のままだと flake の位置を見失い、symlink を `path:` へ渡すと解決先を外部パス
扱いされてこう落ちる。

```
error: access to absolute path '/nix/store/...' is forbidden in pure evaluation mode
```

`readlink -f` で実体まで解決してから `path:` に渡す。skill に flake を持たせる
場合の置き場と形は `nix/files/claude/skills/README.md`（store へコピーされる側）と
claude-skills の `skills/README.md`（作業クローン側）を参照。

## その他

`.env` の読み込み、git 追跡まわりの罠、差分ビルドが無いこと、mise からの移行
→ `references/gotchas.md`
