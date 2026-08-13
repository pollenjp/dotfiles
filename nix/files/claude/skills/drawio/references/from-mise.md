# 旧構成（apt + mise.toml）からの移行

以前は drawio-desktop の `.deb` と `xvfb` / `fonts-noto-cjk` を apt で入れ、
`drawio/mise.toml` の task から `xvfb-run drawio ...` を叩いていた。
その 3 つの依存はすべて `flake.nix` に入ったので、**system 側は空にできる。**

## 対応表

| 旧 | 新 |
| --- | --- |
| `sudo apt install xvfb fonts-noto-cjk` | 不要（flake が持つ）|
| `.deb` を GitHub Releases から入れる | 不要（nixpkgs の drawio を `flake.lock` で固定）|
| `mise run drawio:generate` | `~/.claude/skills/drawio/scripts/drawio-export.sh` |
| `mise run drawio:generate png` | `… /drawio-export.sh -f png` |
| `mise run drawio:png` | `… /drawio-export.sh -f png -s 1.4` |
| `DRAWIO_THEME=light`（`mise.toml` の `[env]`）| 常に `--svg-theme light`（スクリプトが渡す）|
| 図の中に置いていた背景用の白い矩形セル | 不要（出力後に差し込む）|
| `realpath` を挟んでいた箇所 | 不要（相対パスで動く）|

## 手順

```sh
cd <プロジェクト>/drawio
rm mise.toml                    # drawio 以外の task が同居しているなら該当部分だけ削る
~/.claude/skills/drawio/scripts/drawio-export.sh
git diff --stat out/            # 出力が変わっていないか確認する
```

`out/` の差分が出るのは主にこの 2 つ。どちらも意図した変更。

- 白背景が `<rect>` として入る（以前は図の中の矩形セル、または透過のまま）
- drawio の版が上がったことによる `light-dark()` 表記
  （`references/troubleshooting.md` の「`--svg-theme light` を付ける」を見る）

背景用の白い矩形セルを図から消すと、その分だけ図のサイズが変わることがある
（矩形が図の bounding box を広げていた場合）。消したら PNG で見て確認する。

## CI で生成していた場合

`mise` の代わりにプロジェクトの flake から呼ぶ。この skill の `flake.nix` を
`drawio/` へコピーして `nix flake lock` し、両方 commit する。

```sh
cp ~/.claude/skills/drawio/flake.nix drawio/
cd drawio && nix flake lock
git add flake.nix flake.lock
```

以降は `nix develop ./drawio --command drawio ...` や `nix run ./drawio#drawio` が使える。
スクリプトそのものを CI で使いたい場合は `scripts/drawio-export.sh` もコピーする
（skill 側の `flake.lock` とプロジェクト側の `flake.lock` は別管理になる）。

MCP サーバをプロジェクトの `.mcp.json` から使う場合も、置くのはこの同じ flake。
手順は `references/mcp.md`。
