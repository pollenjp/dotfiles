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
| `~/ghq/github.com/pollenjp/dotfiles` | リポジトリ本体 | 管理下 |
| `~/dotfiles` | ローカル専用の flake と `setup` への symlink | **管理外** |

本体を ghq 配下に置くのは、`cdrepo` など ghq 前提の仕組みと置き場所を揃え、
他のリポジトリと同じ規則で辿れるようにするため。一方で日々叩くパスは短く
固定したいので、`~/dotfiles` を「常にここから実行する入口」として別に用意する。

### 最初の clone

**この時点では `ghq` はまだ無い。** `ghq` は Nix が入れるもの (`home/modules/packages.nix`)
なので、初回は `$(ghq root)` も `ghq get` も使えない。既定のパスへ `git clone` で置く。

```sh
mkdir -p ~/ghq/github.com/pollenjp

# https (初回はこちら。SSH 鍵 (1Password) の設定もまだのことが多いため)
git clone https://github.com/pollenjp/dotfiles.git ~/ghq/github.com/pollenjp/dotfiles

# SSH 鍵が既に使えるなら
git clone git@github.com:pollenjp/dotfiles.git ~/ghq/github.com/pollenjp/dotfiles
```

2 台目以降 (`ghq` が入っている環境) なら `ghq get` でも同じ場所に置ける。

```sh
ghq get https://github.com/pollenjp/dotfiles.git
ghq get git@github.com:pollenjp/dotfiles.git
```

> このドキュメントは `ghq root` の既定値 `~/ghq` を直接書いている。
> `GHQ_ROOT` や `git config ghq.root` で変えている場合はそのパスに読み替えること。
> スクリプト側は `ghq` → `GHQ_ROOT` → `git config ghq.root` → `~/ghq` の順で
> 自動判定するので、変えていても正しく動く。

### `~/dotfiles` を用意する

```sh
~/ghq/github.com/pollenjp/dotfiles/nix/scripts/setup-local-flake.sh
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

> ⚠️ **旧経路 `main.bash setup` を使っていたマシンでは `~/dotfiles` がリポジトリ本体になっている。**
> 先に本体を ghq 配下へ移すこと。`setup-local-flake.sh` は `~/dotfiles` が git 作業ツリーだと
> 何もせず止まるので、取り違えて壊すことはない。
>
> ```sh
> mkdir -p ~/ghq/github.com/pollenjp
> mv ~/dotfiles ~/ghq/github.com/pollenjp/dotfiles
> ```
>
> 旧経路が配置した設定ファイルは `~/dotfiles/...` を直接参照しているため、移動すると
> 旧経路側は壊れる。Nix 経路へ切り替えるマシンでのみ行うこと（手順 2 の
> `preflight-unlink.sh` で symlink を外すのが前提）。

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

## 更新

「更新」には別の軸が 3 つある。混ぜると分からなくなるので分けて扱う。

| 何が古くなるか | 何をする | 誰が |
| --- | --- | --- |
| 本体の checkout（`setup.sh` と各モジュール） | `git pull` | `~/dotfiles/setup --self-update`（[後述](#本体を最新にする---self-update)） |
| `nix/flake.lock`（nixpkgs / home-manager のバージョン） | `flake-lock-age.sh update` | `~/dotfiles/setup --flake-update`（[後述](#依存-flakelock-の更新)）か手で実行 |
| skill 側の `flake.lock`（`pjp-drawio` / `pjp-plantuml`） | `flake-lock-age.sh update <そのディレクトリ>` | 手で実行（`setup` は本体しか見ない） |
| `~/dotfiles/flake.lock` | `nix flake update` | `setup.sh` が `switch` の前に張り直す（[後述](#ローカル-flake-の-lock-も張り直す)。本体を編集しただけでも要る） |

**`~/dotfiles/setup` は本体の `setup.sh` への symlink なので、それ自体が古くなることはない。**
古くなるのは symlink の先、つまり本体の checkout。

### 本体を最新にする (`--self-update`)

```sh
~/dotfiles/setup --self-update            # fetch -> fast-forward -> 新しい自分で続行
~/dotfiles/setup --self-update --update   # 最新にしてから home-manager switch
```

メニューからは `u`。`--self-update` を付けない限り git は触らない。

`git pull` は**実行中の `setup.sh` 自身を置き換える**。bash はスクリプトを読み進めながら
実行するので、書き換え方によって次の 2 通りになる（bash 5.2 で実測）。

| 書き換え方 | 実行中のプロセスが見る内容 |
| --- | --- |
| 同じ inode を上書き（`cat > file`） | 途中から新しい内容を読む（挙動が混ざる） |
| unlink + 新規作成（`git checkout` / `merge`） | 古い内容を読み続ける |

git は後者なので壊れはしないが、**古いロジックで最後まで走る**。更新後の
`bootstrap-*.sh` や登録簿を古いオーケストレータが呼ぶ形になるので、更新できたら
`exec` で自分を張り替え、続きは新しい `setup.sh` に任せる。対象ホストや退避の設定は
引き継がれる。更新で `setup.sh` 自体が移動していて `exec` できないときは、
古いまま続けずに止める。

本体は**開発対象でもある**（`path:` を選んだのは commit せずに試せるから）ので、
次の場合は警告だけ出して何もしない。手順の実行自体は続ける（オフラインでも
setup は使えるべきなので、`fetch` の失敗も止める理由にしない）。

| 状況 | 理由 |
| --- | --- |
| 未 commit の変更がある | 作業中の変更を巻き込みたくない（`.ssh` submodule の状態は見ない） |
| detached HEAD / upstream 無し | どこへ進めるべきか決められない |
| fast-forward できない | rebase か merge かの判断はしない |

メニューのヘッダには「本体が N commit 遅れ」を出す。ただし**起動時に `fetch` はしない**
（毎回ネットワークへ出たくない）ので、最後に `fetch` した時点の話になる。

`flake.lock` の更新は `--self-update` では扱わない。別軸なので `--flake-update`（下記）で分けている。
`git pull` は未 commit の変更があると止まるので、**両方やるなら pull が先**
（`--self-update` は手順の実行より前に走るため、`--self-update --flake-update` の順序は勝手に合う）。

### 依存 (flake.lock) の更新

```sh
~/dotfiles/setup --flake-update --update   # 更新してから switch
~/dotfiles/setup --steps flake-update      # 更新だけ

# setup を通さないなら (同じことをする)
~/ghq/github.com/pollenjp/dotfiles/nix/scripts/flake-lock-age.sh update
```

**素の `nix flake update` は使わない。** あれは追跡先の先端を取るので、下の
[遅延](#新しすぎる-revision-を-pin-しない-minimumreleaseage-相当)が黙って外れる。

メニューからは `f`。`flake.lock を更新` という手順が `switch` の直前に入る
（`u` と違ってその場では実行しない。手順表に載っているので `--dry-run` と結果一覧に乗る）。
重くて壊れうる操作なので**プリセットには入れていない**。`--update` は指定しない限り lock を触らない。

nixpkgs / home-manager を上げるには**本体の `nix/flake.lock`** を更新する。`~/dotfiles` 側だけ
更新しても何も上がらない（`nix flake update --flake ~/dotfiles` は `dotfiles` という `path:` 入力を
張り直すだけで、pin は `dotfiles` ノード経由で本体の lock から来る）。

追跡されているファイルを書き換えるのでリポジトリは dirty になる。
**動作を確認したら commit すること**（未 commit のままだと `u` / `--self-update` が本体を更新しない）。
dirty でも switch には新しい lock が入る（`path:` はディレクトリを複製し、
`git+file:` は作業ツリーの内容を見るため）。

> `nix flake update` に `#<ホスト>` は付けられない。`--flake` は flake ref だけを取る。
>
> ```
> error: unexpected fragment 'pollenjp@wsl' in flake reference '~/dotfiles#pollenjp@wsl'
> ```

#### 新しすぎる revision を pin しない (minimumReleaseAge 相当)

上げ先は追跡先の**先端ではなく、公開から 7 日以上経った revision**。
出たばかりのものを掴まないための遅延で、npm / pnpm の `minimumReleaseAge` に相当する。
決めているのは [`scripts/flake-lock-age.sh`](./scripts/flake-lock-age.sh)。

```sh
./nix/scripts/flake-lock-age.sh resolve   # 選ぶ revision を見るだけ
./nix/scripts/flake-lock-age.sh update    # その revision へ更新し、入る閉包をスキャン
./nix/scripts/flake-lock-age.sh check     # 今の flake.lock を検査 (CI が回している)
```

**`update` は lock を書いたあと、その lock で実際に入る閉包のスキャン
（[後述](#閉包のスキャンと-pin先端の差分-遅延の補完)）を自動で差し込む。**
lock を作る・上げる入口はここしか無いので、「新しい pin を初めて実行する前に
必ず照合が挟まる」ようにしてある。whitelist のある flake（本体の `nix/` など）
ではゲートとして働き、新規 findings があると失敗する（lock 自体は更新済み）。
whitelist の無い flake（初回の lock など）では表示だけ。`--no-scan` で飛ばせる。

`flake.lock` がまだ無い flake でも `resolve` / `update` は通る（input の一覧を
`flake.nix` の `inputs` から読む）。**flake を新しく足したときの 1 本目の lock も
`update` で作ること。** 先に `nix flake lock` を打つと一度先端へ pin されるので、
遅延が最初から外れた lock を commit することになる（`check` も落ちる）。

ディレクトリを省くと `nix/` が対象。**リポジトリ内の flake は本体だけではない**ので、
まとめて見るときは並べて渡す（CI の `lock-age` はこの形で回している）。

```sh
./nix/scripts/flake-lock-age.sh check \
  ./nix \
  ./nix/files/claude/skills/pjp-drawio \
  ./nix/files/claude/skills/pjp-plantuml
```

この道具は dotfiles 専用ではない。**他のリポジトリからも同じものを呼べる**ように
flake の app として出している（`flake.nix` の `apps.<system>.flake-lock-age`）。

```sh
nix run 'github:pollenjp/dotfiles?dir=nix#flake-lock-age' -- check
```

引数を省いたときの対象は、チェックアウトから直接叩けば `nix/`、`nix run` で
呼べばカレントディレクトリ。他リポジトリへの入れ方は `pjp-nix-flake` skill の
`references/lock-age.md`。

Nix にはパッケージ単位のバージョン解決が無い。入るものは `flake.lock` が指す
nixpkgs ツリー 1 点で決まるので、**「新しすぎるパッケージを避ける」は「新しすぎる
revision を pin しない」と同義**になる。日数の下限はここでしか表現できない。

対象は root の直下 input **すべて**。片方だけ遅らせても、もう片方が先端に張り付いたままに
なる。測り方は input ごとに違い、script が `flake.lock` を読んで判別する。

| input | 何の時刻で測るか | なぜ |
| --- | --- | --- |
| `nixpkgs`（`nixpkgs-unstable` を追うもの） | `releases.nixos.org` のチャンネル公開時刻（`Last-Modified`） | 各公開は Hydra を通った commit なので binary cache が揃っている。master の任意の commit を日付だけで選ぶとほぼ全部ソースビルドになる |
| その他の GitHub input（`home-manager` など） | 追跡先の commit 時刻（GitHub API の `until=`） | これらにはチャンネルが無い |
| `follows` / `path:` などの input | 対象外 | 自分の revision を持たない |

日数は `--min-age-days N` か `FLAKE_MIN_RELEASE_AGE_DAYS` で変える。`setup.sh` 経由の
ときは `DOTFILES_MIN_RELEASE_AGE_DAYS`（一族の名前を保つため、あちらが橋渡しする）。

```sh
./nix/scripts/flake-lock-age.sh --min-age-days 14 update
./nix/scripts/flake-lock-age.sh --min-age-days 0  update  # 遅延なし = 先端
DOTFILES_MIN_RELEASE_AGE_DAYS=0 ~/dotfiles/setup --steps flake-update
```

**遅延を伸ばすほど、既知 CVE が未修正のまま残る期間も伸びる**（ブラウザ / curl /
openssl のような日常的に踏むものはこちら側のリスクが大きい）。7 日はその折り返し点として
選んだ既定値で、長くすれば安全になるという種類の数字ではない。

##### 遅延が外れたことに気付く仕組み

`flake.nix` は `nixpkgs-unstable` を追ったままで、遅延は **`flake.lock` の pin にしか
現れない**。つまり素で `nix flake update` を叩けば黙って先端に飛ぶ。そのための番人が
CI の `lock-age` ジョブ（`flake-lock-age.sh check`）で、下限より新しい pin があると落ちる。

> ⚠️ **flake を足したら `lock-age` ジョブの並びにも足すこと。** 対象はディレクトリの
> 列挙なので、足し忘れるとその flake だけ黙って検査から漏れる。

判定に使う `flake.lock` の `lastModified` は **commit 時刻**でチャンネル公開時刻ではないので、
Hydra の遅れ（実測 1〜2 日）の分だけ判定は緩い側に出る。先端への事故を捕まえる用途には足りる。

##### 遅延を外す

緊急の CVE 修正を先端から入れたいときは `--min-age-days 0` で `update` する。
その commit では CI の `lock-age` が落ちるが、**それは意図どおり**。通したいときは
`workflow_dispatch` の `min_release_age_days` に `0` を入れて再実行する。

#### 閉包のスキャンと pin↔先端の差分 (遅延の補完)

上の遅延は「未発覚の侵害を誰かが先に踏む時間」を稼ぐ一方、**発覚済みの侵害
バージョンを下限日数のあいだ固定し続ける**というリスクを新しく作る。それを塞ぐ
道具が 2 つある（なぜこの組み合わせなのかは
[ADR 006](../docs/adr/006_nix_closure_sbom_osv_scan_20260823T004634JST/README.md)）。

**[`closure-scan.sh`](./scripts/closure-scan.sh)** — 実際に入る閉包をビルドして
SBOM 化し、vulnxscan（OSV + Grype + vulnix）で照合する。サプライチェーン侵害の
advisory の主戦場が OSV / GHSA なので、NVD しか見ない vulnix は補助線の扱い。
CI の `closure-scan` ジョブが PR / push に加えて**毎日の定期実行**でも回していて
（advisory は pin より後から出るため）、whitelist
（[`vulnxscan-whitelist.csv`](./vulnxscan-whitelist.csv)）に無い findings があると落ちる。

```sh
./nix/scripts/closure-scan.sh scan       # CI と同じ (whitelist に無い findings で非ゼロ)
./nix/scripts/closure-scan.sh report     # 表示するだけ (落ちない。whitelist は無くてもよい)
./nix/scripts/closure-scan.sh baseline   # 今の findings を whitelist へ追記して受け入れ
```

回るタイミングは 3 つ。

| いつ | 形 |
| --- | --- |
| `flake-lock-age.sh update` の完了時（自動） | whitelist があれば `scan`、無ければ `report`。**新しい pin を初めて実行する前に必ず照合が挟まる** |
| PR / push の CI | `scan`（ゲート） |
| 毎日の定期実行 | `scan`（pin 更新が無い期間も advisory の増分を照合） |

対象の属性は flake で変わる。dotfiles 本体は home 閉包
（`homeConfigurations.sandbox`）、それ以外の flake は `devShells.<system>.default`
（「これから実行するツール」は devShell に入っているものなので）。`--attr` で変えられる。

落ちたときの対応は 2 択。

1. **pin を動かして直るか見る** — `flake-lock-age.sh resolve / update`。修正が
   下限より新しい側にしか無いなら、[遅延を外す](#遅延を外す)判断まで含む
2. **意図して受け入れる** — `baseline` で whitelist へ追記し、comment に理由を
   書いてから commit する

whitelist は「安全と確認した」印ではなく**増分検知の基準線**。閉包には既知 CVE が
常に数十件あるので（導入時点で 67 件）、全 findings で落とすとゲートは初日から
赤いままになる。受け入れは git 管理の csv への追記なので、PR の diff がそのまま
監査線になる。

**[`closure-head-diff.sh`](./scripts/closure-head-diff.sh)** — pin と現在の
チャンネル先端の両方で閉包を組み、入るパッケージの版差分を出す。侵害の発覚後、
advisory より先に nixpkgs 側の対応（bump / revert / `knownVulnerabilities`）が
入ることがよくあるので、**pin を更新する PR で「動いたパッケージのうち見覚えの
無いものだけ nixpkgs のコミットログを見る」**ための材料になる。CI の `head-diff`
ジョブが `nix/flake.lock` の動いた PR で summary に貼る。版が動くこと自体は
日常なので、**差分があっても落とさない**。

```sh
./nix/scripts/closure-head-diff.sh
```

sbomnix（vulnxscan 同梱）が PATH に無ければ、script が**対象 flake の pin された
nixpkgs** から `nix shell --inputs-from` で自動で入り直す。スキャナ自身の版も
同じ遅延ポリシーに従わせるための形。

dotfiles 本体の既定対象 `homeConfigurations.sandbox` は、パッケージ集合が
全ホスト共通（ホスト差は設定側にしか無い）なので x86_64-linux の代表として使う。
skill 側 flake（`pjp-drawio` / `pjp-plantuml`）は `update` 時の自動スキャン
（whitelist が無いので表示のみ）だけで、**CI の定期スキャンは本体の閉包しか
見ていない**。

他のリポジトリからは flake の app として呼べる（`flake-lock-age` と同じ形）。

```sh
nix run 'github:pollenjp/dotfiles?dir=nix#closure-scan' -- report
```

#### ローカル flake の lock も張り直す

いまの nix（Determinate 3.21.9 / 2.34 で実測）は **`path:` 入力を narHash で厳密に lock する**。
`~/dotfiles/flake.lock` は本体（`nix/`）をその narHash で pin しているので、
**`nix/` の中身が 1 文字でも変われば**評価がここで落ちる。

```
error: NAR hash mismatch in input 'path:/home/pollenjp/ghq/.../nix?narHash=sha256-…'
       expected 'sha256-…' but got 'sha256-…'
```

落ちる条件は「本体を編集した」「`flake.lock` を更新した」「`git pull` した」の全部。
`nix flake lock` では直らない（同じエラーになる）。`nix flake update` だけが張り直す。
`path:` の先が git 作業ツリーの中かどうかは無関係。

**`setup.sh` は `switch` の前に自動で張り直す**（`sync_local_flake_lock`）。
判定は「実物の narHash が lock に入っているか」だけで、
**合っているときは何もしない**（変わっていないのに lock を触ると、触ったのか判らなくなる）。
`nix hash path` は本体のディレクトリで 0.07 秒程度なので毎回計算して構わない。

手でやるなら input 名を指定する。張り直すと本体の新しい pin も推移的に伝わる
（`Updated input 'dotfiles/nixpkgs'`）。

```sh
nix flake update dotfiles --flake ~/dotfiles
```

> `nix flake update --flake ~/dotfiles`（input 名なし）でも直るが、`~/dotfiles/flake.nix` に
> 自分で足した input まで巻き込んで更新してしまう。`setup.sh` も input 名を指定する。

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
  既存ファイル: 退避しない  (b で変更)

  ↑/↓ 移動   Enter 決定   h ホスト変更   b 退避   q 中止
  u 本体を更新   f 依存を更新 [ ] (flake.lock)

  ❯ 新しいマシン適用
    既存マシン更新
    カスタム
    終了
```

| 選択肢 | 実行される手順 |
| --- | --- |
| 新しいマシン適用 | 1 → 2 → 2.5 → 2.6 → 3 → 4 → 6 → 6.1 → 6.2 → 6.5 → 6.6 |
| 既存マシン更新 | 2.6 → 3 → 4 → 6 → 6.1 → 6.2 → 6.5 → 6.6（**冪等な手順は全部走る**。下記） |
| カスタム | 手順を 1 つずつチェックして選ぶ |

「既存マシン更新」は `switch` に加えて `ssh-config` と `bootstrap-*` を毎回走らせる。
どれも冪等（「既に同じなら何もしない」「既に在れば中身に触らない」）なので、繰り返しても
状態は変わらない。走らせないと、スクリプトを足したときや別マシンで変えたとき
（`claude-skills` など）にそのマシンだけ取り残され、取り込むには `--steps` に名前を
並べるしかなくなる。時間が気になるとき・一部だけ走らせたいときは「カスタム」か
`--steps` で選び直す。

入っていないのは、冪等でないか更新時には有害な手順。

| 手順 | 入れていない理由 |
| --- | --- |
| 1 `nix-install` | 既にあれば飛ばすだけ。足しても何も起きない |
| 2 `preflight-unlink` | **home-manager 自身が張った symlink まで外す**（対象パスの symlink を無条件に unlink する）。旧 `main.bash` からの移行用 |
| 2.5 `local-flake` | `~/dotfiles/setup` を**実行元の checkout** へ張り直す（worktree から走らせると dangling で残る）。ghq の決めるパス外では `exit 1` になり後続まで止まる |
| 7 `chsh` | `sudo` が要る。README でも「必要なら」 |

操作は ↑/↓ で移動、Space で選択、**Enter で実行**、q で戻る/中止。
`h` で対象ホスト、`b` で[既存ファイルの扱い](#既存ファイルを退避するか選ぶ)を変えられる。
`u` で[本体を最新にする](#本体を最新にする---self-update)（更新できたら新しい setup で再起動する）。
`f` で[依存を更新する](#依存-flakelock-の更新)（`u` と違いその場では実行せず、
どちらのプリセットにも `flake.lock を更新` を `switch` の直前に足す。`[x]` が付いていれば
下の「実行される手順」にも出る）。
カスタムでは `bootstrap` の行で Space を押すと配下がまとめて切り替わる。

対象ホストは自動判定する。順は次の 2 つで、違うものを使うなら `h` で選び直すか
`--host <名前>`（`DOTFILES_HOST` も同じ）。

1. `~/dotfiles/flake.nix` が定義しているホスト（[登録簿を上書きする側](#登録簿に載せずにマシンを足す)）
2. `$USER` と `uname` からの推測（WSL なら `<user>@wsl`、次に `<user>@<system>`）

1 を先に見るのは、あちらが登録簿を `//` で上書きするための場所だから。名前を
書いた時点で「このマシンはこれ」という意思表示なので、推測より強く扱う。
複数書いてあるときは**一番上**のものを採る（2 の候補と同名のものが下にあっても
そちらへは行かない。既定を変えたいときは行を入れ替える）。2 へ落ちるのは、
ローカル flake がホストを 1 つも定義していないときだけ。ローカル flake 由来の
ときはヘッダに `(ローカル flake)` と出る。

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
~/dotfiles/setup --new-machine --backup   # 既存ファイルを退避してから置き換える
~/dotfiles/setup --self-update --update   # 本体を最新にしてから switch
~/dotfiles/setup --flake-update --update  # 依存 (flake.lock) を更新してから switch
```

`~/dotfiles/setup` は実体への symlink なので、どちらから呼んでも同じ。
使う flake は `~/dotfiles/flake.nix` があればそちら、無ければリポジトリ側を指す
(既存マシンを移行するときは `--steps local-flake` を一度だけ実行する)。

Nix が入る前に走るので、依存は bash / coreutils / curl のみ
（jq も fzf も使えないのでメニューは自前描画）。
`bootstrap-*.sh` は glob で自動列挙するため、スクリプトを足しても
`setup.sh` の編集は要らない。

#### 既存ファイルを退避するか選ぶ

`programs.bash` は `~/.bashrc` / `~/.bash_profile` / `~/.profile` を書く。これらは
**ディストリの初期ファイルとして最初から在る**のが普通で、home-manager は自分が
作ったのではないファイルを消さないため、そのままでは switch がここで止まる。

```
Existing file '/home/pollenjp/.bashrc' would be clobbered by home-manager
```

`-b <拡張子>` を付けると `~/.bashrc.backup` へ改名してから置き換える。
付けるかどうかは好みが分かれるので、setup が決め打ちにせず選ばせる。

| 選択 | 結果 |
| --- | --- |
| 退避しない（既定） | 実ファイルが在ると switch が中断する。中身を見て手で退ける |
| `-b backup` で退避 | `<名前>.backup` へ改名してから置き換える。`main.bash` の追記も残る |

メニューではいつでも `b` で変更できる。加えて、**switch を含む実行を始めるときに
中断させる実ファイルが見つかれば、この画面を挟む**（見つからなければ訊かない）。

```
    退避しない
  ❯ -b backup で退避してから置き換える

────────────────────────────────────────────────────────
  下のファイルを <名前>.backup へ改名してから置き換える。
  中身 (main.bash の追記など) は残るので後から見比べられる。

  中断させる実ファイル (2 件):
    /home/pollenjp/.bashrc
    /home/pollenjp/.profile
```

メニューを通らない経路では引数か環境変数で指定する（既定は「退避しない」で、
中断させるファイルが在れば実行直前に警告が出る）。

```sh
~/dotfiles/setup --new-machine --backup       # -b backup
~/dotfiles/setup --new-machine --backup=bak   # -b bak (拡張子を変える)
~/dotfiles/setup --new-machine --no-backup    # 付けない (既定)
DOTFILES_BACKUP_EXT=bak ~/dotfiles/setup --update
```

> ⚠️ 退避先が既に在ると `-b` は失敗する（上書きしない）。setup は実行前に見つけて
> 知らせるので、古い `<名前>.backup` を消してから実行し直す。

`preflight-unlink.sh` が外すのは **symlink だけ**で、`~/.bashrc` のような実ファイルは
残す（中身を確認してから捨てたいので、消す判断はしない）。役割が分かれている。

### 新規マシンの手順

上から順に実行する。**2 と 4 と 6 と 7 は忘れやすいので注意**（前節のスクリプトを使えば漏れない）。

| # | やること | `--steps` の id | 備考 |
| --- | --- | --- | --- |
| 0 | `hosts/default.nix` にマシンを 1 エントリ追加 | — | WSL なら `wsl = { ... }` も（[後述](#マシン登録簿-hostsdefaultnix)） |
| 1 | Nix を入れる（前節） | `nix-install` | |
| 2 | `./nix/scripts/preflight-unlink.sh` | `preflight-unlink` | `main.bash setup` 済みのマシンのみ |
| 2.5 | `./nix/scripts/setup-local-flake.sh` | `local-flake` | `~/dotfiles` を用意する（[前述](#置き場所)） |
| 2.6 | `./nix/scripts/setup-ssh-config.sh` | `ssh-config` | `.ssh` submodule を `~/.ssh/config.d/` へ（[後述](#ssh-について)） |
| 3 | `nix run ~/dotfiles#home-manager -- switch --flake ~/dotfiles#<host>` | `switch` | 初回はこの形。既存ファイルの扱いは[前述](#既存ファイルを退避するか選ぶ) |
| 4 | `./nix/scripts/bootstrap-mise.sh` | `bootstrap-mise` | mise のグローバル設定と言語ランタイム |
| 5 | `~/.config/mise/config.toml` を手で整理 | — | 既存マシンのみ（後述） |
| 6 | `./nix/scripts/bootstrap-claude-hook.sh` | `bootstrap-claude-hook` | Claude Code のガードフック登録 |
| 6.1 | `./nix/scripts/bootstrap-claude-statusline.sh` | `bootstrap-claude-statusline` | Claude Code の statusLine 登録 |
| 6.2 | `./nix/scripts/bootstrap-claude-env.sh` | `bootstrap-claude-env` | Claude の commit を無署名にする env 登録（[後述](#claude-の-commit-を無署名にする)） |
| 6.5 | `./nix/scripts/bootstrap-claude-skills.sh` | `bootstrap-claude-skills` | private な skill 置き場の取得（後述） |
| 6.6 | `./nix/scripts/bootstrap-local-env.sh` | `bootstrap-local-env` | `~/.config/pjp/env` を置く（[後述](#マシンローカルの環境変数-configpjpenv)） |
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

#### 3. private な skill の取得 (手順 6.5)

```sh
./nix/scripts/bootstrap-claude-skills.sh
```

`pollenjp/claude-skills`（private）を clone して `~/.claude/` へ繋ぐ。
詳細は後述の「Claude Code > private な skill 置き場」を参照。

**private リポジトリなので SSH 鍵が要る**が、取得に失敗しても**エラーにはならない**。
警告を出して正常終了するので、`setup.sh` の後続（`bootstrap-mise` など）はそのまま走る
（この dotfiles は public で、claude-skills を取れないマシンでも通す必要があるため）。

失敗したときは `~/.claude/` に一切触らない（リンクを張りも消しもしない）。鍵を用意した
あとで、この手順だけ実行し直せばよい。

```sh
~/dotfiles/setup --steps bootstrap-claude-skills
```

このリポジトリを使わないマシンでは、この手順ごと飛ばしてよい。

#### 4. ログインシェルの変更 (手順 7)

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

`~/dotfiles/setup --update`（メニューの「既存マシン更新」）は、これに加えて
`ssh-config` と `bootstrap-*` も走らせる（[前述](#まとめて実行する)。どれも冪等）。ホスト名を
覚えていなくてよく、スクリプトが増えていても取りこぼさないのでこちらが楽。

ただし**これは手元の checkout を適用するだけ**で、リモートの変更も依存の新しい版も取ってこない。
本体ごと最新にするなら `--self-update`（[前述](#本体を最新にする---self-update)）、
nixpkgs / home-manager も上げるなら `--flake-update`（[前述](#依存-flakelock-の更新)）を足す。

```sh
~/dotfiles/setup --self-update --update                  # 本体
~/dotfiles/setup --flake-update --update                 # 依存
~/dotfiles/setup --self-update --flake-update --update   # 両方 (pull -> lock 更新 -> switch)
```

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
    wsl = {
      enable = true;
      onePassword = {
        enable = true;
        # ホスト側 Windows のユーザー名。登録簿の pollenjp@wsl は "polle" 固定なので、
        # 別の名前のマシンはここで足す。値はこのマシンで:
        #   pwsh.exe -NoProfile -Command '$env:USERNAME'
        windowsUserName = "polle";
      };
    };

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

`~/dotfiles/setup` のホスト選択（`h`）にもここで足したものが出る。`setup.sh` は
登録簿と `~/dotfiles/flake.nix` の両方から名前を拾うため。
コメントアウトした雛形の例は拾わない。

さらに、ここに足した名前は[**既定の対象ホスト**](#まとめて実行する)になる。登録簿からの
推測（`<user>@wsl` など）より優先するので、`tmp` のように登録簿と揃っていない
名前でも毎回 `h` や `--host` で選び直さなくてよい。複数足したときは一番上のものが
既定になるので、切り替えたいときは行を入れ替える。

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
（ただし `~/dotfiles/flake.lock` の張り直しが要る。[後述](#ローカル-flake-の-lock-も張り直す)）。
その代わり commit 忘れは CI で出る。

#### 使い捨ての 1 回きり

ファイルを残したくなければ `--impure` で直接組み立てる。

```sh
nix build --impure --expr '
  ((builtins.getFlake "path:'"${HOME}"'/ghq/github.com/pollenjp/dotfiles/nix").lib.mkHome {
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

# 適用 (既存ファイルは .bak へ退避。setup なら --backup=bak / メニューの b)
home-manager switch --flake ~/dotfiles#pollenjp@wsl -b bak

# 世代一覧とロールバック
home-manager generations
/nix/store/<older>-home-manager-generation/activate

# 本体を最新にしてから適用 (git pull -> switch)
~/dotfiles/setup --self-update --update

# 依存も更新してから適用 (nix flake update -> switch。lock は確認後に commit する)
~/dotfiles/setup --flake-update --update

# setup を通さない場合 (本体の flake.lock を触るのでリポジトリ側を指す)
nix flake update --flake ~/ghq/github.com/pollenjp/dotfiles/nix
```

> ⚠️ `-b bak` は `<file>.bak` が既に存在すると失敗する。リトライ時は古い `.bak` を先に消すこと。

## 管理対象のファイル

| 配置先 | 実体 |
| --- | --- |
| `~/.config/starship.toml` | `nix/files/starship.toml` |
| `~/.config/zellij/config.kdl` | `nix/files/zellij/config.kdl` |
| `~/.config/herdr/config.toml` | `nix/files/herdr/config.toml` |
| `~/.config/nvim/init.vim` | `nix/files/nvim/init.vim` |
| `~/.config/tmux/interactive_shell.tmux.conf` | `nix/files/tmux/interactive_shell.tmux.conf` |
| `~/.tmux.conf` | `nix/files/tmux/home.tmux.conf` |
| `~/.screenrc` | `nix/files/screenrc` |
| `~/.vimrc` | `nix/files/vim/vimrc` |
| `~/.vim/{common,clipboard}.vim` | `nix/files/vim/` |
| `~/.config/git/config` | `nix/home/modules/git.nix` (生成) |
| `~/.ssh/config` | `nix/home/modules/ssh.nix` (生成。Include の骨組みだけ) |
| `~/.config/git/ignore` | 同上 (`programs.git.ignores`) |
| `~/.local/bin/ssh` | `nix/files/bin/ssh-wsl.sh` (WSL + 1Password のマシンだけ。[後述](#wsl-では-ssh-自体を-windows-側に差し替える)) |
| `~/.local/bin/ssh-add` | `nix/files/bin/ssh-add-wsl.sh` (同上) |

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

> ⚠️ **`defaultKeyCommand` は `ssh-add` が Windows 側であることに依存している。**
> 鍵を持っているのはホスト側 Windows の 1Password なので、`ssh-add -L` が Linux の
> ssh-agent を引くと鍵が並ばず、署名鍵が見つからないまま `commit.gpgSign = true`
> だけが残る。`op-ssh-sign` のパス指定だけでは足りない。差し替えは
> [ssh ラッパー](#wsl-では-ssh-自体を-windows-側に差し替える)が行う。

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

なお **Claude のセッションからの commit だけは署名しない**。1Password の承認ダイアログで
止まるため。[Claude の commit を無署名にする](#claude-の-commit-を無署名にする)を参照。

## ssh について

`programs.ssh` で `~/.ssh/config` を**生成**しているが、中身は Include の 1 行だけ。
接続情報の実体は `.ssh` submodule にあり、`setup-ssh-config.sh` が
`~/.ssh/config.d/` へ symlink する。

```
Include config.d/*.ssh_config
```

（`ssh` は相対パスの `Include` を `~/.ssh/` 基準で解決する）

```sh
./nix/scripts/setup-ssh-config.sh
```

冪等。`setup.sh` では「新しいマシン適用」「既存マシン更新」の両方に入っている
ので、submodule を更新したら `--update` で張り直される。
submodule が未取得なら教えてくれる（処理は止めない）。

| `~/.ssh/config.d/` の中身 | 出所 |
| --- | --- |
| `*.ssh_config` (symlink) | `.ssh` submodule。スクリプトが張る |
| それ以外 | 手で置いたマシン固有の設定。スクリプトは触らない |

submodule 側でファイル名が変わった場合、参照先が消えた symlink はスクリプトが外す。
手で置いたファイルや、submodule 以外を指す symlink には触らない。

マシン固有の設定を足すときは `~/.ssh/config.d/` にファイルを置く。
`ssh` は同じキーワードについて**最初に得た値**を採るので、**ファイル名の順序が
優先順位**になる。実効値は `ssh -G <ホスト名>` で確認できる。

### ⚠️ 既存の `~/.ssh/config` がある場合

`main.bash` は `~/.ssh/config` に `Include` 行を**追記**していたので、多くのマシンでは
実ファイルとして存在する。home-manager はこれを上書きせず
`Existing file '...' would be clobbered` で中断する。

退避は [`--backup`](#既存ファイルを退避するか選ぶ) が行う（`~/.bashrc` などと同じ扱い）。
`~/.ssh/config` は `hm_managed_paths` に入れてあるので、指定が無ければメニューが訊いてくる。

**退避先の `~/.ssh/config.backup` は Include されないので、設定としては効かなくなる。**
残したい `Host` ブロックは中身を見てから `~/.ssh/config.d/` へ手で移すこと。

> 設計の経緯（中身を Nix で配らない理由、退避を `--backup` に一本化した理由、
> `config.d` へ移す案を棄却した実測）は
> [ADR 003](../docs/adr/003_nix_ssh_config_20260810T210714JST/README.md) を参照。

### WSL では ssh 自体を Windows 側に差し替える

1Password の ssh-agent は**ホスト側 Windows**にいる。この dotfiles は npiperelay や
socat で `SSH_AUTH_SOCK` を橋渡ししていないので、WSL 側の Linux ssh からは agent が
見えない。そこで `ssh` / `ssh-add` そのものを Windows 側の実体へ `exec` する
ラッパーに差し替える。

| 配置先 | 実体 | 何をする |
| --- | --- | --- |
| `~/.local/bin/ssh` | `nix/files/bin/ssh-wsl.sh` | `exec ssh.exe "$@"` |
| `~/.local/bin/ssh-add` | `nix/files/bin/ssh-add-wsl.sh` | `exec ssh-add.exe "$@"` |

置かれるのは **`wsl.onePassword.enable = true` のマシンだけ**（レガシーの
`main.bash` は `uname` と `ssh.exe` の有無で実行時に判定していたが、Nix 経路では
[登録簿](#マシン登録簿-hostsdefaultnix)の指定で決まる）。`$HOME/.local/bin` は
`home.sessionPath` で PATH の前に入るので、これがディストリの `ssh` より先に当たる。

Linux 側の ssh を使いたいときは `USE_LINUX_SSH=1` を渡す（ラッパー側の分岐）。

```sh
USE_LINUX_SSH=1 ssh <ホスト名>
```

**git の署名もこれに依存している。** `gpg.ssh.defaultKeyCommand` は `ssh-add -L` の
出力から `Signing` を含む鍵を選ぶので、`ssh-add` が Linux 側だと 1Password の鍵が
並ばない。詳細は[git について](#git-について)を参照。

> ⚠️ **`main.bash` 経路から移行するマシンでは、同じパスの symlink を先に外すこと。**
> `preflight-unlink.sh` が対象に含めているので、[手順 2](#新規マシンの手順) を
> 飛ばさなければよい。
>
> 外し忘れても複製が verbatim なので通常は通る（下表）。止まるのはどちらかを
> **編集していた場合**で、そのとき `-b` は効かないので手で外すしかない。
>
> | 旧 symlink | switch の挙動 |
> | --- | --- |
> | 生きている / 中身が同じ | 警告のみ（`will be skipped since they are the same`）で store のリンクに置き換わる |
> | 生きている / 中身が違う | `would be clobbered` で中断。**symlink は `-b <拡張子>` の退避対象外**なので手で外す |
> | リンク先が消えている | 警告も出ずに置き換わる |
>
> リンク先が消えている状態そのものは、switch する前が危ない。本体を ghq 配下へ移すと
> `~/dotfiles/bin/ssh-wsl.sh` が無くなるが、**bash は dangling な symlink を読み飛ばして
> PATH 探索を続ける**ので、エラーも警告も出ないままディストリの `ssh` にすり替わる
> （bash 5.2 で実測）。気づく合図が無いので、移行後は `command -v ssh` が
> `~/.local/bin/ssh` を指しているか確認するとよい。

Windows (Git for Windows) 用の `bin/ssh-*-git-for-win.sh` は移していない。
Windows は `main.bash setup` 経路のままなので、リポジトリ直下に残してある。

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

`programs.bash` が書き出すのは `~/.bashrc` / `~/.bash_profile` / `~/.profile` の 3 つ。
どれも symlink ではない実ファイルとして先に在るのが普通なので、初回の switch では
[退避するかどうか](#既存ファイルを退避するか選ぶ)を選ぶことになる。
`preflight-unlink.sh` の対象 (symlink) には入らない。

**`main.bash:199-219` の bash-completion 取得が不要になった。**
curl + tar で bash-completion 2.11 を落として `~/.bashrc` にローダ行を追記していたが、
`programs.bash.enableCompletion` が置き換える。

`~/.common_shellrc.sh` の source は維持している（マシンローカルの逃げ道。
[後述](#マシンローカルの環境変数-configpjpenv)）。

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
- `glfg` などの alias 連鎖（`glfg='glf --graph'`）は完全形に展開した（fish 側と同じ形）。
- `echo-PATH` / `echo-PATH-tr` / `echo-PATH-grep` / `git_get_default_branch` は
  alias から関数に変えた（動作は同じ）。

### 移植しなかったもの

`025_mingw` と `205_go_path` の cygpath 分岐（Windows は対象外）、`.bash/02_asdf.sh`
（asdf は使われていない）、`050_common` の `bindkey -v`（zsh 専用のガード付きで
bash では元々発火していなかった）。

## マシンローカルの環境変数 (`~/.config/pjp/env`)

そのマシンでしか使わない API キーのように、**tracked にできない環境変数**の置き場。
`$XDG_CONFIG_HOME` が設定されていればそちらが優先される。

`bash.nix` の `initExtra` と `fish.nix` の `interactiveShellInit` の両方に
ローダが入っていて、**ファイルが在れば読む / 無ければ何もしない**。
home-manager は作りも消しもしない（秘密情報なので store には置けない）。

ファイルを置くのは setup の手順 6.6 (`bootstrap-local-env`)。
**「新しいマシン適用」「既存マシン更新」の両方に含まれている**ので、普段は何もしなくてよい。

```sh
./nix/scripts/bootstrap-local-env.sh          # 実体
~/dotfiles/setup --steps bootstrap-local-env  # これだけ走らせる場合
```

初回だけ形式を書いたテンプレート（全行コメント = 実質空）を置き、`chmod 600` する。
**2 回目以降は中身に触らない。** 実際の API キーが入っているファイルなので、
上書きは一切しない（緩いパーミッションだけは 600 へ締める）。

### ⚠️ `home.sessionVariables` に書かないこと

あれは `/nix/store` 経由で `~/.config/environment.d/10-home-manager.conf` として
配置される。**`/nix/store` は誰でも読める**うえ、値は tracked な `.nix` にも残る。
秘密情報は必ずこのファイル側へ。

### 形式

```
# コメントと空行は無視される
FOO_API_KEY=sk-xxxx
BAR_TOKEN=abc def
```

- 行頭から `KEY=VALUE`、1 行 1 個、改行は LF
- **クォートしない。** `=` の後ろは行末までがそのまま値（`FOO='x'` は `'x'` になる）
- **展開もコマンド置換もしない。** `$X` は文字列 `$X` のまま
- 複数行の値は不可。要るなら `~/.common_shellrc.sh` 側へ

fish には値の展開が無く、bash の `set -a; . file; set +a` と同じ意味を再現できない。
そこで bash 側を `export "KEY=VALUE"`（引数を再スキャンしないので展開が起きない）に
して、**展開しない方へ両シェルを揃えてある**。flake の `shellHook` で使っている
`set -a; . ./.env; set +a` とは意味が違うので注意。

識別子で始まらない行は黙って読み飛ばす。壊れた行が混ざってもシェル起動のたびに
エラーを出さないため。

### `~/.common_shellrc.sh` との使い分け

| | `~/.config/pjp/env` | `~/.common_shellrc.sh` |
| --- | --- | --- |
| 中身 | **データ**（`KEY=VALUE` だけ） | **コード**（任意のシェル文） |
| 読むシェル | bash / fish | bash のみ |
| 用途 | マシン固有の環境変数・API キー | 緊急時に PATH を直書きする復旧経路 |

bash では `~/.config/pjp/env` → `~/.common_shellrc.sh` の順に読む。逃げ道から
env の値を上書きできるようにするためなので、順序を入れ替えないこと。

## Claude Code

`nix/files/claude/` 配下を `~/.claude/` へ配置する。

| 配置先 | 実体 | 単位 |
| --- | --- | --- |
| `~/.claude/CLAUDE.md` | `nix/files/claude/CLAUDE.md` | ファイル |
| `~/.claude/skills/pjp-<名前>/` | `nix/files/claude/skills/pjp-<名前>/` | ディレクトリ |
| `~/.claude/agents/pjp-<名前>.md` | `nix/files/claude/agents/pjp-<名前>.md` | ファイル |
| `~/.claude/commands/pjp-<名前>.md` | `nix/files/claude/commands/pjp-<名前>.md` | ファイル（サブディレクトリで名前空間も可） |

`nix/home/modules/claude.nix` が各ディレクトリを `readDir` で自動列挙するので、
**追加するときに `.nix` を編集する必要はない**（`README.md` は除外される）。
書き方は各ディレクトリの `README.md` を参照。

**このリポジトリは public なので、ここに置けるのは公開して差し支えないものだけ。**
公開できないものは次節の `claude-skills` へ置く。

### 命名: `pjp-` で始める

**自作のものは名前を `pjp-` で始める。** skill はディレクトリ名と `SKILL.md` の
`name` の両方（`pjp-drawio` `pjp-plantuml`）。agent / command も同じ。

`~/.claude/skills/` には Anthropic 配信・このリポジトリ・`claude-skills` の 3 系統が
同じ名前空間で並ぶ。prefix が無いと **一覧を見ても自分のものが判別できず**、
配信物は増減するので一般名詞（`dataviz` `run` `init` など）は将来ぶつかる。
`claude-skills` 側も同じ規約で、あちらは `scripts/lint.sh` が検査する
（こちら側に相当する検査は無い）。

### なぜディレクトリごとではなく中身を 1 つずつ symlink するのか

`~/.claude/` 配下は **Claude Code 自身が書き換える**。`skills/` には `manifest.json`
があり、Anthropic 配信の skill（`pdf` / `docx` / `xlsx` / `pptx` など）がここへ入る。
ディレクトリごと store の symlink にすると、それらの導入・更新が壊れる。

中身を 1 つずつ配置すれば、Claude Code 管理のものと**兄弟として並ぶ**だけで衝突しない。

```
~/.claude/skills/
├── manifest.json      <- Claude Code 管理 (実ファイル)
├── pdf/  docx/  ...   <- Claude Code 管理 (実ディレクトリ)
└── pjp-my-skill -> /nix/store/…   <- Nix 管理
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

### statusLine

Claude Code の下端に出る 1 行（`nix/files/claude/statusline-command.sh`）。

```
<model> · <dir basename> · <git branch>[*] · <context% left>
```

shell prompt（starship）が既に出しているもの（時刻・`user@host`・フルパス）は
意図的に繰り返さない。数百 ms ごとに呼ばれるので `jq` は 1 回にまとめて起動している。

#### 登録（マシンごとに一度だけ）

```sh
./nix/scripts/bootstrap-claude-statusline.sh
```

フックとまったく同じ事情で、**登録**だけが `settings.json` 側に残る。
スクリプト本体は Nix が配置し、`.statusLine` をそこへ向けるのがこのコマンド。
冪等で、他のキーは保持する。別の statusLine が設定されていたら元の値を
表示してから置き換える。

> ⚠️ `/statusline` で作った実ファイルが既に `~/.claude/statusline-command.sh` に
> 在るマシンでは、初回の switch が `would be clobbered` で止まる。
> 先に消す（または `-b` を付けて退避する）こと。

### Claude の commit を無署名にする

このマシンの git は 1Password の `op-ssh-sign` で署名する（[前述](#git-について)）。
署名のたびにホスト側 Windows の 1Password が承認ダイアログを出すため、Claude に
commit させるとそこで止まる。**Claude のセッションからの commit だけ**署名を外す。

#### 登録（マシンごとに一度だけ）

```sh
./nix/scripts/bootstrap-claude-env.sh
```

`~/.claude/settings.json` の `env` へ、git の config を環境変数の形で書く。

```json
"env": {
  "GIT_CONFIG_COUNT": "2",
  "GIT_CONFIG_KEY_0": "commit.gpgsign",
  "GIT_CONFIG_VALUE_0": "false",
  "GIT_CONFIG_KEY_1": "tag.gpgsign",
  "GIT_CONFIG_VALUE_1": "false"
}
```

git は `GIT_CONFIG_COUNT` / `GIT_CONFIG_KEY_<n>` / `GIT_CONFIG_VALUE_<n>` で渡された
config を **config ファイルより優先する**。そのため効き方がこうなる。

- **Claude のセッション（Bash tool）にだけ効く。** 自分の手元のターミナルからの commit は
  今どおり 1Password で署名される
- `git commit` 直打ちでも `--amend` でも `rebase --continue` でも `git tag` でも効く。
  「`--no-gpg-sign` を付ける」という指示と違い、忘れる余地が無い

Claude Code 自身も同じ仕組みで `credential.interactive=false` を注入するが、
**既存の `GIT_CONFIG_COUNT` を読んでその先に足す**実装なので競合しない。

冪等で、`env` の他のキーは保持する。無関係な `GIT_CONFIG_*` ペアが既にあれば順序を保って
残し、番号だけ 0 から振り直す（番号に穴があると git はその手前までしか読まない）。

**実行中のセッションにも入る**（このマシンでは再起動なしで反映された）。確認は
`env | grep GIT_CONFIG`、または Claude に `git config --get commit.gpgsign` を実行させて
`false` になること（自分のターミナルで実行すると `true` のまま）。入らなければ再起動する。

#### 採らなかった案

| 案 | 却下理由 |
| --- | --- |
| `CLAUDE.md` に「`--no-gpg-sign` を付ける」と書く | soft な指示なので忘れうる。全セッションでトークンも食う |
| repo local に `commit.gpgsign false` | 自分の commit も無署名になる。repo ごとに要る |
| `includeIf "gitdir:~/.herdr/worktrees/"` | worktree の外で Claude が commit すると効かず、逆に worktree で自分が commit すると無署名になる |
| `PreToolUse` で `git commit` を deny | 効くが bash 文字列の解析（複合コマンド・クォート）が要る。env で足りる |

> ⚠️ branch protection の "Require signed commits" が有効な repo では、Claude が作った
> commit は push で弾かれる。Claude が rebase / amend した既存 commit の署名も落ちる。

### private な skill 置き場 (claude-skills)

公開できない skill / agent / command は [`pollenjp/claude-skills`](https://github.com/pollenjp/claude-skills)（private）に置き、
**Nix ではなく `bootstrap-claude-skills.sh` が作業クローンへの symlink を張る**。

```sh
./nix/scripts/bootstrap-claude-skills.sh            # 取得 / 更新してリンクを張り直す
./nix/scripts/bootstrap-claude-skills.sh --status   # いま何が繋がっているか
~/dotfiles/setup --steps bootstrap-claude-skills    # 入口 (symlink) から呼ぶ場合
```

`$(ghq root)/github.com/pollenjp/claude-skills` へ clone し、`skills/` `agents/`
`commands/` の中身を 1 つずつ `~/.claude/<種類>/` へ symlink する。冪等なので、
skill を足したあとや別マシンの変更を取り込むときに何度でも実行してよい。
「既存マシン更新」にも入っているので、`--update` するだけで別マシンの変更が入る。

```
~/.claude/skills/
├── manifest.json      <- Claude Code 管理 (実ファイル)
├── pdf/ docx/ ...     <- Anthropic 配信 (実ディレクトリ)
├── <公開してよいもの> -> /nix/store/…                       (nix/files/claude/skills/)
└── <private>          -> ~/ghq/…/claude-skills/skills/…     (bootstrap-claude-skills.sh)
```

`nix/files/claude/` と同じく **中身を 1 つずつ**置く方式なので、3 系統が兄弟として
並ぶだけで衝突しない。同名のものが既にある場合は上書きせず警告して飛ばす。

#### 取得できないマシンでも止まらない

dotfiles は public なので、claude-skills を取れないマシン（鍵がまだ無い、メンバー
ではない、オフライン）でも setup を通したい。そのため**取得の失敗はエラーにせず、
警告を出して exit 0 する**。`setup.sh` は手順が 1 つでも失敗すると残りを走らせないので、
ここで落ちると後続の `bootstrap-*` まで巻き添えになる。

| 状況 | 挙動 |
| --- | --- |
| clone できない（鍵が無い / オフライン / `git` が無い） | `~/.claude/` には触らず、警告して終了 |
| clone はあるが pull できない | 手元のクローンの内容でリンクを張り直し、警告を添える |

取得できなかったときにリンクを**消しにいかない**のは重要で、掃除は「リンク先が
クローンの中を指しているか」で判定するため、クローンが無い状態で prune すると
別マシンで張ったリンクを全部消してしまう。

鍵が無いマシンで対話プロンプト（`known_hosts` の確認など）に固まらないよう、
`GIT_TERMINAL_PROMPT=0` と `ssh -o BatchMode=yes` で即座に失敗させている。

#### なぜ flake input にしないのか

**claude-skills は private で、この dotfiles は public。** flake input にすると:

- public な `flake.lock` に private repo の URL と rev が載る
- GitHub Actions の `nix flake check` が fetch できずに落ちる
  （deploy key か PAT をリポジトリに足さないと直らない）

加えて skill は試行錯誤しながら書くもので、store 管理だと 1 文字直すたびに
commit → push → `flake update` → `home-manager switch` が要る。作業クローンへ
symlink すれば編集がそのまま反映される（`nix/files/claude/skills/README.md` に
書いてある「試行錯誤中は直接置く方が早い」の問題がそもそも起きない）。

引き換えに rev の pin は無くなるが、pin したければクローン側で `git checkout <tag>` すればよい。

clone / pull はネットワークアクセスを伴うため `home.activation` には入れていない
（`bootstrap-mise.sh` と同じ理由。`home-manager switch` は hermetic に保つ）。

#### 掃除の判定

台帳は持たず、**リンク先が作業クローンの中を指しているか**だけで自分の張ったリンクを
判定する（`nix-managed-guard.sh` が `/nix/store` を指すかで判定しているのと同じ考え方）。
そのため Claude Code 管理のものや Nix 管理のものには触れない。
クローン先を引っ越した場合に備えて、最後に使ったパスだけ
`~/.local/state/dotfiles/claude-skills-dir` に控えている。

#### ⚠️ 反映されるのと commit されるのは別

store 管理ではないので `~/.claude/skills/<名前>/` は**書き込める**。`nix-managed-guard.sh`
も（`/nix/store` を指さないので）止めない。編集はそのまま効くが、実体は
claude-skills の作業クローンなので **commit / push しないと他のマシンには届かない**。

### 管理しないもの

`settings.json`（権限の「常に許可」などで書き換わる）、`skills/manifest.json` と
Anthropic 配信 skill、`plugins/`、実行時の状態（`projects/` `sessions/` など）、
`claude-skills` の中身（上記のとおり作業クローンへの symlink で繋ぐ）。

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
> `setup.sh` は `[tools]` に残っている名前を実行後の「残りの手作業」に並べる
> （片付いていれば何も出さない）。

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
cd ~/ghq/github.com/pollenjp/dotfiles/nix
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
│       ├── ssh.nix           ~/.ssh/config の骨組み + WSL の ssh ラッパー
│       ├── claude.nix        ~/.claude/ 配下 (readDir で自動列挙)
│       ├── starship.nix      programs.starship (設定は素のファイルのまま)
│       ├── mise.nix          mise 抑止マーカー
│       ├── shell-common.nix  bash/fish 共通 (sessionVariables / sessionPath / mise)
│       ├── fish.nix          abbr 88 / function 24
│       └── bash.nix          alias 88 / 関数 24
├── files/                 既存設定の複製 (store 管理される素のファイル)
│   └── bin/               WSL 用 ssh ラッパー (実行ビット付き)
└── scripts/
    ├── setup.sh                   「適用」の手順を選んで実行する (入口)
    ├── setup-local-flake.sh        ~/dotfiles にローカル flake と setup の symlink を置く
    ├── setup-ssh-config.sh         ~/.ssh/config.d/ を整える (switch より前)
    ├── verify.sh                   検証を一括実行する
    ├── preflight-unlink.sh         main.bash が張った symlink を外す (移行時に 1 回)
    ├── bootstrap-mise.sh           mise のグローバル設定を初期化する (マシンごとに 1 回)
    ├── bootstrap-claude-hook.sh    Claude Code のフックを登録する (マシンごとに 1 回)
    ├── bootstrap-claude-statusline.sh  Claude Code の statusLine を登録する (マシンごとに 1 回)
    ├── bootstrap-claude-env.sh     Claude の commit を無署名にする env を登録する (マシンごとに 1 回)
    ├── bootstrap-claude-skills.sh  private な skill 置き場を取得して繋ぐ (冪等)
    └── bootstrap-local-env.sh      ~/.config/pjp/env を置く (中身は上書きしない)
```
