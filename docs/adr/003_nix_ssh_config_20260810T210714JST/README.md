# ADR: ssh の設定を Nix 管理に載せる範囲を決める

| 項目 | 内容 |
| --- | --- |
| ステータス | 提案 (Proposed) — レビュー中 |
| 日付 | 2026-08-10 (JST) |
| 決定者 | pollenjp |
| 関連 PR | [#32](https://github.com/pollenjp/dotfiles/pull/32) |
| 前提 ADR | [001_home_manager_migration](../001_home_manager_migration_20260808T163454JST/README.md) / [002_nix_hosts_and_local_flake](../002_nix_hosts_and_local_flake_20260810T153848JST/README.md) |
| 後続 ADR | [004_nix_wsl_ssh_wrapper](../004_nix_wsl_ssh_wrapper_20260811T124616JST/README.md)（本 ADR が触れていない WSL 用 `bin/ssh-*-wsl.sh` の扱いを決めた。本文の決定は変えていない） |
| 運用手順 | [`nix/README.md`](../../../nix/README.md)（日常運用はこちら） |

---

## 1. 背景 (Context)

ssh だけが Nix 経路の**管理外**に取り残されていた。

`~/.ssh/config` への `Include` 行は `main.bash setup` が**追記**しており、
Nix 経路だけで構築したマシンには何も入らない。

```
main.bash:   ~/.ssh/config に `Include ~/dotfiles/ssh_config` を追記
ssh_config:  Include ~/dotfiles/.ssh/*.ssh_config   <- .ssh submodule (private repo)
             Include ~/.ssh/config.d/*.ssh_config   <- マシン固有
```

追記方式なので「このマシンでは済んでいるか」がファイルを見ないと判らない。
また、旧経路を畳むと `ssh_config` ごと消えるため、`.ssh` submodule を
`~/.ssh/config` へ繋ぐものが無くなる。

## 2. 決定 (Decision)

### A. 骨組みだけ Nix、中身はスクリプト

`programs.ssh` が生成するのは `Include` 1 行だけにする。

```
Include config.d/*.ssh_config
```

（`ssh` は相対パスの `Include` を `~/.ssh/` 基準で解決するので
`~/.ssh/config.d/*.ssh_config` を指す）

中身は `nix/scripts/setup-ssh-config.sh` が `.ssh` submodule から
`~/.ssh/config.d/` へ symlink する。

**中身を Nix で配らない理由:**

1. **`/nix/store` は誰でも読める。** 接続先ホスト名・ユーザー名・踏み台の構成を
   store に置きたくない。store のファイルは 444 なのでパーミッションでも隠せない。
2. 実体は `.ssh` submodule にあり **flake root (`nix/`) の外**なので、
   そもそも flake から読めない。

骨組みが Nix 管理になることで、「`Include` 行が入っているか」をマシンごとに
気にしなくてよくなる。これが追記方式に対する主な改善。

### B. 既存 `~/.ssh/config` の退避は `--backup` に一本化する

`main.bash` の追記方式のせいで `~/.ssh/config` は実ファイルとして残っている
ことが多く、home-manager は `Existing file '...' would be clobbered` で
switch ごと中断する。

この退避は **`setup.sh` の `-b` (`--backup`) に任せる**。`~/.bashrc` などと
同じ扱いにして、「switch を邪魔する既存ファイル」の退き方を 1 つにする。

そのために `setup.sh` の `hm_managed_paths` へ `.ssh/config` を追加した。
これが無いと `clobber_paths()` が検出せず、指定が無いときにメニューが訊いて
くれない（黙って switch が落ちる）。

退避先 `~/.ssh/config.backup` は **Include されないので設定としては効かない**。
残したい `Host` ブロックは中身を見てから `~/.ssh/config.d/` へ手で移す。

## 3. 変更点の詳細 (What changed)

| ファイル | 変更 |
| --- | --- |
| `nix/home/modules/ssh.nix` | 新規。`programs.ssh` で Include の骨組みを生成 |
| `nix/home/default.nix` | 上を import |
| `nix/scripts/setup-ssh-config.sh` | 新規。submodule を `~/.ssh/config.d/` へ張る |
| `nix/scripts/setup.sh` | 手順 `ssh-config` を追加。`hm_managed_paths` に `.ssh/config` |
| `nix/scripts/preflight-unlink.sh` | 対象に `~/.ssh/config`（symlink の場合用） |
| `nix/README.md` | 「ssh について」節 |

### `enableDefaultConfig = false`

従来の `~/.ssh/config` には `Include` 行しか無く、`ForwardAgent` や
`ControlMaster` などの既定値は入っていなかった。挙動を変えないために切る。

未指定だと deprecation の warning が出る。CI は sandbox の `warnings` が空で
あることを確認しているので、未指定のままだと落ちる。

### `setup-ssh-config.sh` の位置

`bootstrap-*.sh` の枠（glob 自動列挙）には入れず、`setup.sh` の手順として
`switch` の手前に置いた。「新しいマシン適用」「既存マシン更新」の両方に入る。

後者にも入れたのは、`.ssh` submodule を更新したときに `~/.ssh/config.d/` を
張り直す必要があり、冪等で副作用も無いため。

> 決定 B の前は「実ファイルの `~/.ssh/config` を退避する」役目があったので
> `switch` より前であることが**必須**だった。B によってその制約は消えたが、
> switch 直後から ssh を引けるようにしたいので位置は変えていない。

## 4. 検討した代替案 (Alternatives considered)

### A-1. `.ssh` submodule の中身を Nix で配る

flake root の外なので不可能。仮に `nix/` 配下へ移しても、`/nix/store` が
誰でも読める以上、private な接続情報を置く先としては不適当。

### A-2. `~/.ssh/config` を Nix 管理にせず、従来どおり追記で済ませる

現状維持。「済んでいるか判らない」という元の問題が残る。

### B-1. 旧 `~/.ssh/config` を `~/.ssh/config.d/00-local.ssh_config` へ移す

**一度これで実装したが、やめた。** `Include` 経由でそのまま効かせられるので
移行が滑らかに見えたが、2 つの問題があった。

1. `config.d` は Include されるので、**移した瞬間から設定として生き続ける**。
   中身を見直す機会が無いまま旧い設定が黙って残る。
2. `00-` 始まりで最初に読まれる。`ssh` は同じキーワードについて**最初に得た値**を
   採るので、**旧い設定が submodule の設定を上書き**する。

2 は実測した（[検証](#6-検証-verification)）。移行のための退避先が
「最優先の設定」になるのは筋が悪い。

> 検討の過程で「移した旧 config に残る `Include ~/dotfiles/ssh_config`
> （新レイアウトでは存在しないパス）が ssh を壊すのでは」とも考えたが、
> **これは外れ**だった。OpenSSH は存在しない Include を黙って無視する。
> 判断材料にしていないが、記録として残す。

### B-2. `setup.sh` の `switch` に常に `-b` を付ける

退避ファイルが増えるのを嫌う人もいるため、`setup.sh` は既定を決め打ちにせず
メニューで訊く方針を採っている（別途決定済み）。ssh だけ例外にする理由は無い。

## 5. 影響 (Consequences)

### 良くなること

- Nix 経路だけで構築したマシンでも ssh の設定が入る
- 「`Include` 行が入っているか」をマシンごとに気にしなくてよい
- `.ssh` submodule を更新したら `--update` で `~/.ssh/config.d/` が追随する
- switch を邪魔する既存ファイルの退き方が 1 つになった

### 注意が必要なこと

- **`~/.ssh/config` が Nix 管理（store への symlink）になる。** 手で編集できなく
  なるので、マシン固有の設定は `~/.ssh/config.d/` に置く。`git.nix` で
  `~/.config/git/config` を生成しているのと同じ形。
- **`--backup` で退避した設定は効かなくなる。** `~/.ssh/config.backup` は誰も
  Include しない。残したい `Host` は手で `config.d/` へ移す必要がある。
- **`config.d` のファイル名順が優先順位になる。** `ssh` は最初に得た値を採る。
- リポジトリ直下の `ssh_config` と `bin/ssh-*-git-for-win.sh` は Windows 経路が
  使うので残している。Windows を畳むときに一緒に消す。

## 6. 検証 (Verification)

環境の制約で `codeload.github.com` が 403 になるため、`nix/README.md` 記載の
input 差し替え（`--override-input`）で実行している。

### Include 連鎖が実際に効くか

`ssh -G` で実効値を確認した。

| 引いたホスト | 結果 | 出所 |
| --- | --- | --- |
| `github.com` | `user git` / `identitiesonly yes` | `10-github.ssh_config` |
| `bastion` | `hostname 10.0.0.1` / `port 2222` | `20-bastion.ssh_config` |

> **OpenSSH は `$HOME` ではなく passwd の home を見る。** サンドボックスの
> `HOME` を差し替えただけでは設定が読まれず、最初は「Include が効かない」と
> 誤検知した。実 home で測り直している。

### 代替案 B-1 を棄却した根拠

`config.d/00-local.ssh_config` に `Host github.com / User LEGACY-STALE`、
`config.d/10-github.ssh_config` に `User git` を置いて `ssh -G github.com`
を引くと **`LEGACY-STALE`** が返る。退避先が submodule の設定を上書きする。

存在しない `Include` については、`Include ~/dotfiles/ssh_config`（実在しない）を
含む状態で `ssh -G` が `exit 0` / stderr なしで通ることを確認した。

### 退避の動作

- `setup-ssh-config.sh` が `~/.ssh/config` を実ファイルのまま残すこと
- `HOME_MANAGER_BACKUP_EXT=backup` での activate が `exit 0` で通り、
  旧 config が `~/.ssh/config.backup` へ退くこと
- `~/.ssh/config.d/` には submodule 由来のものだけが残ること
- `clobber_paths()` が `~/.ssh/config` を検出すること

### スクリプトの冪等性と安全性

- 2 回目以降も同じ結果になること
- 手で置いた `50-manual.ssh_config` に触らないこと
- submodule からファイルを消すと、その symlink だけ外れること
- submodule 未取得でも処理を止めないこと（警告のみ）
- `~/.ssh` と `config.d` が 700 になること

### 全体

- `nix flake check --all-systems --no-build` 24 件通過 / sandbox の `warnings == []`
- `nixfmt --check` / `shfmt -d` / `shellcheck`
- `setup.sh` の手順順序が `local-flake` → `ssh-config` → `switch` になること
- `--backup` 併用と `--help` が壊れないこと

## 7. 移行・運用手順

```sh
# submodule を取得していなければ
git -C ~/ghq/github.com/pollenjp/dotfiles submodule update --init .ssh

# 既存の ~/.ssh/config がある場合は退避しながら適用する
~/dotfiles/setup --update --backup

# 退避された設定に残したい Host があれば手で移す
$EDITOR ~/.ssh/config.backup
$EDITOR ~/.ssh/config.d/50-local.ssh_config

# 実効値の確認
ssh -G <ホスト名>
```

`.ssh` submodule を更新したあとは `~/dotfiles/setup --update` で
`~/.ssh/config.d/` が張り直される。

## 8. 参考 (References)

- 運用手順: [`nix/README.md` 「ssh について」](../../../nix/README.md#ssh-について)
- [ssh_config(5)](https://man.openbsd.org/ssh_config) — `Include` の解決規則と
  「最初に得た値を採る」規則
- home-manager `programs.ssh`（`includes` / `enableDefaultConfig`）
