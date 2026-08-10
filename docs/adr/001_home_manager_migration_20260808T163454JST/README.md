# ADR: dotfiles 管理を Nix home-manager へ移行する

| 項目 | 内容 |
| --- | --- |
| ステータス | 実装中 (Accepted / In progress) — Stage 1-3 はマージ済み、Stage 4-5 はレビュー中 |
| 日付 | 2026-08-08 (JST) / 最終更新 2026-08-09 |
| 決定者 | pollenjp |
| 関連 PR | [#18](https://github.com/pollenjp/dotfiles/pull/18) Stage 1-3 (**merged**) / [#19](https://github.com/pollenjp/dotfiles/pull/19) Stage 4 / [#20](https://github.com/pollenjp/dotfiles/pull/20) Stage 5-1 fish / [#21](https://github.com/pollenjp/dotfiles/pull/21) Stage 5-2 bash |
| 補足資料 | [textbook/](./textbook/README.md)（新規参画者向けの解説） |
| 運用手順 | [`nix/README.md`](../../../nix/README.md)（日常運用はこちら） |
| 後続 ADR | [002_nix_hosts_and_local_flake_20260810T153848JST](../002_nix_hosts_and_local_flake_20260810T153848JST/README.md) — マシン固有設定の表現と実行の入口パスを決めた。**「7. 移行・運用手順」と `textbook/` は現行の形に更新済み。**「2. 決定」「3. 変更点の詳細」「6. 検証」に出てくる `~/dotfiles/nix#...` や `isWSL` などは決定当時の記録としてそのまま残してある |

---

## 1. 背景 (Context)

これまでの dotfiles は独自スクリプト `./main.bash setup` によって配置していた。加えて、実行時のパッケージ管理は **シェル起動のたびに** `mise` の設定ファイルを書き換える方式だった。

### 現状（変更前）の構造

![変更前アーキテクチャ](./plantuml/out/01_before.svg)

### 課題

1. **配置が手続き的で検証できない**
   `main.bash:66-103` の `file_pairs` 配列を `ln -s` するだけで、「今何がどこに配置されているか」「適用前に何が変わるか」を確認する手段がない。さらに `Makefile` の `clean` は 13 個ある配置先のうち 4 個しか `unlink` しないため、**確実なアンインストール経路が存在しない**。

2. **パッケージ管理がシェル起動毎の破壊的変更**
   `shell/060_mise.sh` は起動のたびに `~/.config/mise/config.toml` を `sed -i` で書き換え、16 個のパッケージを `[tools]` に注入する。複数シェルの同時起動に備えて `flock` による排他まで自前で実装している。
   さらに `shell/252_alias_mise.sh` は日次で `mise use -g --pin` を走らせてバージョンを固定する。これは **`flake.lock` が本来担う役割を手で再実装したもの**にほかならない。

3. **起動時のネットワーク依存**
   `.fish/010_fish_fisher.fish` は fisher を `curl` で取得し、日次で `fisher update` を走らせる。再現性と起動レイテンシの両面で問題がある。
   （`.zsh/150-zi.zsh` は zsh 起動の**たびに** `source <(curl -sL https://git.io/zi-loader)` を実行するという、より重い同種の問題を抱えている。ただし後述のとおり zsh は今回の対象外。）

4. **暗黙の依存**
   `.gitconfig:31` は `pager = delta` を指定しているが、`git-delta` はどの管理下にもなく手動インストール前提だった。また `cargo:` 系の 5 パッケージ（`bat` / `eza` / `fd-find` / `procs` / `ripgrep`）は `cargo-binstall` 経由で **ソースビルド**されていた。

5. **OS 差分の手作業**
   `.gitconfig:11-17` の 1Password `op-ssh-sign` のパスは、WSL / Windows でコメントを手で切り替える運用になっている。コミット事故の温床。

---

## 2. 決定 (Decision)

dotfiles の管理を [Nix home-manager](https://nix-community.github.io/home-manager/) へ段階的に移行する。あわせて次を採用する。

1. **`nix/` 専用ディレクトリに閉じ、設定ファイルは複製する**
   既存ツリー（`shell/`, `.bash/`, `.zsh/`, `.fish/`, `.config/`, `main.bash`）は**一切変更しない**。設定は `nix/files/` へコピーする。移行期間中は同じ設定が 2 箇所に存在するが、既存マシンを壊さず並行検証するための意図的な代償。

2. **`flake.nix` はリポジトリ直下ではなく `nix/` に置く**
   複製方式のおかげで `nix/` が自己完結するため、flake の `self` が `nix/` に閉じ、store コピーがレガシーツリーを含まない。

3. **Nix store 管理**（`mkOutOfStoreSymlink` は使わない）
   編集の度に `home-manager switch` が必要になる代わりに、世代管理とロールバックが完全に効く。ただし**実行時にツール自身が書き込むファイルは例外**とする（§3 参照）。

4. **対象は Linux / macOS (aarch64) / WSL のみ**
   Windows (MINGW/MSYS) は Nix が動かないため対象外。`main.bash setup` を Windows 用および復旧用に残す。この割り切りにより `programs.*` モジュールを idiomatic に使える。

5. **対象シェルは bash / fish のみ。zsh は持ち込まない**

6. **グローバル CLI ツールは Nix、言語ランタイムは mise**
   プロジェクト毎のバージョン切替が必要な `go` / `node` は mise に残す。

7. **段階移行。どの段階でも `./main.bash setup` で戻せる状態を保つ**

### 変更後の構造（赤い部分が新規／変更点）

![変更後アーキテクチャ](./plantuml/out/02_after.svg)

### 移行の順序

![段階移行](./plantuml/out/03_staging.svg)

---

## 3. 変更点の詳細 (What changed)

| 変更前の仕組み | 変更後 (home-manager) |
| --- | --- |
| `main.bash setup`（symlink + rc 追記） | `home-manager switch --flake ~/dotfiles/nix#<host>` |
| 配置状態が不透明 | `nix build .#...activationPackage` で**適用前に配置ツリーを読める** |
| `Makefile clean` が 4/13 しか外さない | `home-manager uninstall` で全撤去。世代ロールバックも可能 |
| `shell/060_mise.sh` の `sed -i` 注入 | `home.packages` による宣言。マーカーファイルで旧注入を停止 |
| `shell/252_alias_mise.sh` の日次 pin | `flake.lock` |
| `cargo-binstall` によるソースビルド | nixpkgs のバイナリキャッシュ |
| `git-delta` が未管理 | `programs.delta`（本体も入る） |
| `.gitconfig` の 1Password パス手動コメント切替 | `lib.mkIf` による自動分岐。パス中の Windows ユーザー名は `dotfiles.windowsUserName` として host から渡す |
| bash-completion を `curl` + `tar` で 2.11 を取得 | `programs.bash.enableCompletion`（nixpkgs の 2.18.0） |
| fisher（curl インストーラ + 日次 update） | `programs.fish.plugins` + `fishPlugins.*` |
| `.bash/03_mise.sh` が起動毎に mise 補完を書き出す | `programs.mise`（store 上の静的ファイル） |
| シェル断片を数字プレフィックスで読み込み順制御 | 役割別の Nix モジュール（`fish.nix` / `bash.nix` / `shell-common.nix`） |

### 実装したモジュール

| ファイル | 役割 |
| --- | --- |
| `home/modules/packages.nix` | `programs.*` を使わない CLI ツール |
| `home/modules/files.nix` | 静的な設定ファイルの配置 |
| `home/modules/git.nix` | `programs.git` / `programs.delta` |
| `home/modules/starship.nix` | `programs.starship`（設定は素のファイルのまま） |
| `home/modules/mise.nix` | mise 抑止マーカー |
| `home/modules/shell-common.nix` | bash/fish 共通（`sessionVariables` / `sessionPath` / `programs.mise`） |
| `home/modules/fish.nix` | abbr 88 / function 24 / `interactiveShellInit` |
| `home/modules/bash.nix` | alias 88 / 関数 24 / `initExtra` |
| `scripts/verify.sh` | 検証の一括実行 |
| `scripts/preflight-unlink.sh` | `main.bash` が張った symlink を外す |
| `scripts/bootstrap-mise.sh` | mise のグローバル設定を初期化（マシンごとに 1 回） |

### 移植中に見つかった既存のバグ

平坦化・移植の過程で、レガシー側に元からあった不具合が表面化した。いずれも再現を確認した上で修正している。

| 対象 | 症状 |
| --- | --- |
| `c`（bash） | `alias c='noglob c-func'` の `noglob` は zsh 専用。bash では `noglob: command not found` で失敗していた |
| `cdrepo`（bash） | ガードが fish 構文の `if not command -v ghq`。bash では `not` が無く終了ステータス 127 = 常に偽で、一度も発火しない死んだコードだった |
| ssh-agent（bash/fish 両方） | `ssh-add` の存在確認が無く、未インストール環境では起動のたびにエラーが出ていた |
| mise の `install_before` | 現在の mise では `minimum_release_age` に改名済み。旧名は `settings ls` に存在せず、書いても**エラーにならず無視される** |
| mise 設定の seeding | Stage 4 のマーカーがテンプレート seeding も止めるため、**新規マシンでは `~/.config/mise/config.toml` が作られない**。`bootstrap-mise.sh` で対処 |

平坦化で判明した重複定義（レガシーでは読み込み順で後勝ち、いずれも後勝ち側を採用）:

| 名前 | 先に定義 | 後に定義（採用） |
| --- | --- | --- |
| `f` | `201_git` の `git fetch` | `250_alias` の `cd ..` |
| `ls` | `060_mise` の `eza` | `250_alias` の `eza --group-directories-first -F` |

### store 管理の例外

「Nix store 管理」を原則とするが、**実行時にツール自身が書き込むファイルは store に置けない**（store は read-only）。調査で判明した該当パスと対処:

| パス | 書き込む主体 | 対処 |
| --- | --- | --- |
| `~/.config/mise/config.toml` | `sed -i` / 日次 `mise use --pin` | Nix 管理下に置かず mise に所有させる |
| `~/.config/git/config` | `git config --global` | `programs.git.includes` で `config.local` に書込先を逃がす |
| `~/.config/fish/fish_plugins` | `fisher` | Stage 5 で fisher ごと不要にする |
| `~/.ssh/config` | `main.bash` の Include 追記 | 今回は対象外（`.ssh` は未初期化の private submodule であり、flake は `?submodules=1` なしに submodule を取得しない） |
| `~/.common_shellrc.sh` | ユーザー（untracked） | **絶対に Nix 管理下に置かない**。半端な移行状態での復旧経路 |

### 対象外にしたもの

| 対象 | 理由 |
| --- | --- |
| zsh (`.zshrc`, `.zsh/`, `p10k/`) | nix 側に持ち込まない。レガシー経路では従来どおり動作する |
| `.config/pypoetry/` | 古いため |
| `_zshrc_mac`, `_screenrc_for_mac`, `_vimrc_for_windows` | 参照されていない死んだファイル |
| `programs.tmux` | 独自の prefix/escape-time 設定を前置する。tpm 未使用のため利点なし → 素のファイル配置 |
| `programs.neovim` | `init.lua` を書き出し `~/.config/nvim` のディレクトリ配置と衝突する → 素のファイル配置 |
| `programs.zellij` | KDL 生成の書き換えコストが高く、`enable*Integration` は**シェル起動毎に zellij を自動起動する**罠がある → 素のファイル配置 |
| `nix-darwin` | `/etc`・launchd・Homebrew を管理するもので本リポジトリの用途にない |

---

## 4. 検討した代替案 (Alternatives considered)

| 案 | 概要 | 不採用の理由 |
| --- | --- | --- |
| 現状維持 (`main.bash` 継続) | 独自スクリプトを改善して使い続ける | 手続き的・差分確認不可・アンインストール経路なしという根本課題が残る |
| **chezmoi** ([PR #17](https://github.com/pollenjp/dotfiles/pull/17)) | テンプレートと `chezmoi apply` による宣言的配置。ADR 実装済みの未マージブランチが存在する | dotfile の配置は解決するが**パッケージ管理は範囲外**で、mise の `sed -i` 問題と自作 lockfile 問題が残る。Nix なら配置とパッケージを単一の `flake.lock` で固定でき、世代ロールバックも得られる |
| GNU Stow | symlink farm 管理 | テンプレート / OS 分岐 / パッケージ管理の仕組みがなく、結局スクリプトが必要 |
| dotbot / yadm | 宣言的 install / git ラッパ | パッケージのバージョン固定ができない |
| `mkOutOfStoreSymlink` 方式 | `~/.config/... -> ~/dotfiles/...` の symlink を張り、直接編集の即時反映を維持する | 現状の UX を保てる利点はあるが、世代ロールバックがファイル内容に効かない。再現性を優先して store 管理を選択した |
| `flake.nix` をリポジトリ直下に置く | `home-manager switch --flake ~/dotfiles#...` と書けて短い | store コピーにレガシーツリー全体が入る。複製方式なら `nix/` に閉じられるので採らなかった |
| Nix で全部管理（mise 廃止） | 言語ランタイムも Nix + direnv で管理 | プロジェクト毎のランタイム切替を全リポジトリに flake を置いて実現するのは負担が大きい。将来の別 ADR とする |

---

## 5. 影響 (Consequences)

### 良くなること

- **適用前に差分を確認できる。** `nix build .#homeConfigurations."<host>".activationPackage` の結果を `find` すれば、配置される全ファイルを事前に読める。
- **世代管理とロールバック。** `home-manager generations` で一覧し、古い世代の `activate` を叩けば即座に戻せる。
- **`flake.lock` により全マシンのツールバージョンが一致する。** 日次 pin の自作ロジックが不要になる。
- **ソースビルドが消える。** `cargo:` 系 5 パッケージがバイナリキャッシュから入る。
- **OS 差分が自動化される。** 1Password のパス手動コメント切替が不要になり、コミット事故の温床が消える。
- **起動時のネットワークアクセスが減る。** fisher の curl と日次 update、bash-completion の curl が消える。

### 注意が必要なこと（レビュー対象）

- ⚠️ **編集ワークフローが変わる。** store 管理のため、設定を変えたら `home-manager switch` が必要になる。symlink 直接編集の即時反映は失われる。
- ⚠️ **`mise activate` は shim を PATH の先頭に差す。** `.zsh/103_mise.zsh` は `shell/0xx_*` の**後**にロードされるため、mise のリストに残っている限り mise 側が Nix 側を上書きする。**Stage 4 のリスト削減は美観ではなく必須。**
- ⚠️ **既に `~/.config/mise/config.toml` に書き込まれた 16 エントリは自動では消えない。** マシン毎に一度だけ手で言語ランタイムのみへ削る必要がある。
- ⚠️ **Stage 5 で `programs.bash` が `~/.bashrc` を所有する。** `~/.bashrc` は symlink ではなく `main.bash` が**追記**したファイルなので `preflight-unlink.sh` では外せない。事前に `append_load_rc_line` (`script/utils.bash:25-49`) が追記したガード付き stanza と、bash-completion のローダ行 (`main.bash:213-219`) を手で削除しないと `Existing file ... would be clobbered` で失敗する。
- ⚠️ **`git config --global` が使えなくなる。** 書込先の `~/.config/git/config` が store 上の read-only ファイルになるため。マシン固有の設定は `~/.gitconfig` を作れば足せる（git の読み込み順により home-manager の設定を上書きできる）。同じ理由で `~/.gitconfig` の symlink は必ず外すこと。
- ⚠️ **タグにも署名が付くようになる。** `signing.signByDefault` が `commit.gpgSign` と `tag.gpgSign` の両方を立てるため。元は commit のみだった。
- ⚠️ **bash でも starship プロンプトになる。** レガシーで starship を初期化しているのは fish だけで、bash は素のプロンプトだった。両シェルで揃える判断だが、実質的な挙動変更。戻す場合は `starship.nix` の `enableBashIntegration` を `false` にする。
- ⚠️ **`bootstrap-mise.sh` の実行を忘れると新規マシンで go / node が入らない。** `~/.config/mise/config.toml` を Nix 管理下に置いていないため、`home-manager switch` だけでは作られない。
- **ログインシェルの変更は手作業。** `programs.fish.enable` はインストールのみで `chsh` はしない。
- ⚠️ **`-b bak` は `<file>.bak` が既に存在すると失敗する。** 部分失敗からのリトライ時は古い `.bak` を先に消すこと。
- ⚠️ **x86_64-darwin (Intel Mac) は対象外。** nixpkgs 26.11 でサポートが打ち切られ、評価時点で `Nixpkgs 26.11 has dropped support for x86_64-darwin.` で落ちる。
- **移行期間中は設定が 2 箇所に存在する。** 意図的な選択だが、片方だけ直す事故に注意。Stage 6 で収束を判断する。

---

## 6. 検証 (Verification)

nixpkgs 26.11pre (`70ce2343`) / home-manager master (`7834e825`) に対して検証した。
Stage 2 以降は `./nix/scripts/verify.sh` で一括実行できる（実際の `$HOME` には触れない）。

**全ステージ共通**

- `nix flake check --all-systems --no-build` が 3 system 全てで通過（`all checks passed!`）
- `config.warnings` が空
- 使い捨て `$HOME` (`/tmp/hm-sandbox`) への `activate` が成功し、再実行しても世代が増えない（冪等）
- `nixfmt --check` / `shfmt` / `shellcheck` が通過

**Stage 3（ファイル配置）**

- 配置された 9 ファイルすべてが `/nix/store` を指すこと
- 書き換えた参照先（`~/.vim/common.vim` など）が配置後に実在すること

**Stage 4（git / starship / mise）**

- 生成された git config の全セクションを目視確認（`user` / `includeIf` / `ignore` 含む）
- WSL 版と非 WSL 版の差分が op-ssh-sign の 1 行のみ
- `isWSL = true` かつ `windowsUserName` 未設定のホストで警告が出て、signer が既定へフォールバックすること
- 偽 `mise` を使った機能テストで、マーカー有無による挙動差を確認
  （なし: 16 エントリ注入 + `mise install` / あり: 一切触らない）

**Stage 5（シェル）**

- fish: abbr 88/88・function 24/24 がレガシー定義と一致（欠落・余剰ゼロ）
- bash: レガシー 92 種 → alias 88 + 関数化 4 で完全一致
- 生成された `config.fish` と function 24 個が `fish -n`、`.bashrc` が `bash -n` を通過
- **実際に対話シェルを起動**してエラー出力が無いこと、vi モード / greeting 抑制 /
  starship / mise / kubectl 補完が有効なことを確認
- Nix の `${` エスケープ漏れが無いこと（`touch-vscode-workspace` を実行して
  ヒアドキュメントから正しい JSON が生成されるところまで確認）

検証で判明し、その場で修正した点:

- `x86_64-darwin` は nixpkgs 26.11 で評価が落ちるため対象 system から除外した
- `nixfmt-rfc-style` は非推奨（`now the same as pkgs.nixfmt`）だったため `nixfmt` に変更した
- `home.stateVersion` の有効値は `26.11` が最大。greenfield なので最新に合わせた
- `programs.git.delta` および `userName`/`userEmail`/`aliases`/`extraConfig` は
  home-manager 26.11 で改名・非推奨になっていたため新 API へ移行した
- **初回は `home-manager` コマンドが存在しない**（`programs.home-manager.enable` が
  CLI を入れるのは初回 activate の後）。flake に `packages.<system>.home-manager` を
  追加し、`nix run ~/dotfiles/nix#home-manager -- switch ...` で解決した
- `activationPackage` の `home-files` は store への symlink なので、`find` に `-L` が
  必要。付けないと 1 件も列挙されず「配置物なし」に見える

> **検証環境の制約**: 作業環境は `codeload.github.com` がネットワークポリシーで遮断されており、`github:` 形式 input のソース取得ができない。検証は input を git プロトコル / channels tarball に差し替えて実施した（同一リビジョン）。`flake.lock` の narHash 照合のみ未実施。

---

## 7. 移行・運用手順

> パスは[後続 ADR](../002_nix_hosts_and_local_flake_20260810T153848JST/README.md)で
> 変わっている。リポジトリ本体は `$(ghq root)/github.com/pollenjp/dotfiles`、
> 日々の入口は `~/dotfiles`（ローカル専用 flake）。以下はその形に更新してある。

```sh
# 0. リポジトリ本体を ghq 配下へ
ghq get git@github.com:pollenjp/dotfiles.git
REPO="$(ghq root)/github.com/pollenjp/dotfiles"

# 1. Nix を導入
curl -fsSL https://install.determinate.systems/nix | sh -s -- install

# 2. 何が配置されるかを $HOME に触れず確認する
#    (home-files は store への symlink なので find に -L が必須)
cd "${REPO}/nix"
nix build '.#homeConfigurations."pollenjp@wsl".activationPackage' -o /tmp/hm
find -L /tmp/hm/home-files -mindepth 1 -maxdepth 3

# 3. main.bash が張った symlink を外す (Stage 3 以降)
./scripts/preflight-unlink.sh

# 3.5 ~/dotfiles にローカル flake と setup の symlink を置く
./scripts/setup-local-flake.sh

# 4. 初回適用
#    この時点では home-manager コマンドはまだ存在しない。
#    programs.home-manager.enable が CLI を profile へ入れるのは
#    初回の activate が成功した後なので、1 回目は flake から直接実行する。
nix run ~/dotfiles#home-manager -- switch --flake ~/dotfiles#pollenjp@wsl -b bak --dry-run
nix run ~/dotfiles#home-manager -- switch --flake ~/dotfiles#pollenjp@wsl -b bak

# 5. mise のグローバル設定を初期化する (マシンごとに 1 回)
#    ~/.config/mise/config.toml は Nix 管理下に置いていないため、
#    これを飛ばすと新規マシンでは go / node が入らないままになる。
./scripts/bootstrap-mise.sh

# 6. 既存マシンのみ: ~/.config/mise/config.toml から Nix へ移した
#    CLI ツールを手で削り、go / node / usage だけ残す
$EDITOR ~/.config/mise/config.toml

# 日常 (初回以降は profile に入るので短く書ける)
home-manager switch --flake ~/dotfiles#pollenjp@wsl
home-manager generations
nix flake update --flake "${REPO}/nix"
```

`programs.fish.enable` は fish を**インストールするだけ**でログインシェルには設定しない
（`/etc/passwd` の変更は home-manager の管轄外）。必要なら別途 `chsh` する。

手順の詳細と新規マシン向けチェックリストは [`nix/README.md`](../../../nix/README.md) にある。

> `nix run home-manager -- ...`（レジストリ経由）は使わないこと。nixpkgs 同梱の別バージョンが
> 実行され、`flake.lock` で固定した home-manager モジュールとバージョンがずれる。
> flake が `packages.<system>.home-manager` を公開しているのはこのため。

**ロールバック**は 3 段階:

1. `home-manager generations` で古い世代の `activate` を実行する
2. `home-manager uninstall` で全撤去する
3. **最終手段として `./main.bash setup` が動く** — Stage 6 まで `main.bash` を触らないのはこのため

---

## 8. 参考 (References)

- home-manager 公式: <https://nix-community.github.io/home-manager/>
- home-manager オプション一覧: <https://nix-community.github.io/home-manager/options.xhtml>
- Nix flakes: <https://nix.dev/concepts/flakes.html>
- 本 ADR の入門ドキュメント: [textbook/README.md](./textbook/README.md)
- 図の再生成: [`plantuml/`](./plantuml/) で `mise run plantuml:generate`（`plantuml/mise.toml` 参照）
- 代替案として検討した chezmoi 移行 ADR: `docs/adr/2026-07/19T093812JST_chezmoi_migration/`（ブランチ `claude/dotfiles-chezmoi-migration-95xj5i`）
