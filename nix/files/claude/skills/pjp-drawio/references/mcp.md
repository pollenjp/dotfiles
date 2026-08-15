# 公式 MCP サーバ (@drawio/mcp)

**任意。書き出しには要らない**（`scripts/drawio-export.sh` で完結する）。
図を draw.io エディタ（ブラウザ）で開きたいときだけ入れる。

| tool | すること |
| --- | --- |
| `open_drawio_xml` | mxGraph XML をエディタで開く |
| `open_drawio_csv` | CSV から図を作って開く |
| `open_drawio_mermaid` | Mermaid を編集可能な図に変換して開く |
| `list_pages` / `get_page` / `set_page` | `.drawio` のページ操作 |
| `search_shapes` | shape ライブラリの検索（style 文字列を引くのに便利）|

## 設定はプロジェクトのリポジトリへ置く

`~/.claude.json` へ user scope で入れるのではなく、**図を扱うリポジトリの `.mcp.json` に
書く。**

- 図を扱うリポジトリでだけ有効になる。関係ないプロジェクトに常駐させない
- clone した人にそのまま伝わる。マシンごとの手作業（`claude mcp add`）が消える
- 版はそのプロジェクトの `flake.lock` が固定する。図の生成に使う drawio の版と
  同じ扱いになる

`drawio/` に flake を置き、リポジトリのルートに `.mcp.json` を書く。

```sh
cp ~/.claude/skills/pjp-drawio/flake.nix ~/.claude/skills/pjp-drawio/flake.lock drawio/
git add drawio/flake.nix drawio/flake.lock
```

```jsonc
// .mcp.json (リポジトリのルート)
{
  "mcpServers": {
    "drawio": {
      "command": "nix",
      "args": ["run", "path:./drawio#drawio-mcp"]
    }
  }
}
```

初回だけ Claude Code が承認を訊く（それまで `claude mcp list` では
`⏸ Pending approval` と出る）。

> **`path:` を付ける。** 付けないと git flake として扱われ、**追跡前のファイルが見えない。**
>
> ```
> error: Path 'drawio/flake.nix' in the repository "…" is not tracked by Git.
> ```
>
> `path:` なら追跡状態に関わらず動き、`Git tree has uncommitted changes` の警告も出ない。

> `.mcp.json` では `${VAR}` と `${VAR:-default}` が `command` / `args` / `env` / `url` /
> `headers` で展開される。パスをプロジェクトルート起点で明示したいなら
> `path:${CLAUDE_PROJECT_DIR:-.}/drawio#drawio-mcp` と書ける。

`flake.lock` はコピーせず `cd drawio && nix flake lock` で作ってもよい。その場合
skill 側とは別に版が動く。

## 個人的に全プロジェクトで使いたい場合

user scope に入れる。**この場合プロジェクト側に flake は要らない**（skill 同梱のものを
使う）。マシンごとに一度だけ実行する。

```sh
claude mcp add drawio --scope user -- "${HOME}/.claude/skills/pjp-drawio/scripts/drawio-mcp.sh"
claude mcp list
claude mcp remove drawio --scope user
```

`~/.claude/skills/pjp-drawio` は home-manager が張り替えてもパスが変わらないので、
そのまま指してよい（store の実体はラッパが解決する）。

**共有リポジトリの `.mcp.json` にこの形（skill のパス）を書かない。** この skill を
入れていない人の手元で壊れる。共有するなら上のプロジェクト側の形にする。

## 版を上げる

`flake.nix` の `rev` / `version` / `hash` / `npmDepsHash` を差し替える。`hash` は
`lib.fakeHash` を入れて `nix build` すれば正しい値を教えてくれる。npm の配布物には
`package-lock.json` が無いので、lock を持つ GitHub リポジトリ側から固めている。

## 注意

- `npx -y @drawio/mcp` は使わない（node と npm 越しの取得が固定されない）。
  flake 経由なら nix が版を固定する
- 図の配線（routing）機能を使うと、初回だけ CDN から `libavoid-routing.js` を
  取りに行く。ネットワークが無い環境では単に無効になるだけで、他の機能は動く
- `search_shapes` の索引はリポジトリ同梱のものを store に入れてあるので、
  こちらは CDN を見に行かない

ref: https://github.com/jgraph/drawio-mcp
