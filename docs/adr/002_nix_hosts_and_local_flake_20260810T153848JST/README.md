# ADR: マシン固有設定の表現と、実行の入口となるパスを決める

| 項目 | 内容 |
| --- | --- |
| ステータス | 提案 (Proposed) — レビュー中 |
| 日付 | 2026-08-10 (JST) |
| 決定者 | pollenjp |
| 関連 PR | [#29](https://github.com/pollenjp/dotfiles/pull/29) |
| 前提 ADR | [001_home_manager_migration](../001_home_manager_migration_20260808T163454JST/README.md) |
| 運用手順 | [`nix/README.md`](../../../nix/README.md)（日常運用はこちら） |

前提 ADR で home-manager への移行そのものは決めた。この ADR はその上で残っていた
2 つの問題 — **マシンごとの差をどう書くか** と **どのパスから実行するか** — を決める。

---

## 1. 背景 (Context)

### 課題 A: マシン固有の値が平坦に並んでいて、有効な組み合わせが読めない

`mkHome` に渡す値は平坦なフラグの並びだった。

```nix
"pollenjp@wsl" = mkHome {
  username = "pollenjp";
  system = "x86_64-linux";
  isWSL = true;
  onePassword = true;
  windowsUserName = "polle";
};
```

3 つのフラグの間には次の依存があるが、**並びからは読み取れない**。

- `windowsUserName` は WSL のときしか意味を持たない（`/mnt/c/Users/...` を組み立てる値のため）
- 1Password 連携はホスト側 Windows の `op-ssh-sign-wsl.exe` を呼ぶので WSL 専用
- よって `windowsUserName` が要るのは「WSL かつ 1Password」のときだけ

さらに、分岐の実装は「`windowsUserName` が `null` かどうか」という**暗黙の判定**だった。
このため **1Password を使わないマシン**と**書き忘れ**を区別できず、前者でも警告が出ていた。
「署名しない」も正当な構成であり、警告が出るのは誤りである。

### 課題 B: 一時的なマシンを試す場所が無い

検証用や一時的な環境の `homeConfiguration` を試したいが、

- 登録簿 (`hosts/default.nix`) に混ぜると git に載り、他マシンにも配られる
- かといって `hosts/default.nix` を手で編集して commit しないのは事故のもと

「git に載せずにホストを定義する」場所が無かった。

### 課題 C: リポジトリの置き場所が旧経路に縛られている

旧経路 `main.bash setup` は `~/dotfiles` にリポジトリがある前提で、配置する設定ファイルに
`~/dotfiles/...` を直接書き込む（`~/.config/fish/config.fish` が `~/dotfiles/.fish/*.fish` を
読む、など）。

一方 Nix 経路では設定ファイルは store から配られるので、リポジトリがどこにあってもよい
（モジュールは `../../files/...` と flake root 内の相対パスしか参照していない）。
それにもかかわらず、手順は `~/dotfiles/nix#...` と旧経路の置き場所を引きずっていた。

他のリポジトリは `ghq` 配下にあるので、dotfiles だけ規則が違う状態でもあった。

---

## 2. 決定 (Decision)

### A. マシン固有設定は入れ子の attrset で渡す

**親が有効なときだけ子が意味を持つ**という関係を、そのまま階層にする。

```nix
"pollenjp@wsl" = mkHome {
  username = "pollenjp";
  system = "x86_64-linux";
  wsl = {
    enable = true;
    onePassword = {
      enable = true;
      windowsUserName = "polle";
    };
  };
};
```

有効な組み合わせは 3 通りだけになり、構造から読める。

| マシン | 指定 | git の署名 |
| --- | --- | --- |
| 非 WSL | `wsl` を書かない | 署名の設定を書き出さない |
| WSL / 1Password 無し | `wsl.enable = true;` | 同上 |
| WSL / 1Password 有り | 上のブロックまるごと | Windows 側の `op-ssh-sign-wsl.exe` を経由 |

階層で表現しきれない「親が false なのに子が true」は `assertions` で評価時に止める
（attrset は `wsl.enable = false` のまま `wsl.onePassword.enable = true` と書けてしまうため）。

暗黙の `null` 判定はやめ、`wsl.onePassword.enable` という**明示のフラグ**で切り替える。
false のマシンでは署名関連を**丸ごと**書き出さない。`commit.gpgSign = true` だけが残ると
署名鍵が見つからず `git commit` そのものが失敗するため、片方だけを残さない。

### B. リポジトリ本体は ghq のパスへ、実行の入口は `~/dotfiles` へ

パスの役割を 2 つに分ける。

| パス | 中身 | git |
| --- | --- | --- |
| `$(ghq root)/github.com/pollenjp/dotfiles` | リポジトリ本体 | 管理下 |
| `~/dotfiles` | ローカル専用の flake と `setup` への symlink | **管理外** |

```
~/dotfiles/
├── flake.nix   本体を input に取り、homeConfigurations などを再輸出する
├── flake.lock  nix が生成する
└── setup -> $(ghq root)/github.com/pollenjp/dotfiles/nix/scripts/setup.sh
```

本体を ghq 配下に置くことで、`cdrepo` など ghq 前提の仕組みと置き場所が揃う。
一方で日々叩くパスは短く固定したいので、`~/dotfiles` を入口として別に用意する。

`~/dotfiles/flake.nix` は本体の出力をそのまま再輸出するので、**登録簿のホストも
`~/dotfiles#pollenjp@wsl` で引ける**。入口が 1 つに揃うため、`tmp` のような
ローカル専用ホストを作るかどうかに関わらず常に置く。

```nix
homeConfigurations = dotfiles.homeConfigurations // {
  tmp = dotfiles.lib.mkHome { ... };   # このマシンにだけ在るホスト
};
```

これが課題 B の答えでもある。git 管理外のファイルなので、登録簿を汚さずに
一時的なホストを定義できる。

---

## 3. 変更点の詳細 (What changed)

| ファイル | 変更 |
| --- | --- |
| `nix/home/options.nix` | `dotfiles.wsl.{enable, onePassword.{enable, windowsUserName}}` を定義 |
| `nix/lib/mk-home.nix` | `mkHome` の引数を `wsl`（既定 `{ }`）に集約 |
| `nix/hosts/default.nix` | `pollenjp@wsl-no-1password` を追加。渡せる値をコメントに明記 |
| `nix/home/modules/git.nix` | 署名設定を `wsl.onePassword.enable` で切り替え。警告を `assertions` へ |
| `nix/flake.nix` | `lib.mkHome` を出力に追加（ローカル flake から呼ぶため） |
| `nix/scripts/setup-local-flake.sh` | 新規。`~/dotfiles` を用意する |
| `nix/scripts/setup.sh` | symlink 解決 / 手順 `local-flake` / flake の選択 / ホスト一覧 |
| `nix/README.md` | 「置き場所」節を新設。手順とコマンドのパスを更新 |

### `path:` を input に使う

`~/dotfiles/flake.nix` は本体を `path:` で参照する。

```nix
inputs.dotfiles.url = "path:/home/pollenjp/ghq/github.com/pollenjp/dotfiles/nix";
```

`git+file:` ではなく `path:` にした理由は、**本体を編集したら commit しなくても
そのまま試せる**ため。lock も評価のたびに追随するので `nix flake update` も要らない
（[検証](#6-検証-verification)で確認した）。

この選択には副作用がある。**untracked ファイルが見えるかどうかが flake の指し方で変わる。**

| 指し方 | 解決方法 | 追跡していないファイル |
| --- | --- | --- |
| `--flake <repo>/nix` | git リポジトリ内のパスなので **git 解決** | 見えない |
| `--flake ~/dotfiles`（`path:` 経由） | ディレクトリをそのまま複製 | **見える** |

CI は前者なので、後者だけで通していると commit 忘れに気付けない。
`setup.sh` の untracked 警告は、どちらの経路かで文言を出し分けるようにした。

### `setup.sh` が `$0` の symlink を辿る

`~/dotfiles/setup` が symlink である以上、`dirname "$0"` では実体に辿り着けず
`nix_dir` が `~` になる。`$0` の指す先を辿ってから解決する。

macOS の `readlink` には `-f` が無いので、`readlink` を繰り返す移植性のある形で書いた
（設計メモにある「macOS の `/bin/bash` は 3.2」という制約と同じ理由）。

### ホスト一覧はローカル flake も見る

`setup.sh` の一覧は登録簿を `sed` で舐めて作る（手順 1 の前に呼ぶので `nix` に頼れない）。
`~/dotfiles/flake.nix` も同じ方法で読み、両方の名前を出す。見ないと `tmp` がメニューに
出ないうえ、`--host tmp` も「登録されていません」で弾かれる。

左辺の抽出は `dotfiles.lib.mkHome` のような修飾付きの呼び方にも当たるようにした。
行頭が `#` の行は拾わないので、雛形のコメント例が幽霊ホストとして出ることはない。

---

## 4. 検討した代替案 (Alternatives considered)

### A-1. 平坦なまま `assertions` だけ足す

組み合わせの誤りは止められるが、「何が有効なのか」は結局コードを読まないと分からない。
構造で表せるものを検査で補うのは順序が逆と考えた。

### A-2. `nullOr submodule` で「無い状態」を `null` にする

```nix
wsl = { onePassword = { windowsUserName = "polle"; }; };  # 有り
wsl = { onePassword = null; };                            # WSL だが 1Password 無し
wsl = null;                                               # 非 WSL
```

不正な組み合わせを**型として**書けなくできるので理屈では上。だが `wsl = { }` が
「WSL だが 1Password 無し」を意味するのは読み手に優しくなく、`enable` フラグという
home-manager の慣習からも外れる。慣習に寄せ、残る 2 つだけ `assertions` で見る形にした。

### B-1. リポジトリ内に gitignore したホスト定義を置く

`hosts/local.nix` を gitignore する案。採らなかったのは、上記のとおり
**見えるかどうかが flake の指し方で変わる**ため。同じ定義が経路によって在ったり
無かったりするうえ、CI は git 解決なので手元だけ通る状態になる。

### B-2. `~/dotfiles` に本体を置いたまま `~/dotfiles/nix#...` を使い続ける

現状維持。ghq との不一致が残るのと、一時ホストの置き場所が無いままになる。

### B-3. ローカル flake を `~/.config/dotfiles-local/` などに置く

入口が `~/dotfiles/setup` に揃わない。短いパス 1 つに集約する利点を優先した。

---

## 5. 影響 (Consequences)

### 良くなること

- 有効な組み合わせが `hosts/default.nix` を見るだけで分かる
- 1Password の無いマシンで警告が出なくなる（「署名しない」を正当な構成として扱う）
- 一時的なホストを登録簿を汚さずに定義できる
- 入口が `~/dotfiles` に揃う。`~/dotfiles/setup` で更新でき、パスを覚えなくてよい
- 本体が ghq 配下に入り、他のリポジトリと同じ規則で辿れる
- 本体を編集したら commit せずにそのまま試せる

### 注意が必要なこと（レビュー対象）

- **非 WSL ホストの署名設定が無くなる。** 1Password を WSL 専用として `dotfiles.wsl` の
  下に置いた結果、`pollenjp@x86_64-linux` / `aarch64-linux` / `aarch64-darwin` には
  署名関連が入らない（変更前は `commit.gpgSign` と `defaultKeyCommand` が入っていた）。
  これらでも 1Password で署名したくなったら `onePassword` を `dotfiles.wsl` の外へ出す。
  `options.nix` にその旨を注記してある。
- **`~/dotfiles` の意味が経路によって違う。** 旧経路 `main.bash setup` では
  `~/dotfiles` がリポジトリ本体である。Nix 経路ではローカル flake の置き場所になる。
  両立しないが、元々「同一マシンで両方を走らせないこと」としているので新たな制約ではない。
  `setup-local-flake.sh` は `~/dotfiles` が git 作業ツリーだった場合に**何もせず止まる**ので、
  取り違えてリポジトリを壊すことはない。
- **既存マシンには移行が要る。** 本体を ghq 配下へ移し、`--steps local-flake` を一度実行する。
  それまでは `setup.sh` が従来どおり本体の flake を指すので、放置しても壊れはしない。
- **`nix flake update` の対象は本体側。** `~/dotfiles` の lock は `path:` を追うだけなので
  更新の必要が無い。依存を上げるときはリポジトリ側の `flake.lock` を触る。

---

## 6. 検証 (Verification)

環境の制約で `codeload.github.com` が 403 になるため、`nix/README.md` 記載の
input 差し替え（`--override-input`）で実行している。

### 設定

- `nix flake check --all-systems --no-build` — 24 件すべて通過
- `pollenjp@wsl` の `~/.config/git/config` が従来どおり `op-ssh-sign-wsl.exe` を指すこと
- `pollenjp@wsl-no-1password` と非 WSL ホストに署名設定が出ないこと
  （`signing.signByDefault` が `null`）
- `assertions` 2 種類が意図したメッセージで評価を止めること（不正なホストを一時的に足して確認）

### `path:` input の挙動（この決定の前提）

- 本体を編集したあと lock を更新せずに再評価すると、**変更が反映される**こと
- `path:` 経由では **untracked ファイルが見える**こと
  （`--flake <repo>/nix` の git 解決とは異なる）

### `~/dotfiles`（使い捨ての `HOME` と ghq root を作って通した）

- ghq のパスが違うときに終了コード 1 と置き直し手順が出ること
- 正常系で `flake.nix` と `setup` symlink が置かれ、2 回目は触らないこと
- `~/dotfiles/setup`（symlink）経由で `--list` / `--dry-run` が動くこと
  = `$0` の symlink 解決が効いていること
- 手順順序が `local-flake` → `switch` になり、`switch` が `~/dotfiles` を指すこと
- ローカル flake が無い新規マシンでは本体を指し、案内が出ること
- `~/dotfiles` が git 作業ツリーのときに止まること
- 生成された flake から本体の登録簿 6 ホストと `lib.mkHome` / `packages` が引けること
- 雛形のコメントを外して `tmp` を足すと登録簿と並んで出ること。コメントのままなら出ないこと
- `--host tmp` が通り `~/dotfiles#tmp` へ switch すること

### lint

- `nixfmt --check` / `shfmt -d` / `shellcheck` / sandbox の `warnings == []`

---

## 7. 移行・運用手順

### 新規マシン

```sh
# 1. 本体を ghq 配下へ
ghq get git@github.com:pollenjp/dotfiles.git

# 2. 以降はメニューから (手順 local-flake が ~/dotfiles を用意する)
"$(ghq root)/github.com/pollenjp/dotfiles/nix/scripts/setup.sh" --new-machine
```

### 既存マシン（旧レイアウトからの移行）

```sh
# 1. 本体を ghq 配下へ移す (~/dotfiles を空ける)
mkdir -p "$(ghq root)/github.com/pollenjp"
mv ~/dotfiles "$(ghq root)/github.com/pollenjp/dotfiles"

# 2. ローカル flake と setup の symlink を置く (一度だけ)
"$(ghq root)/github.com/pollenjp/dotfiles/nix/scripts/setup.sh" --steps local-flake

# 3. 以後
~/dotfiles/setup --update
```

### 日常

```sh
~/dotfiles/setup --update                            # メニュー経由
home-manager switch --flake ~/dotfiles#pollenjp@wsl  # 直接
```

---

## 8. 参考 (References)

- 前提 ADR: [dotfiles 管理を Nix home-manager へ移行する](../001_home_manager_migration_20260808T163454JST/README.md)
  - 追従の方針: **手順書として読まれる部分**（「7. 移行・運用手順」と `textbook/`）は
    本 ADR の形に更新した。読んだ人がそのまま叩けてしまうため。
    一方、**当時の決定と検証の記録**（「2. 決定」「3. 変更点の詳細」「6. 検証」）は
    `~/dotfiles/nix#...` や `isWSL` のまま残した。記録を後から書き換えると
    「そのとき何を決めて何を確かめたか」が失われるため。同 ADR の冒頭に注記した。
  - `textbook/plantuml/03_repo_layout.puml` のラベルも更新したが、
    **`out/03_repo_layout.svg` は再生成していない。** 図は `mise run plantuml:generate`
    （PlantUML 1.2026.6 固定）で作られており、手元の graphviz とフォントが違うと
    変更のない図まで差分が出る。生成環境で再実行すること。
- 運用手順: [`nix/README.md`](../../../nix/README.md)
- [Nix flake の input 形式](https://nix.dev/manual/nix/latest/command-ref/new-cli/nix3-flake.html#url-like-syntax)（`path:` と `git+file:` の違い）
- [ghq](https://github.com/x-motemen/ghq)（`ghq root` の決め方）
