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
  nix-direnv と一緒に入れる。`nix/home/modules/direnv.nix`）で、道具の flake を `nix/` に置いて
  `echo 'use flake path:./nix' > .envrc && direnv allow`。1 つの flake に devShell を並べ、ディレクトリ
  ごとに `use flake path:../../nix#ch01` のように選ぶこともできる。nix-direnv が devShell を `.direnv/`
  に cache して GC root も張るので、入るたびに評価し直さず、GC でも消えない。
  `flake.nix`・`flake.lock` 以外の、flake.nix から読むファイルを変えたら `direnv reload`
  （か `.envrc` に `watch_file <ファイル>`）
- **`use flake` にも `path:` を付ける。** nix-direnv は devShell を作り直すたびに `nix flake archive` を
  打つので、素のパス（`use flake`・`use flake .`）では lazy-trees（Determinate Nix）でも repo 全体が写り、
  最新の写しが GC root で残る（下の「何が /nix/store へ写るか」）
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

その代わり、**素のパス（`nix develop .`・`nix develop ./nix`）で読むと、upstream の Nix 2.34 まで
（lazy-trees を切った Determinate Nix も）は repo 全体を `/nix/store` へ写す。** flake が repo の下の
ディレクトリにあっても、写すのは repo の root からの追跡済みファイル全部（commit していない変更も）で、
作業ツリーが変わるたびに別の写しになる。Determinate Nix の lazy-trees と upstream の Nix 2.35 以降は
評価の前に写さないが、`self` を参照する・`nix flake archive` を打つと、同じく repo 全体が写る
（下の「何が /nix/store へ写るか」）。道具の flake を flake だけのディレクトリに置き、`path:` で読むのは
このため（SKILL.md の「flake を置く場所」）。

逆に **`path:` で読むディレクトリと、git リポジトリでないディレクトリは、git を見ずに
ディレクトリの中身を全部 `/nix/store` へコピーする**（追跡していないファイルも、
`.gitignore` で外したものも。upstream の nix は評価のたびに、lazy-trees は `./.`・`self` などで参照した
ときと `nix flake archive` のときに写す）。`/nix/store` は誰でも読めるので、`.env` などの秘密を
そのディレクトリに置かない（`.gitignore` は効かない）。

### 何が /nix/store へ写るか（nix の版と lazy-trees）

写るかどうかは、nix（版と lazy-trees）・読み方・derivation が何を参照するかで決まる。下の表は、git の
repo の下のディレクトリに置いた flake を素のパスで、git でないディレクトリの flake を `path:` で読み、
`ls /nix/store` の差で見たもの（2026-11。Determinate Nix 3.24.1、upstream の Nix 2.34.9・2.35.3。
下の「確かめ方」）。

| すること | upstream の Nix 2.34 まで・lazy-trees を切った Determinate Nix | upstream の Nix 2.35 以降 | Determinate Nix の lazy-trees |
| --- | --- | --- | --- |
| 素のパスで、source を参照しない devShell を `nix develop`（`nix build`・`nix flake metadata` も） | repo 全体 | なし | なし |
| 素のパスで、derivation が `./data.txt`・`./.` を参照する | repo 全体と、参照した分 | 参照した分だけ | 参照した分だけ |
| 素のパスで、derivation が `self` を参照する | repo 全体 | repo 全体 | repo 全体 |
| 素のパスで `nix flake archive` を打つ | repo 全体 | repo 全体 | repo 全体 |
| `path:` で、何も参照しない | ディレクトリ全体 | ディレクトリ全体 | なし |
| `path:` で、`./.`・`self` を参照する・`nix flake archive` を打つ | ディレクトリ全体 | ディレクトリ全体 | ディレクトリ全体 |

- 「repo 全体」は git で追っているファイル全部（flake が下のディレクトリにあっても repo の root から）。
  「ディレクトリ全体」は追跡していないファイルも含めた中身全部。`./.` は flake のディレクトリを指し、
  素のパスならその中の追跡しているファイルだけが写る
- Determinate Nix の lazy-trees は、flake の木を元の場所から読み、derivation が参照した分だけを写す
  （Determinate が置く `/etc/nix/nix.conf` の既定。[lazy trees](https://docs.determinate.systems/determinate-nix/lazy-trees/)）。
  upstream の nix にこの設定は無い（`nix config show lazy-trees` が `could not find setting` で落ち、
  nix.conf に書いても効かない）
- upstream の Nix 2.35 は、`path:` でない flake を写さずに hash だけ取り、`.outPath` が derivation に
  入ったときに写す（[2.35 の release notes](https://nix.dev/manual/nix/2.35/release-notes/rl-2.35)）。
  NixOS 26.05 の既定の nix は 2.34、nixos-unstable は 2026-11 の時点で 2.35
- `self` は flake を読んだ木全体（下のディレクトリの flake でも repo の root から）を指す。`shellHook` に
  `${self}` を書くなど、derivation に入れると repo 全体が写る
- nix-direnv の `use flake` は、devShell を作り直すたび（`flake.nix`・`flake.lock`・`.envrc` を変えた
  ときなど）に `nix flake archive` を打ち、出た store path を `.direnv/flake-inputs/` に GC root として置く
  （前の GC root は外す。nix-direnv 3.2.0）。素のパスの flake なら repo 全体が写り、最新の写しは GC でも消えない

道具だけの devShell を `nix/` に置いて `path:` で読む形（SKILL.md の「flake を置く場所」）は、どの列でも
repo を写さない（写るのは `nix/` の `flake.nix` と `flake.lock` だけで、中身が同じなら同じ store path に
なる）。素のパスで読んでいる repo は、今のホストが lazy-trees や Nix 2.35 で写らなくても、この形へ直す。

ホストがどの列かは `nix --version` で見る。`nix (Determinate Nix …) …` なら `nix config show lazy-trees` が
`true` で lazy-trees の列、`false` で左の列。`nix (Nix) 2.35.…` 以降なら upstream の Nix 2.35 以降の列、
`nix (Nix) 2.34.…` までなら左の列。

#### 確かめ方

確かめたいコマンドの前後で `/nix/store` の一覧を取り、増えたものを見る。

```bash
export LC_ALL=C
d=$(mktemp -d)
ls /nix/store >"${d}/before"
nix develop --no-eval-cache ./nix --command true   # 確かめるコマンド (例は、素のパスで読むと写るか)
ls /nix/store >"${d}/after"
comm -13 "${d}/before" "${d}/after"                # 増えた store path (.drv や build の出力も出る)
```

- 中身が同じ写しは store に既にあり、差に出ない。試すたびに中身を変える（使い捨ての repo に
  `head -c 3000000 /dev/urandom >big.bin` を置いて commit し直すと、写ったものを大きさでも見分けられる）
- `nix develop`・`nix build` には `--no-eval-cache` を付ける（評価の cache に当たると、評価せずに返る）
- lazy-trees を切ったときは `--option lazy-trees false` を足して見る。upstream の nix は、nixpkgs の
  `nixVersions.nix_2_34`・`nixVersions.latest` を `nix build` して、その `bin/nix` で同じコマンドを打つ
- ほかの nix のプロセスが同時に足した store path も差に出る

### たまった写しを片付ける

素のパスで読んでできた repo の写しは、`/nix/store/<hash>-source` として残る。repo に
しか無いファイル（下の例では `<目印>`。`scripts/lint.sh` のような、その repo の root からの
パス）を持つものを探し、どこからも使われていなければ消す。

```bash
# 一覧 (写しを作った時刻つき)。store のパスは mtime が 1970 年にそろうので、時刻は ctime で見る
for p in /nix/store/*-source; do
  [[ -f $p/<目印> ]] && stat -c '%z %n' "$p"
done

# 消す。使われている写しは nix-store が alive と言って消さない (何が使っているかは nix-store --query --roots <path>)
for p in /nix/store/*-source; do
  [[ -f $p/<目印> ]] && nix-store --delete "$p"
done
```

nix-direnv で読んでいた repo の写しは、`.direnv/flake-inputs/` の GC root が掴んでいて消えない
（`nix-store --query --roots <path>` に出る）。`.envrc` を `use flake path:./nix` に直して `direnv allow`
すると、作り直すときに外れる（`.direnv/` を消しても外れる）。

使われていないパスを repo の写しに限らずまとめて消すなら `nix store gc`（ディスクの空きを
作る全体の手順は pjp-disk-cleanup skill）。

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
