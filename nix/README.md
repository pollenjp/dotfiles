# nix (home-manager)

dotfiles を Nix home-manager で宣言的に管理するためのディレクトリ。

既存の `main.bash setup` 経路とは**独立**しており、設定ファイルは `nix/files/` に複製されている。
どちらの経路を使うかはマシン単位で選ぶ。同一マシンで両方を走らせないこと。

## 対象範囲

| 対象 | 管理者 |
| --- | --- |
| dotfile 配置 | Nix home-manager |
| グローバルな CLI ツール | Nix home-manager |
| 言語ランタイム (node / go) | mise (プロジェクト毎の切替が必要なため) |
| プロジェクト毎のツール固定 | mise (`mise.toml`) |

対象 OS は **Linux / macOS / WSL**。Windows (MINGW/MSYS) は Nix が動かないため `main.bash setup` を使う。

対象シェルは **bash / fish**。zsh は Nix 管理の対象外。

## 置き場所

パスは 2 つある。**リポジトリ本体は ghq が決める場所に置き、日々の操作は
`~/dotfiles` から行う。**

| パス | 中身 | git |
| --- | --- | --- |
| `$(ghq root)/github.com/pollenjp/dotfiles` | リポジトリ本体 | 管理下 |
| `~/dotfiles` | ローカル専用の flake と `setup` への symlink | **管理外** |

本体を ghq 配下に置くのは、`cdrepo` など ghq 前提の仕組みと置き場所を揃え、
他のリポジトリと同じ規則で辿れるようにするため。一方で日々叩くパスは短く
固定したいので、`~/dotfiles` を「常にここから実行する入口」として別に用意する。

### 最初の clone

```sh
ghq get git@github.com:pollenjp/dotfiles.git
# ghq が無ければ手で置いてもよい (パスが同じであればよい)
git clone git@github.com:pollenjp/dotfiles.git ~/ghq/github.com/pollenjp/dotfiles
```

`ghq root` の既定は `~/ghq`。`GHQ_ROOT` や `git config ghq.root` で変えていれば
そちらが使われる。

### `~/dotfiles` を用意する

```sh
"$(ghq root)/github.com/pollenjp/dotfiles/nix/scripts/setup-local-flake.sh"
```

冪等。次の 2 つを置く（既にあるものは触らない）。

```
~/dotfiles/
├── flake.nix   本体を input として取り込み、homeConfigurations を再輸出する
├── flake.lock  nix が生成する
└── setup -> .../nix/scripts/setup.sh
```

以後はここから実行する。

```sh
~/dotfiles/setup                                  # メニュー
~/dotfiles/setup --update                         # 既存マシンの更新
home-manager switch --flake ~/dotfiles#pollenjp@wsl
```

> パスが違うと `setup-local-flake.sh` は止まる。意図して別の場所に置くなら
> `DOTFILES_ALLOW_ANY_PATH=1` を、`~/dotfiles` 以外に置くなら
> `DOTFILES_LOCAL_DIR` を指定する。

`~/dotfiles/flake.nix` は git 管理外なので、**このマシンにだけ要るホスト**を
足す場所にもなる（[後述](#登録簿に載せずにマシンを足す)）。足さなくても、
入口を 1 つに揃えるために常に置く。

## Nix のインストール

```sh
# 推奨: Determinate Systems 版 (flakes が最初から有効)
curl -fsSL https://install.determinate.systems/nix | sh -s -- install

# 公式版を使う場合は experimental-features を自分で有効化する
sh <(curl -L https://nixos.org/nix/install) --daemon
mkdir -p ~/.config/nix
printf 'experimental-features = nix-command flakes\n' >> ~/.config/nix/nix.conf
```

systemd の無いコンテナでは `--daemon` が失敗するので `--no-daemon` を使う。
root で single-user install する場合は `/etc/nix/nix.conf` に `build-users-group =` (空) が必要。

## 依存の更新

```sh
nix flake update --flake "$(ghq root)/github.com/pollenjp/dotfiles/nix"
```

`~/dotfiles` 側の lock は `path:` 入力を追うだけなので、更新は要らない。

> **GitHub の tarball 取得が遮断された環境について**
>
> `github:` 形式の input は `codeload.github.com` からソースを取得する。
> ネットワークポリシーでこれが遮断されている環境 (git プロトコルのみ到達可能) では
> `flake.lock` の解決はできてもソース取得で 403 になる。
> その場合は `flake.nix` を変更せず input を差し替えて評価する:
>
> ```sh
> nix flake check \
>   --override-input nixpkgs "tarball+https://channels.nixos.org/nixpkgs-unstable/nixexprs.tar.xz" \
>   --override-input home-manager "git+https://github.com/nix-community/home-manager?shallow=1"
> ```

## 適用

### まとめて実行する

次節の手順表をそのまま実行するスクリプトがある。引数なしで起動するとメニューが出る。

```sh
~/dotfiles/setup            # 用意済みならこれ (symlink)
./nix/scripts/setup.sh      # 実体。~/dotfiles を用意する前はこちら
```

```
  対象ホスト: pollenjp@wsl  (h で変更)

  ❯ 新しいマシン適用
    既存マシン更新
    カスタム
    終了
```

| 選択肢 | 実行される手順 |
| --- | --- |
| 新しいマシン適用 | 1 → 2 → 2.5 → 3 → 4 → 6 |
| 既存マシン更新 | 3 (`home-manager switch`) だけ |
| カスタム | 手順を 1 つずつチェックして選ぶ |

操作は ↑/↓ で移動、Space で選択、**Enter で実行**、q で戻る/中止。
カスタムでは `bootstrap` の行で Space を押すと配下がまとめて切り替わる。

対象ホストは `$USER` と `uname` から `hosts/default.nix` を引いて自動判定する
（WSL なら `<user>@wsl` を優先）。違うものを使うなら `h` で選び直すか `--host <名前>`。

自動化していないのは手順 0（`hosts/default.nix` への追加）と
手順 5（mise の `config.toml` 整理）だけ。手順 7 (`chsh`) は
「必要なら」なのでプリセットには入れていないが、カスタムから選べる。

メニューを出さずに実行することもできる。

```sh
~/dotfiles/setup --new-machine            # 「新しいマシン適用」と同じ
~/dotfiles/setup --update                 # 「既存マシン更新」と同じ
~/dotfiles/setup --steps switch,bootstrap-mise
~/dotfiles/setup --list                   # 手順の id 一覧
~/dotfiles/setup --new-machine --dry-run  # 走るコマンドを見るだけ
```

`~/dotfiles/setup` は実体への symlink なので、どちらから呼んでも同じ。
使う flake は `~/dotfiles/flake.nix` があればそちら、無ければリポジトリ側を指す
(既存マシンを移行するときは `--steps local-flake` を一度だけ実行する)。

Nix が入る前に走るので、依存は bash / coreutils / curl のみ
（jq も fzf も使えないのでメニューは自前描画）。
`bootstrap-*.sh` は glob で自動列挙するため、スクリプトを足しても
`setup.sh` の編集は要らない。

### 新規マシンの手順

上から順に実行する。**2 と 4 と 6 は忘れやすいので注意**（前節のスクリプトを使えば漏れない）。

| # | やること | `--steps` の id | 備考 |
| --- | --- | --- | --- |
| 0 | `hosts/default.nix` にマシンを 1 エントリ追加 | — | WSL なら `wsl = { ... }` も（[後述](#マシン登録簿-hostsdefaultnix)） |
| 1 | Nix を入れる（前節） | `nix-install` | |
| 2 | `./nix/scripts/preflight-unlink.sh` | `preflight-unlink` | `main.bash setup` 済みのマシンのみ |
| 2.5 | `./nix/scripts/setup-local-flake.sh` | `local-flake` | `~/dotfiles` を用意する（[前述](#置き場所)） |
| 3 | `nix run ~/dotfiles#home-manager -- switch --flake ~/dotfiles#<host>` | `switch` | 初回はこの形 |
| 4 | `./nix/scripts/bootstrap-mise.sh` | `bootstrap-mise` | mise のグローバル設定と言語ランタイム |
| 5 | `~/.config/mise/config.toml` を手で整理 | — | 既存マシンのみ（後述） |
| 6 | `./nix/scripts/bootstrap-claude-hook.sh` | `bootstrap-claude-hook` | Claude Code のガードフック登録 |
| 7 | `chsh` でログインシェルを変更 | `chsh` | 必要なら |

#### 1. 初回のブートストラップ (手順 3)

**`home-manager` コマンドはまだ存在しない。** `programs.home-manager.enable` が CLI を
profile へ入れるのは *初回の activate が成功した後* なので、1 回目は flake から直接実行する。

```sh
nix run ~/dotfiles#home-manager -- switch --flake ~/dotfiles#pollenjp@wsl
```

> ⚠️ `nix run home-manager -- ...` (レジストリ経由) は使わないこと。
> nixpkgs 同梱の別バージョンが実行され、`flake.lock` で固定した home-manager
> モジュールとバージョンがずれる。上の `~/dotfiles#home-manager` なら
> lock と同じバージョンが使われる。

`#` の後ろは `nix/hosts/default.nix` の登録名。

#### 2. mise の初期化 (手順 4)

```sh
./nix/scripts/bootstrap-mise.sh
```

`~/.config/mise/config.toml` は **Nix 管理下に置いていない**（mise が実行時に書き換える
ファイルなので store に置けない）。そのため `home-manager switch` だけでは作られず、
**新規マシンでは go / node が入らないまま**になる。このスクリプトで初期化する。

冪等なので何度実行してもよい。詳細は後述の「mise との役割分担」を参照。

#### 3. ログインシェルの変更 (手順 7)

`programs.fish.enable` は fish を**インストールするだけ**で、ログインシェルには設定しない
（`/etc/passwd` の変更は home-manager の管轄外）。必要なら手で変更する。

```sh
command -v fish | sudo tee -a /etc/shells
chsh -s "$(command -v fish)"
```

### 2 回目以降

初回の activate が終われば `~/.nix-profile/bin/home-manager` が入るので、
以後は短く書ける。

```sh
home-manager switch --flake ~/dotfiles#pollenjp@wsl
```

`~/dotfiles/setup --update`（メニューの「既存マシン更新」）でも同じことをする。
ホスト名を覚えていなくてよいのでこちらが楽。

**`command not found` になる場合**は `~/.nix-profile/bin` が PATH に無い。
Nix インストーラが用意する profile スクリプトを読み込む (ログインし直すか、以下を実行):

```sh
. ~/.nix-profile/etc/profile.d/nix.sh    # single-user install
. /etc/profile.d/nix.sh                  # multi-user install
```

シェル設定を home-manager が持つ Stage 5 以降は、この PATH 設定も宣言的に入る。

## マシン登録簿 (hosts/default.nix)

1 エントリが 1 マシン。マシンごとの差は `mkHome` に渡す値で吸収する。

| 引数 | 既定 | 用途 |
| --- | --- | --- |
| `username` | (必須) | Linux / macOS 側のユーザー名。`$USER` と一致しないと activate が中断する |
| `system` | (必須) | `x86_64-linux` / `aarch64-linux` / `aarch64-darwin` |
| `homeDirectory` | `/home/<username>`（darwin は `/Users/<username>`） | 検証用に逃がしたいときだけ指定する |
| `wsl` | `{ }` | WSL 固有の設定（下記）。省略すれば非 WSL マシン |

### WSL 固有の設定は入れ子で渡す

`wsl` は入れ子の attrset で、**親が有効なときだけ子が意味を持つ**という関係を
そのまま構造にしてある。平坦なフラグの並びだと「どの組み合わせが有効なのか」が
読み取れないため。

```nix
wsl = {
  enable = true;              # WSL か
  onePassword = {
    enable = true;            # ホスト側 Windows の 1Password を使うか (WSL 専用)
    windowsUserName = "polle"; # その 1Password のパスに要る Windows ユーザー名
  };
};
```

有効な組み合わせは次の 3 通りだけになる。

| マシン | 指定 | git の署名 |
| --- | --- | --- |
| 非 WSL | `wsl` を書かない | 署名の設定を書き出さない |
| WSL / 1Password 無し | `wsl.enable = true;` | 同上 |
| WSL / 1Password 有り | 上のブロックまるごと | Windows 側の `op-ssh-sign-wsl.exe` を経由して署名する |

登録簿では `pollenjp@wsl`（1Password 有り）と `pollenjp@wsl-no-1password`（無し）が
これに当たる。適用時に `#` の後ろで選ぶ。

```sh
home-manager switch --flake ~/dotfiles#pollenjp@wsl
home-manager switch --flake ~/dotfiles#pollenjp@wsl-no-1password
```

`setup.sh` の自動判定は WSL なら `<user>@wsl`（= 1Password あり）を選ぶ。
1Password の無いマシンではメニューの `h` で選び直すか、
`--host pollenjp@wsl-no-1password` を渡す。

> 1Password を使わないマシンで署名設定を書き出さないのは、`commit.gpgSign = true`
> だけが残ると署名鍵が見つからず `git commit` そのものが失敗するため。
> 「署名しない」も正当な構成として扱っている。

`windowsUserName` の値は WSL 上で次を実行すると判る（Nix の評価は純粋なので
自動取得はできない。`getEnv` や `--impure` は `nix flake check` を壊す）。

```sh
pwsh.exe -NoProfile -Command '$env:USERNAME'
```

階層で表現しきれない「親が false なのに子が true」は `assertions` で評価時に止まる。

- `wsl.onePassword.enable` が true なのに `wsl.enable` が false
- `wsl.onePassword.enable` が true なのに `windowsUserName` が無い

### 登録簿に載せずにマシンを足す

一時的な環境など、`hosts/default.nix` を編集したくない・git で管理したくない場合は
`~/dotfiles/flake.nix` に足す。[置き場所](#置き場所)で用意したものがそのまま使える。

```nix
homeConfigurations = dotfiles.homeConfigurations // {
  tmp = dotfiles.lib.mkHome {
    username = "pollenjp";
    system = "x86_64-linux";
    wsl.enable = true;

    # このマシンだけの設定は modules で渡す。
    # 本体が既に定義している値を差し替えるには mkForce が要る
    # (同じ優先度の定義が 2 つあると "conflicting definition values" で落ちる)。
    modules = [
      (
        { lib, ... }:
        {
          programs.git.settings.user.email = lib.mkForce "tmp@example.com";
        }
      )
    ];
  };
};
```

```sh
home-manager switch --flake ~/dotfiles#tmp
```

`dotfiles.homeConfigurations // { ... }` としているので、登録簿のホストも同じ場所から
引ける。`~/dotfiles#pollenjp@wsl` と `~/dotfiles#tmp` が並ぶ。

生成される雛形にはこの例がコメントで入っている。`lib.mkHome` を公開しているのは
このためで、引数は[登録簿](#マシン登録簿-hostsdefaultnix)と同じ。

#### なぜリポジトリの中に置かないのか

`hosts/local.nix` を gitignore して置く手も考えられるが、**見えるかどうかが
flake の指し方で変わる**ので採らない。

| 指し方 | 解決方法 | 追跡していないファイル |
| --- | --- | --- |
| `--flake <repo>/nix` | git リポジトリ内のパスなので **git 解決** | 見えない |
| `--flake ~/dotfiles`（`path:` 経由） | ディレクトリをそのまま複製 | 見える |

同じ定義が経路によって在ったり無かったりするうえ、CI は前者なので手元だけ通る。
`~/dotfiles` は git 管理外なので、この食い違いが起きない。

なお後者の性質のおかげで、**本体を編集したら commit しなくてもそのまま試せる**
（lock も評価のたびに追随するので `nix flake update` は要らない）。
その代わり commit 忘れは CI で出る。

#### 使い捨ての 1 回きり

ファイルを残したくなければ `--impure` で直接組み立てる。

```sh
nix build --impure --expr '
  ((builtins.getFlake "path:'"$(ghq root)"'/github.com/pollenjp/dotfiles/nix").lib.mkHome {
    username = "tmp";
    system = "x86_64-linux";
    wsl.enable = true;
  }).activationPackage' -o /tmp/hm
/tmp/hm/activate
```

## 日常運用

```sh
# 何が配置されるかを $HOME に触れず確認する
nix build ~/dotfiles#homeConfigurations.'"pollenjp@wsl"'.activationPackage -o /tmp/hm
find -L /tmp/hm/home-files -mindepth 1 -maxdepth 3   # home-files は symlink なので -L 必須

# 適用 (既存ファイルは .bak へ退避)
home-manager switch --flake ~/dotfiles#pollenjp@wsl -b bak

# 世代一覧とロールバック
home-manager generations
/nix/store/<older>-home-manager-generation/activate

# 依存の更新 (本体の flake.lock を触るのでリポジトリ側を指す)
nix flake update --flake "$(ghq root)/github.com/pollenjp/dotfiles/nix"
```

> ⚠️ `-b bak` は `<file>.bak` が既に存在すると失敗する。リトライ時は古い `.bak` を先に消すこと。

## 管理対象のファイル

| 配置先 | 実体 |
| --- | --- |
| `~/.config/starship.toml` | `nix/files/starship.toml` |
| `~/.config/zellij/config.kdl` | `nix/files/zellij/config.kdl` |
| `~/.config/nvim/init.vim` | `nix/files/nvim/init.vim` |
| `~/.config/tmux/interactive_shell.tmux.conf` | `nix/files/tmux/interactive_shell.tmux.conf` |
| `~/.tmux.conf` | `nix/files/tmux/home.tmux.conf` |
| `~/.screenrc` | `nix/files/screenrc` |
| `~/.vimrc` | `nix/files/vim/vimrc` |
| `~/.vim/{common,clipboard}.vim` | `nix/files/vim/` |
| `~/.config/git/config` | `nix/home/modules/git.nix` (生成) |
| `~/.config/git/ignore` | 同上 (`programs.git.ignores`) |

複製時に `~/dotfiles/...` への参照を書き換えている（store 管理では解決できないため）。

| 元の記述 | 書き換え後 |
| --- | --- |
| `source ~/dotfiles/vim_common/common.vim` | `source ~/.vim/common.vim` |
| `source-file ~/dotfiles/tmux/home.tmux.conf` | `source-file ~/.tmux.conf` |

## git について

`programs.git` で `~/.config/git/config` を **生成** している（素のファイル配置ではない）。
目的は 1Password `op-ssh-sign` のパスで、従来は WSL 用と Windows 用がコメントアウトで
並んでおり手で切り替える運用だった。これを登録簿の指定による分岐に置き換えている。

署名まわりは `dotfiles.wsl.onePassword.enable` で丸ごと切り替わる
（マシンごとの指定は[マシン登録簿](#マシン登録簿-hostsdefaultnix)を参照）。

| 生成される項目 | 有効 | 無効 |
| --- | --- | --- |
| `commit.gpgSign` / `tag.gpgSign` | `true` | 書き出さない |
| `gpg.format` | `ssh` | 書き出さない |
| `gpg.ssh.defaultKeyCommand` | ssh-agent の鍵から `Signing` を含むものを選ぶ | 書き出さない |
| `gpg.ssh.program` | Windows 側の `op-ssh-sign-wsl.exe` | 書き出さない |

`defaultKeyCommand` は 1Password が鍵に付ける名前で引くものなので、1Password の
無いマシンでは当たらない。片方だけ残すと「署名しようとして鍵が見つからず commit が
失敗する」状態になるため、無効のマシンでは署名設定を丸ごと省いている。

**署名が入るのは `wsl.onePassword.enable = true` のマシンだけ**になる。1Password は
WSL 専用の設定として `dotfiles.wsl` の下に置いているため、非 WSL のマシン
（`pollenjp@x86_64-linux` / `aarch64-linux` / `aarch64-darwin`）には署名設定が入らない。
これらでも 1Password で署名したくなったら、`onePassword` を `dotfiles.wsl` の外へ
出して `windowsUserName` を WSL のときだけ要求する形にする。

> ⚠️ **`~/.gitconfig` の symlink は必ず外すこと。**
> git は `~/.config/git/config` を読んだ **後に** `~/.gitconfig` を読むため、
> `main.bash` が張った symlink が残っていると home-manager の設定を黙って上書きする。
> `preflight-unlink.sh` が対象に含めている。

**`git config --global` は使えなくなる。** 書込先の `~/.config/git/config` が store 上の
read-only ファイルになるため。マシン固有の設定を足したい場合は `~/.gitconfig` を作れば
よい（git の読み込み順により home-manager の設定を上書きできる）。

## fish

`.fish/*.fish` (17 ファイル / 610 行) は `nix/home/modules/fish.nix` へ**全面移植**した。
レガシー側の数字プレフィックスによる読み込み順制御はやめ、役割別に整理してある。
順序が本質的に効くもの (PATH の前置、mise activate、starship init) だけを
`interactiveShellInit` の並び順で表現している。

内訳: abbr 88 個 / function 24 個 / `interactiveShellInit`。

**fisher は不要になった。** `programs.fish.plugins` が `fishPlugins.autopair` と
`fishPlugins.fzf-fish` を宣言的に入れるため、curl でのインストーラ取得と日次
`fisher update` が消える。`~/.config/fish/fish_plugins` も不要。

平坦化で判明した重複 (レガシーでは読み込み順で後勝ちだった):

| 名前 | 先に定義 | 後に定義 (採用) |
| --- | --- | --- |
| `f` | `201_git` の `git fetch` | `250_alias` の `cd ..` |
| `ls` | `060_mise` の `eza` | `250_alias` の `eza --group-directories-first -F` |

## bash

`.bashrc` / `.bash/*.sh` / `shell/*.sh` を `nix/home/modules/bash.nix` へ全面移植した。
内訳: alias 88 個 / 関数 24 個 / `initExtra`。

**`main.bash:199-219` の bash-completion 取得が不要になった。**
curl + tar で bash-completion 2.11 を落として `~/.bashrc` にローダ行を追記していたが、
`programs.bash.enableCompletion` が置き換える。

`~/.common_shellrc.sh` の source は維持している（マシンローカルの逃げ道）。

### bash で壊れていたものを移植時に修正

| 対象 | 症状 |
| --- | --- |
| `c` | `alias c='noglob c-func'` の `noglob` は zsh 専用。bash では `noglob: command not found` で失敗していた |
| `cdrepo` | ガードが fish 構文の `if not command -v ghq` で書かれており、bash では `not` が見つからず終了ステータス 127 = 常に偽。一度も発火しない死んだコードだった |
| ssh-agent | `ssh-add` の存在確認が無く、未インストール環境では起動のたびにエラーが出ていた |

### 挙動が変わる点

- **bash でも starship プロンプトになる。** レガシーでは starship を初期化しているのは
  fish だけで、bash は素のプロンプトだった。両シェルで揃えている。
  戻したい場合は `starship.nix` の `enableBashIntegration` を `false` にする。
- `glog` などの alias 連鎖（`glog='glo --graph'`）は完全形に展開した（fish 側と同じ形）。
- `echo-PATH` / `echo-PATH-tr` / `echo-PATH-grep` / `git_get_default_branch` は
  alias から関数に変えた（動作は同じ）。

### 移植しなかったもの

`025_mingw` と `205_go_path` の cygpath 分岐（Windows は対象外）、`.bash/02_asdf.sh`
（asdf は使われていない）、`050_common` の `bindkey -v`（zsh 専用のガード付きで
bash では元々発火していなかった）。

## Claude Code

`nix/files/claude/` 配下を `~/.claude/` へ配置する。

| 配置先 | 実体 | 単位 |
| --- | --- | --- |
| `~/.claude/CLAUDE.md` | `nix/files/claude/CLAUDE.md` | ファイル |
| `~/.claude/skills/<名前>/` | `nix/files/claude/skills/<名前>/` | ディレクトリ |
| `~/.claude/agents/<名前>.md` | `nix/files/claude/agents/<名前>.md` | ファイル |
| `~/.claude/commands/<名前>.md` | `nix/files/claude/commands/<名前>.md` | ファイル（サブディレクトリで名前空間も可） |

`nix/home/modules/claude.nix` が各ディレクトリを `readDir` で自動列挙するので、
**追加するときに `.nix` を編集する必要はない**（`README.md` は除外される）。
書き方は各ディレクトリの `README.md` を参照。

### なぜディレクトリごとではなく中身を 1 つずつ symlink するのか

`~/.claude/` 配下は **Claude Code 自身が書き換える**。`skills/` には `manifest.json`
があり、Anthropic 配信の skill（`pdf` / `docx` / `xlsx` / `pptx` など）がここへ入る。
ディレクトリごと store の symlink にすると、それらの導入・更新が壊れる。

中身を 1 つずつ配置すれば、Claude Code 管理のものと**兄弟として並ぶ**だけで衝突しない。

```
~/.claude/skills/
├── manifest.json      <- Claude Code 管理 (実ファイル)
├── pdf/  docx/  ...   <- Claude Code 管理 (実ディレクトリ)
└── my-skill -> /nix/store/…   <- Nix 管理
```

### ⚠️ `~/.claude/` を直接編集しないこと

store 上の read-only ファイルへの symlink なので、編集は実行ユーザーによって
**壊れ方が違う**。

| 実行者 | 直接編集した場合 |
| --- | --- |
| 一般ユーザー | `Permission denied`（明確に失敗する） |
| **root** | **黙って成功し store が破損する**（`nix store verify` が hash 不一致を検出。変更は次の GC やリビルドで失われ、エラーも出ない） |

正しい手順はリポジトリ側を編集して `home-manager switch`。

これを Claude に伝えるため、`PreToolUse` フック
（`nix/files/claude/hooks/nix-managed-guard.sh`）を用意している。
**該当パスを編集しようとしたときだけ**介入し、正しい手順を返して拒否する。

判定はパス名のパターンではなく **解決先が `/nix/store` 配下かどうか**で行う。
そのため次は誤って止めない。

- `~/.claude/skills/manifest.json`（Claude Code 管理の実ファイル）
- `~/.claude/skills/pdf/`（Anthropic 配信 skill）
- `~/.claude/skills/<試作>/`（直接置いて試行錯誤している最中のもの）
- 読み取り（`Read` / `cat` / `ls`）

`~/.claude/CLAUDE.md` にも同じ趣旨を**3行だけ**書いてある。全セッションで
読まれてトークンを消費するので、詳細はフック側に持たせている。

#### フックの登録（マシンごとに一度だけ）

```sh
./nix/scripts/bootstrap-claude-hook.sh
```

フックの定義は `settings.json` にしか書けないが、そのファイルは Claude Code
自身が書き換える（権限の「常に許可」など）ため Nix 管理下に置けない。
**スクリプト本体だけを Nix が配置し、登録はこのコマンドで行う。**
冪等で、既存の設定は保持する。

### 管理しないもの

`settings.json`（権限の「常に許可」などで書き換わる）、`skills/manifest.json` と
Anthropic 配信 skill、`plugins/`、実行時の状態（`projects/` `sessions/` など）。

## mise との役割分担

| 対象 | 管理者 |
| --- | --- |
| グローバルな CLI ツール | Nix (`home/modules/packages.nix`) |
| 言語ランタイム (go / node) | mise |
| プロジェクト毎のツール固定 | mise (`mise.toml`) |

Nix が CLI ツールを持つ環境では、レガシー経路の起動時パッケージ注入を止める必要がある。
その合図に `~/.local/state/dotfiles/package-manager` というマーカーファイルを使っている
（内容は `nix`）。配置するのは `nix/home/modules/mise.nix`。

このマーカーがあると次が停止する。**マーカーが無い環境の挙動は従来どおり。**

- `shell/060_mise.sh` / `.fish/060_mise.fish` の `sed -i` によるパッケージ注入と `mise install`
- `shell/252_alias_mise.sh` / `.fish/252_alias_mise.fish` の日次バージョン pin

### `~/.config/mise/config.toml` は Nix 管理下に置かない

mise が実行時に書き換えるファイルなので store には置けない。設定の投入も
mise 自身のコマンドで行う（config.toml は mise のスキーマであり、Nix 側に
スナップショットを持たせると形式変更への追随が必要になるため）。

**新規マシンではマシンごとに一度だけ実行する:**

```sh
./nix/scripts/bootstrap-mise.sh
```

`[settings]`（`minimum_release_age` / `lockfile` / `fetch_remote_versions_timeout`）と
言語ランタイム（`go` / `node` / `usage`）を入れる。`mise settings set` は該当キーだけを
触るので冪等で、既存の `[tools]` も壊さない。

> ⚠️ `.config_tmpl/mise/config.toml`（レガシー側のテンプレート）にある `install_before` は
> 現在の mise では **`minimum_release_age` に改名**されている。旧名は
> `mise settings ls --all` に存在せず、`mise settings set` してもエラーにならず
> **黙って無視される**。テンプレート側は以前から効いていなかった可能性が高い。

> ネットワークアクセスとインストールを伴うため `home.activation` には入れていない。
> `home-manager switch` は hermetic に保つ方針。

> ⚠️ **既存マシンでは、既に書き込まれた 16 エントリが自動では消えない。**
> マシン毎に一度だけ `~/.config/mise/config.toml` を手で編集し、`go` / `node` / `usage`
> だけ残すこと。消さないと mise の shim が PATH 先頭にいるため Nix 側のツールが使われない。

## CI

`.github/workflows/nix.yml` が `nix/**` の変更時に走る。

| ジョブ | ランナー | 内容 |
| --- | --- | --- |
| `check (x86_64-linux)` | ubuntu-latest | 全 system の評価 → x86_64-linux のビルド → sandbox への activate と冪等性 → `warnings` が空か |
| `check (aarch64-darwin)` | macos-latest | aarch64-darwin のビルド |
| `lint` | ubuntu-latest | `nixfmt --check` / `shfmt -d` / `shellcheck` |

`aarch64-linux` はランナーが無いので**評価のみ**（`--all-systems --no-build`）。
オプション名の誤りやプラットフォーム分岐の壊れはこれで捕まる。

ローカルで同じことをするには `./nix/scripts/verify.sh` を使う。

## 検証

```sh
./nix/scripts/verify.sh
```

`nix flake check` → sandbox ビルド → 配置ファイル一覧 → 使い捨て `$HOME` への activate →
冪等性確認 → `~/dotfiles` 参照の残留チェック、までを一括で行う。実際の `$HOME` には触れない。

個別に実行する場合:

```sh
cd "$(ghq root)/github.com/pollenjp/dotfiles/nix"
git add .                                  # git 解決なので untracked は見えない (後述)

nix flake check                            # 現在の system 向けに評価 + ビルド
nix flake check --all-systems --no-build   # 全 system を評価のみ (CI 向け)

# 配置されるファイルを事前に確認する
nix build '.#homeConfigurations."pollenjp@wsl".activationPackage' -o /tmp/hm
find -L /tmp/hm/home-files -mindepth 1     # ★ home-files は symlink なので -L が必須
```

## ディレクトリ

```
nix/
├── flake.nix              inputs / homeConfigurations / checks / formatter / devShells
├── lib/mk-home.nix        homeConfiguration 組み立てヘルパ
├── hosts/default.nix      マシン登録簿
├── home/
│   ├── default.nix        import 一覧 + stateVersion
│   ├── options.nix        dotfiles.wsl.{enable,onePassword.{enable,windowsUserName}}
│   └── modules/
│       ├── packages.nix      programs.* を使わない CLI ツール
│       ├── files.nix         静的な設定ファイルの配置
│       ├── git.nix           programs.git / programs.delta
│       ├── starship.nix      programs.starship (設定は素のファイルのまま)
│       ├── mise.nix          mise 抑止マーカー
│       ├── shell-common.nix  bash/fish 共通 (sessionVariables / sessionPath / mise)
│       ├── fish.nix          abbr 88 / function 24
│       └── bash.nix          alias 88 / 関数 24
├── files/                 既存設定の複製 (store 管理される素のファイル)
└── scripts/
    ├── setup.sh                   「適用」の手順を選んで実行する (入口)
    ├── setup-local-flake.sh        ~/dotfiles にローカル flake と setup の symlink を置く
    ├── verify.sh                   検証を一括実行する
    ├── preflight-unlink.sh         main.bash が張った symlink を外す (移行時に 1 回)
    ├── bootstrap-mise.sh           mise のグローバル設定を初期化する (マシンごとに 1 回)
    └── bootstrap-claude-hook.sh    Claude Code のフックを登録する (マシンごとに 1 回)
```
