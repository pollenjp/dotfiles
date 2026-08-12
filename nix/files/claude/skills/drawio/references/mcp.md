# 公式 MCP サーバ (@drawio/mcp)

**図を draw.io エディタ（ブラウザ）で開くための道具。** SVG / PNG への書き出しには
要らない。書き出しだけなら `scripts/drawio-export.sh` で完結する。

| tool | すること |
| --- | --- |
| `open_drawio_xml` | mxGraph XML をエディタで開く |
| `open_drawio_csv` | CSV から図を作って開く |
| `open_drawio_mermaid` | Mermaid を編集可能な図に変換して開く |
| `list_pages` / `get_page` / `set_page` | `.drawio` のページ操作 |
| `search_shapes` | shape ライブラリの検索（style 文字列を引くのに便利）|

サーバ本体は `flake.nix` が `packages.drawio-mcp` として持っている。npm 配布物には
`package-lock.json` が無いので、lock を持つ GitHub リポジトリ側から rev で固めてある。
版を上げるときは `rev` / `version` / `hash` / `npmDepsHash` を差し替える
（`hash` は `lib.fakeHash` を入れて `nix build` すれば正しい値を教えてくれる）。

## 登録

**マシンごとに一度だけ。** `~/.claude/skills/drawio` は home-manager が張り替えても
パスが変わらないので、そのまま指してよい（store のパスはラッパが解決する）。

```sh
claude mcp add drawio --scope user -- "${HOME}/.claude/skills/drawio/scripts/drawio-mcp.sh"
```

`--scope user` なので、この登録は全プロジェクトで有効になる。確認と削除:

```sh
claude mcp list
claude mcp remove drawio --scope user
```

チームで共有するリポジトリに `.mcp.json` として置く場合は、`${HOME}` を含む絶対パスに
なってしまうので上のラッパは向かない。この skill の `flake.nix` をプロジェクトへ
コピーして、プロジェクトの flake から起動する。

```jsonc
// .mcp.json
{
  "mcpServers": {
    "drawio": {
      "command": "nix",
      "args": ["run", "./drawio#drawio-mcp"]
    }
  }
}
```

> `nix run ./drawio#...` は git リポジトリの中では **追跡されているファイルしか見ない**。
> `drawio/flake.nix` と `drawio/flake.lock` を `git add` してから使う。

## 注意

- `npx -y @drawio/mcp` は使わない（node と npm 越しの取得が固定されない）。
  ラッパ経由なら nix が版を固定する
- 図の配線（routing）機能を使うと、初回だけ CDN から `libavoid-routing.js` を
  取りに行く。ネットワークが無い環境では単に無効になるだけで、他の機能は動く
- `search_shapes` の索引はリポジトリ同梱のものを store に入れてあるので、
  こちらは CDN を見に行かない

ref: https://github.com/jgraph/drawio-mcp
