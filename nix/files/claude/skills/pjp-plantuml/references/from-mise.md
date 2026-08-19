# 旧構成（apt + mise.toml）からの移行

以前は `plantuml/mise.toml` で java を用意し、`plantuml:download` task で
`plantuml.jar` を GitHub Releases から `~/.cache/plantuml/` へ落とし、
graphviz と `fonts-noto-cjk` は apt で入れていた。

**その依存はすべて `flake.nix` に入ったので、system 側は空にできる。**
nixpkgs の `plantuml` が JDK と graphviz を同梱していて `GRAPHVIZ_DOT` まで
設定済みなので、jar を落とす手順そのものが無くなる。

## 対応表

| 旧 | 新 |
| --- | --- |
| `[tools] java = "25"` | 不要（`pkgs.plantuml` が JDK を同梱）|
| `PLANTUML_VERSION` / `PLANTUML_JAR` | 不要（版は `flake.lock` が固定）|
| `mise run plantuml:download` | **廃止**（jar を落とす手順ごと無くなる）|
| `mise run plantuml:run <args>` | `nix develop "path:$(readlink -f ~/.claude/skills/pjp-plantuml)" --command plantuml <args>`（`readlink -f` が要る理由は `troubleshooting.md`）|
| `mise run plantuml:generate` | `~/.claude/skills/pjp-plantuml/scripts/plantuml-export.sh` |
| `mise run plantuml:generate png` | `… /plantuml-export.sh -f png` |
| `mise run plantuml:generate svg,png` | `… /plantuml-export.sh -f svg,png` |
| `sudo apt install graphviz` | 不要（flake が持つ）|
| `sudo apt install fonts-noto-cjk` | 不要（flake が持つ。`troubleshooting.md`）|
| `.puml` の `skinparam backgroundColor #FFFFFF` | 不要（PlantUML は既定で白背景）|

## 手順

```sh
cd <プロジェクト>/plantuml
rm mise.toml                    # plantuml 以外の task が同居しているなら該当部分だけ削る
~/.claude/skills/pjp-plantuml/scripts/plantuml-export.sh
git diff --stat out/            # 出力が変わっていないか確認する
```

`~/.cache/plantuml/plantuml-*.jar` は使われなくなるので消してよい。

`out/` に差分が出るとしたら、主に PlantUML の版が変わったことによるもの
（線の太さやフォントメトリクスの微差）。**PNG で書き出して目で確認する。**

`.puml` から `skinparam backgroundColor #FFFFFF` を消しても出力は変わらない
（既定が白背景のため）。残しておいても害は無いので、急いで消す必要はない。

## 版の固定

既定では **nixpkgs が持っている版**を使い、`flake.lock` がそれを固定する。
`PLANTUML_VERSION` のような明示の指定は無くなる。

```sh
cd ~/dotfiles/nix/files/claude/skills/pjp-plantuml
nix flake update
git add flake.lock              # store は read-only なので lock は必ず commit する
```

nixpkgs より新しい版がどうしても要る場合だけ、`flake.nix` の中で上書きする。

```nix
plantumlPkg = pkgs.plantuml.overrideAttrs (old: rec {
  version = "1.2026.6";
  src = pkgs.fetchurl {
    url = "https://github.com/plantuml/plantuml/releases/download/v${version}/plantuml-${version}.jar";
    hash = "sha256-iZSPFMk3Vsej+3tpB4/zfoSJ/XndQwxYK5MeL2U1hpA=";
  };
});
```

`symlinkJoin` の `paths` を `[ plantumlPkg ]` に差し替えて使う。
hash は `nix store prefetch-file <url>` で取る。

> nixpkgs は `plantuml-pdf-<version>.jar` を使っているが、この派生が公開されて
> いないリリースがある（v1.2026.6 は plain jar のみ）。上のように plain jar を
> 指した場合、**PDF 出力は使えなくなる。**

## CI で生成していた場合

`mise` の代わりにプロジェクトの flake から呼ぶ。この skill の `flake.nix` を
`plantuml/` へコピーして lock を作り、両方 commit する。**`nix flake lock` は使わない**
（先端へ pin される。`pjp-nix-flake` skill の `references/lock-age.md`）。

```sh
cp ~/.claude/skills/pjp-plantuml/flake.nix plantuml/
git add plantuml/flake.nix   # flake は git の追跡済みファイルしか見ない
nix run 'github:pollenjp/dotfiles?dir=nix#flake-lock-age' -- update ./plantuml
git add plantuml/flake.lock
```

以降は `nix develop ./plantuml --command plantuml ...` や
`nix run ./plantuml#plantuml -- ...` が使える。スクリプトそのものを CI で使いたい
場合は `scripts/plantuml-export.sh` もコピーする（skill 側の `flake.lock` と
プロジェクト側の `flake.lock` は別管理になる）。

## 差分ビルドは無い

mise の `sources` / `outputs = { auto = true }` に相当するものは無く、
毎回すべての `.puml` を描き直す。`plantuml` は複数入力をまとめて受けるので
JVM の起動は 1 形式につき 1 回で済むが、図が増えると時間は伸びる。

対象を絞りたいときはファイルを明示する。

```sh
~/.claude/skills/pjp-plantuml/scripts/plantuml-export.sh 01_order_flow.puml
```
