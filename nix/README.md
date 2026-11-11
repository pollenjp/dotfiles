# nix (home-manager)

dotfiles を Nix home-manager で宣言的に管理するためのディレクトリ。

設定ファイルの実体は `nix/files/` にある。repo 直下にあった旧経路 (`main.bash setup`) から
複製して始めたもので、旧経路は [ADR 013](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/013_remove_legacy_tree_20261007T015646JST/README.md)
で削除した。以下で「移植元」「複製元」として挙げる旧経路のファイルは、git の履歴
(`git show 4a54c96:shell/250_alias.sh` など) で読める。

各ファイルの役割はここに写さず、そのファイルの先頭のコメントにだけ書く (テストは「## 確かめること」。
[後述](#テスト))。ディレクトリを辿れば分かるファイルの一覧も置かない。ファイルや option を足すたびに
直す所が増え、書き漏れるため。

## 対象範囲

| 対象 | 管理者 |
| --- | --- |
| dotfile 配置 | Nix home-manager |
| グローバルな CLI ツール | Nix home-manager |
| 言語ランタイム (node / go) | mise (プロジェクト毎の切替が必要なため) |
| プロジェクト毎のツール固定 | mise (`mise.toml`) |

対象 OS は **Linux / macOS / WSL**。Windows 側のアプリの設定は WSL から配る
（[後述](#windows-側のファイルを配る)）。Git Bash (MINGW/MSYS) の設定は管理しない。

対象シェルは **bash / fish**。zsh は Nix 管理の対象外。

## 置き場所

パスは 2 つある。**リポジトリ本体は ghq が決める場所に置き、日々の操作は
`~/dotfiles` から行う。**

| パス | 中身 | git |
| --- | --- | --- |
| `~/ghq/github.com/pollenjp/dotfiles` | リポジトリ本体 | 管理下 |
| `~/dotfiles` | ローカル専用の flake と `setup` への symlink | **管理外** |
| `~/ghq/github.com/pollenjp/dotfiles-private` | private な片割れ（ssh の接続先・辞書・登録した PC のホスト `nix/hosts/`。`setup` が取る） | 管理下（private） |

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
├── flake.nix   本体と dotfiles-private の nix/ を input として取り込み、homeConfigurations を再輸出する
├── flake.lock  nix が生成する
└── setup -> .../nix/scripts/setup.sh
```

dotfiles-private の `nix/` は、この PC を登録したホストを読むための 2 つ目の `path:` の入力（[後述](#dotfiles-private-に登録したホスト)）。
clone の `nix/` がまだ無いマシンでは、本体の空の stub（`nix/private-stub`）を指す。

以後はここから実行する。

```sh
~/dotfiles/setup                                  # メニュー
~/dotfiles/setup --update                         # 既存マシンの更新
home-manager switch --flake ~/dotfiles#<ホスト>
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

`~/dotfiles/flake.nix` は git 管理外なので、**このマシンにだけ要るホスト**（`tmp` など。dotfiles-private を読めない PC の
値を書く）を書く場所にもなる（[後述](#登録簿に載せずにマシンを足す)）。足さなくても、入口を 1 つに揃えるために常に置く。

WSL の PC で雛形を描くと（初回・`--force`・`--initial`）、`tmp` の例（コメント）の `windowsUserName` に、この PC の Windows の
ユーザー名が入る（[後述](#足したホストに書く値)）。初回と `--force` では、引けなくても止めずに作り物の名前のまま書き、そのことを
1 行出す（`--initial` は今までどおり、引けなければ書かずに止まる）。

SSH 鍵 (1Password) も gh のログインもまだの新しい WSL の PC は、`--initial` を付けて初期用のホスト `initial` も書く
（Windows のユーザー名は自動で引く。[後述](#新しい-wsl-の-pc)）。

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
| skill 側の `flake.lock`（`pjp-d3js` / `pjp-drawio` / `pjp-plantuml`） | `flake-lock-age.sh update <そのディレクトリ>` | 手で実行（`setup` は本体しか見ない） |
| `pjp-d3js` の `package-lock.json`（d3・Observable Plot・linkedom） | `npm install --package-lock-only`（skill の `SKILL.md`「版」） | 手で実行（`setup` も CI も見ない） |
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
| 未 commit の変更がある | 作業中の変更を巻き込みたくない |
| detached HEAD / upstream 無し | どこへ進めるべきか決められない |
| fast-forward できない | rebase か merge かの判断はしない |

`dotfiles.claude.gitViaGh.enable` のマシンでは、origin が GitHub の ssh の URL（`git@github.com:…`）なら、
この `fetch` も gh の資格情報で先に試し、だめなら ssh で取り直す（[setup の取得も gh で先に試す](#setup-の取得も-gh-で先に試す)）。
https で clone した本体は、今までどおり `git` で取る。

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
> error: unexpected fragment 'pollenjp@x86_64-linux' in flake reference '~/dotfiles#pollenjp@x86_64-linux'
> ```

#### 新しすぎる revision を pin しない (minimumReleaseAge 相当)

上げ先は追跡先の**先端ではなく、公開から猶予の日数 (既定 7 日) 以上経った revision**。
出たばかりのものを掴まないための遅延で、npm / pnpm の `minimumReleaseAge` に相当する。
決めているのは [`scripts/flake-lock-age.sh`](./scripts/flake-lock-age.sh)。日数と、期間付きの例外は
[`release-age.nix`](./release-age.nix) に書く（[後述](#猶予の日数と例外-release-agenix)）。

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

`update` は `nix flake update` を、`flake.nix` と `flake.lock` だけを写した一時ディレクトリで打ち、出来た
`flake.lock` を戻す（`nix flake update` が読むのはこの 2 つだけ）。flake のディレクトリを素のパスで渡すと、
git の repo の中では nix が repo 全体（追跡しているファイル。commit していない変更も）を `/nix/store` へ写し、
作業ツリーが変わるたびに写しが増えるため。相対パスの input（`path:./x` など）を持つ flake だけは、写した先から
辿れないのでその場で update する。新しく作った lock は、git の作業ツリーの中なら `git add --intent-to-add` する
（nix がその場で作るときと同じ。追跡していない lock は素のパスで読む nix に見えず、先端で作り直される）。

`flake.lock` がまだ無い flake でも `resolve` / `update` は通る（input の一覧を
`flake.nix` の `inputs` から読む）。**flake を新しく足したときの 1 本目の lock も
`update` で作ること。** 先に `nix flake lock` を打つと一度先端へ pin されるので、
遅延が最初から外れた lock を commit することになる（`check` も落ちる）。

ディレクトリを省くと `nix/` が対象。**リポジトリ内の flake は本体だけではない**ので、
まとめて見るときは並べて渡す（CI の `lock-age` はこの形で回している）。

```sh
./nix/scripts/flake-lock-age.sh check \
  ./nix \
  ./nix/files/claude/skills/pjp-d3js \
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
`references/lock-age.md`。他リポジトリの猶予の日数と例外は、その flake の隣の `release-age.nix` に書ける
（[後述](#ほかのリポジトリの猶予と例外)）。

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

普段の日数は `release-age.nix` の `minimumReleaseAgeDays`。その場だけ変えるなら `--min-age-days N` か
`FLAKE_MIN_RELEASE_AGE_DAYS`（`setup.sh` 経由のときは `DOTFILES_MIN_RELEASE_AGE_DAYS`。一族の名前を保つため、
あちらが橋渡しする）。効く順は `--min-age-days` > 環境変数 > `release-age.nix` > 7 で、どれが効いたかは
`==> ./nix (下限 7 日。設定 release-age.nix (flake の隣))` の行に出る（日数を替えたときは
`(下限 0 日。--min-age-days。設定 release-age.nix (flake の隣))` のように、日数の出どころと設定を並べる）。

```sh
./nix/scripts/flake-lock-age.sh --min-age-days 14 update
./nix/scripts/flake-lock-age.sh --min-age-days 0  update  # 遅延なし = 先端
DOTFILES_MIN_RELEASE_AGE_DAYS=0 ~/dotfiles/setup --steps flake-update
```

設定は flake ごとに次の順で探し、最初に見つかった 1 つだけを読む
（[ADR 037](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/037_release_age_beside_flake_20261027T001056JST/README.md)）。

| 順 | 設定 | 見出しの行 |
| --- | --- | --- |
| 1 | `--config FILE`（渡した全部の flake に効く） | `設定 <FILE> (--config)` |
| 2 | 対象の flake の隣の `release-age.nix`（dotfiles の `nix/` なら `nix/release-age.nix`。他のリポジトリはここに書く。`nix run` で呼んでも読む） | `設定 release-age.nix (flake の隣)` |
| 3 | script の隣の `../release-age.nix`（チェックアウトから叩いたときの dotfiles の `nix/release-age.nix`。隣に設定の無い skill の flake などは、これを借りる） | `設定 <パス> (script の隣)` |
| 4 | どれも無い（7 日で、例外は無い） | `設定なし` |

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

##### 猶予の日数と例外 (`release-age.nix`)

セキュリティパッチが猶予より新しい側にしか無いときは、理由を書いた**期間付きの例外**を
[`release-age.nix`](./release-age.nix) に足す（[ADR 032](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/032_nixpkgs_release_age_exceptions_20261024T140555JST/README.md)・
[設計](https://github.com/pollenjp/dotfiles-private/blob/main/docs/superpowers/specs/2026-10-24-nixpkgs-release-age-exceptions-design.md)）。例外は dotfiles 全体（登録した全 PC と CI）に効く
（他のリポジトリは、その flake の隣に書く。[後述](#ほかのリポジトリの猶予と例外)）。
`date` は「その時までの公開を使う」と読み、2 つの書き方がある
（[ADR 038](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/038_release_age_timestamp_20261027T084524JST/README.md)）。

| `date` の書き方 | どこまでの公開を使うか |
| --- | --- |
| `"2026-10-23"`（`YYYY-MM-DD`） | その日（Asia/Tokyo）の終わり（23:59:59 +09:00）まで |
| `"2026-10-23T18:20:00+09:00"`・`"2026-10-23T09:20:00Z"`（時差を書いた RFC 3339 の timestamp。時差は `Z`・`+HH:MM`・`-HH:MM`） | その時刻まで。時差の無い timestamp（`"2026-10-23T18:20:00"`）は、どちらの時間か決まらないので止まる |

`flake-lock-age.sh` の `resolve`・`update` は公開の時刻を `公開 2026-10-23 18:20:00 JST (09:20:00 UTC)` の形で出す
（UTC の日付が違えば `公開 2026-10-24 02:00:00 JST (2026-10-23 17:00:00 UTC)` のように日付から）。JST の日付か、時刻に `+09:00` を付けたものを、そのまま
`date` に写せる。`check` が出すのは `commit …` の時刻（lock の `lastModified`。公開より前）なので、写す元にしない。

| 例外 | 欄 | 何をするか |
| --- | --- | --- |
| 全体 | `exceptions.all`: `date`・`reason` | `flake-lock-age.sh` が `nixpkgs` を `date` までの公開から選ぶ（猶予より新しいときだけ。`home-manager` などほかの input は猶予のまま）。`check` も `date` までの pin を通す |
| 一部 (nixpkgs から) | `exceptions.fromNixpkgs`: `packages`・`date`・`reason` | `packages` だけを input の `nixpkgs-exceptions`（`date` までの公開）から取る。ほかは普段の pin のまま |
| 一部 (upstream から) | `exceptions.fromUpstream`: `package`・`version`・`reason` | `package` を upstream の配布物から取る（nixpkgs のどの公開にも修正版がまだ無いとき）。中身は `pkgs/upstream/<package>.nix` |

```nix
# nix/release-age.nix (例。値は作り物)
{
  minimumReleaseAgeDays = 7;
  exceptions = {
    all = [ { date = "2026-10-23"; reason = "CVE-…: openssl 3.x.y の修正が 2026-10-22 の公開に入った"; } ];
    fromNixpkgs = [ { packages = [ "foo" ]; date = "2026-10-23T18:20:00+09:00"; reason = "CVE-…: foo 1.2.3 の修正"; } ];
    fromUpstream = [ { package = "mise"; version = "2026.10.17"; reason = "CVE-…: nixpkgs#… を待つ間"; } ];
  };
}
```

足したあとの手順:

| 例外 | 手順 |
| --- | --- |
| 全体 | `./nix/scripts/flake-lock-age.sh update`（閉包のスキャンも挟まる）→ `nix/flake.lock` と `release-age.nix` を commit。CI の `lock-age` は例外の分だけ新しい pin を通す |
| 一部 (nixpkgs から) | `./nix/scripts/flake-lock-age.sh update --input nixpkgs-exceptions`（普段の pin は動かさない。全部を上げてよければ素の `update`）→ commit |
| 一部 (upstream から) | `pkgs/upstream/<package>.nix` を書く（release の配布物を `fetchurl` と sha256 で固定する。実例は `pkgs/upstream/mise.nix`）→ commit。`flake.lock` は変わらない |

- **一部の例外（nixpkgs から・upstream から）に書けるのは、ほかの package から使われないアプリだけ**で、top-level の名前
  （`pkgs.<名前>`）に限る。home の pkgs に overlay で当てるので、`programs.<名前>` や `home.packages` を書き換えずに
  差し替わる（mise なら `programs.mise` の既定の package）。ライブラリ（openssl・nss・cacert・`python3Packages.certifi`
  など）を差し替えると、依存側が組み直されて binary cache が外れ、新旧の pin の版が混ざる。これらは**全体**で扱う。
  flake の check（`release-age-state`）が、例外を当てた home と当てない home の `home.packages` の drvPath を比べ、
  差し替えた package をほかの package が使っていたら名前を出して落ちる
- `nixpkgs-exceptions` は、効いている一部 (nixpkgs から) の項目が無いあいだは `nixpkgs` と同じ revision にしておく
  （`flake-lock-age.sh` がそう選ぶ）。評価もそのあいだはこの input を読まないので、普段の道は重くならない
- 書き誤り（知らない欄・暦に無い日付・時差の無い timestamp・時刻や時差の誤り・空の `reason`・入れ子の名前・pkgs に無い名前・
  同じ package を 2 回・`pkgs/upstream/<package>.nix` が無い・その版と `version` が違う）は、home の評価で止まる（CI の `check`
  も落ちる）。`flake-lock-age.sh` も、どのリポジトリの設定でも、欄の形（知らない欄・型・無い欄・空の `reason`）と `date`（形・
  時差・時刻・暦・今日（Asia/Tokyo）より先の日付・今より先の timestamp）を確かめ、全部をまとめて出して、どの flake を選ぶ・
  確かめるより前に止まる（CI の `lock-age` も落ちる）。先の `date` を止めるのは、打ち間違いだと、その時まで猶予が外れたまま
  先端を取り続け、`check` も通ってしまうため
- `--input <名前>` を付けても、lock に無い github の input（flake.nix に足したばかりのもの）は一緒に選ぶ
  （`nix flake update` は lock に無い input を先端で足すため）

**消し時。** 例外は要らなくなると何もしなくなり、home の評価が `nixpkgs の例外 …` で始まる警告を出す。setup は switch の後に
[警告のまとめ](#途中の警告のまとめ)へ写し、CI の `check` ジョブは落とさずに annotation で出す。自動では消さないので、PR で消す
（消し忘れても害は無い）。判定は今日の日付ではなく pin の日時と package の版で決める（home-manager の評価は今日の日付を読めない）。

| 例外 | 何もしなくなる（消し時） |
| --- | --- |
| 全体・一部 (nixpkgs から) | 普段の pin（`nixpkgs`）の commit の日時が、`date`（日付ならその日の終わり、timestamp ならその時刻）を越えた（おおよそ `date` + 猶予の日数のあとの `update` で） |
| 一部 (nixpkgs から) で `nixpkgs-exceptions` がまだ普段の pin より新しくない | 「まだ何もしていない」と出る。`update --input nixpkgs-exceptions` で選び直す |
| 一部 (upstream から) | 普段の pin の nixpkgs のその package の版が、`version` 以上になった。その system の配布物が無いときも nixpkgs のままで、その旨が出る |

commit の日時は公開の日時より古い側に出るので、公開で選ぶ `update` より消し時の判定は少し遅れる（早めに言うことは無い）。

`flake-lock-age.sh` も、何もしなくなった全体の例外に `例外 (全体) <date>: 何もしない (猶予 N 日の方が新しい。消してよい)` の行を
出す（`resolve`・`update` と `check`。こちらは今日と猶予の日数で決める）。home の評価の無い他のリポジトリでは、これが消し時の
知らせになる。

##### ほかのリポジトリの猶予と例外

他のリポジトリ（`nix run` で `flake-lock-age` を呼ぶもの）も、**flake の隣（`flake.nix` と同じディレクトリ）に
`release-age.nix` を置けば**、猶予の日数と全体の例外を書ける（[ADR 037](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/037_release_age_beside_flake_20261027T001056JST/README.md)）。
`resolve`・`update`・`check` のどれも読むので、CI の手順（`nix run … -- check`）は変えなくてよい。例外が理由とともに
リポジトリに残り、`--min-age-days` を付けずに `update` を打っても、猶予の決まりで直しの前の版へ戻さない。

```nix
# <flake のディレクトリ>/release-age.nix (例。値は作り物)
{
  minimumReleaseAgeDays = 7; # 普段の猶予 (日)。書かなければ 7
  exceptions.all = [
    { date = "2026-10-23"; reason = "CVE-…: openssl 3.x.y の修正が 2026-10-23 の公開に入った"; }
  ];
}
```

- 書けるのは `minimumReleaseAgeDays` と `exceptions.all`。一部の例外（`fromNixpkgs`・`fromUpstream`）は dotfiles の home の
  overlay が input `nixpkgs-exceptions` と組んで当てる欄なので、その input の無い flake の設定に書くと `flake-lock-age` が
  止める（何もしないのに、効いているつもりの記録が残るため）
- `date` には、入れたい修正の入った公開を、`resolve`・`update` の `公開 … JST (… UTC)` の行から写す。JST の日付
  （`"2026-10-23"`。その日の終わりまで）か、時刻に時差を付けたもの（`"2026-10-23T18:20:00+09:00"`。その時刻まで）。足したら
  `update` で選び直し（ほかの github input は猶予どおりに選び直す）、`flake.lock` と `release-age.nix` を commit する
- 消し時は、おおよそ `date` + 猶予の日数のあと。`update`・`check`（CI の出力）に `例外 (全体) <date>: 何もしない (… 消してよい)`
  と出たら、PR で項目を消す
- 書き誤りは上と同じく `flake-lock-age` が止める。手順の細部（CI・新しいリポジトリへの入れ方）は `pjp-nix-flake` skill の
  `references/lock-age.md`

##### 遅延を外す

緊急の CVE 修正を先端から入れたいときは、まず[猶予の例外](#猶予の日数と例外-release-agenix)を考える（全体・一部を
日付で区切れて、CI の `lock-age` も通る）。それでも全体を先端へ上げるなら `--min-age-days 0` で `update` する。
その commit では CI の `lock-age` が落ちるが、**それは意図どおり**。通したいときは
`workflow_dispatch` の `min_release_age_days` に `0` を入れて再実行する。

mise で入れるもの（言語ランタイム・`claude`・各 repo の `mise.toml` のツール）の遅延は別の口で、期間を区切って
緩められる（[遅延を期間付きで緩める](#遅延-minimum_release_age-を期間付きで緩める)）。

#### 閉包のスキャンと pin↔先端の差分 (遅延の補完)

上の遅延は「未発覚の侵害を誰かが先に踏む時間」を稼ぐ一方、**発覚済みの侵害
バージョンを下限日数のあいだ固定し続ける**というリスクを新しく作る。それを塞ぐ
道具が 2 つある（なぜこの組み合わせなのかは
[ADR 006](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/006_nix_closure_sbom_osv_scan_20260823T004634JST/README.md)）。

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

どれも照らしたあとに findings の表（whitelist に無いもの。受け入れたものは件数だけ）を出し、成果物の
`report.txt` に残す（CI は summary に貼る）。表は `vulns.csv` から作る（vulnxscan も表を出すが、版によって
stdout にも stderr のログにも出るので拾わない）。findings が 0 件なら「なし」と書く。

回るタイミングは 3 つ。

| いつ | 形 |
| --- | --- |
| `flake-lock-age.sh update` の完了時（自動） | whitelist があれば `scan`、無ければ `report`。**新しい pin を初めて実行する前に必ず照合が挟まる** |
| PR / push の CI | `scan`（ゲート） |
| 毎日の定期実行 | `scan`（pin 更新が無い期間も advisory の増分を照合） |

対象の属性は flake で変わる。dotfiles 本体は home 閉包
（`homeConfigurations.sandbox`）、それ以外の flake は `devShells.<system>.default`
（「これから実行するツール」は devShell に入っているものなので）。`--attr` で変えられる。

flake だけのディレクトリ（下にディレクトリを持たない）は `path:` で読む（git の repo の中でも、repo を
`/nix/store` へ写さない）。下にディレクトリを持つ flake（本体の `nix/`・skill のディレクトリ・repo の root）は
素のパスで読む（`path:` は git を見ずにディレクトリの中身を全部写すので、書き出しや `.git` まで写さないため）。

落ちたときの対応は 2 択。

1. **pin を動かして直るか見る** — `flake-lock-age.sh resolve / update`。修正が
   下限より新しい側にしか無いなら、[猶予の例外](#猶予の日数と例外-release-agenix)を足す（全体・一部）か
   [遅延を外す](#遅延を外す)判断まで含む
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
nixpkgs** から組む。スキャナ自身の版も同じ遅延ポリシーに従わせるための形。対象の
pin で組めなければ、次の順に退いて、最初に組めたもので照らす（[ADR 040](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/040_closure_scan_sbomnix_fallback_20261102T021114JST/README.md)）。

| 順 | 組む pin | 試すとき |
| --- | --- | --- |
| 1 | 対象 flake の pin | いつも |
| 2 | dotfiles の pin | 対象と違う pin のときだけ。チェックアウトから叩けば script の隣の `nix/flake.lock`、`nix run` の app なら app を組んだときの `nix/flake.lock` |
| 3 | 対象の `flake.lock` の git の履歴にある前の pin | first-parent（merge された pin）を新しい順に 3 つまで（読めない `flake.lock` も 1 つと数える）。dotfiles 自身のスキャン（CI・setup の `flake-update`）は 2 が対象と同じ pin になるので、ここで前の pin へ退く |

2 と 3 も遅延を守って入れた pin（今の pin と同じか古い）なので、どこから取っても
スキャナの遅延は守られる。nixpkgs で sbomnix の依存が壊れた pin（2026-10 の
typepy 2.0.0 で sqliteschema が組めなかった）でも、スキャンそのものを落とさない
ための退き先で、findings の判定は変わらない。

- 1 で組めず退いたら、警告を出す（stderr と setup の警告のまとめ。CI では annotation）
- どの sbomnix をどの pin から取ったかは、毎回成果物の `scanner.txt` に残る（CI は
  summary に貼る）。退いたなら、組めなかった pin とわけ（最初に組めなかった derivation か、
  2・3 の `flake.lock` を nix で読めなかったわけ）も
- CI の `closure-scan` は 3 のために履歴を全部取る（`fetch-depth: 0`）。浅い clone では
  前の pin をたどれない
- どれでも組めなければ、試した pin とわけを並べて止まる。組める版の sbomnix を PATH に
  置けば、それで照らす（PATH にあれば組まない）

dotfiles 本体の既定対象 `homeConfigurations.sandbox` は、パッケージ集合が
全ホスト共通（ホスト差は設定側にしか無い）なので x86_64-linux の代表として使う。
skill 側 flake（`pjp-d3js` / `pjp-drawio` / `pjp-plantuml`）は `update` 時の自動スキャン
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
`path:` の入力は本体（`dotfiles`）と dotfiles-private の `nix/`（`dotfiles-private`。[前述](#dotfiles-private-に登録したホスト)）の
2 つで、合っていない入力だけをまとめて張り直す（dotfiles-private の `nix/` も、取得や手での編集で変わる）。

手でやるなら input 名を指定する。張り直すと本体の新しい pin も推移的に伝わる
（`Updated input 'dotfiles/nixpkgs'`）。

```sh
nix flake update dotfiles --flake ~/dotfiles
nix flake update dotfiles-private --flake ~/dotfiles   # dotfiles-private の nix/ を直した・取ったとき
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
  対象ホスト: <user>@<hostname>  (dotfiles-private / h で変更)
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
| 新しいマシン適用 | 1 → 2 → 2.4 → 2.5 → 3 → 4 → 4.1 → 6 → 6.1 → 6.2 → 6.3 → 6.5 → 6.6 → 6.7 → 6.8 → 6.9 |
| 既存マシン更新 | 2.4 → 3 → 4 → 4.1 → 6 → 6.1 → 6.2 → 6.3 → 6.5 → 6.6 → 6.7 → 6.8 → 6.9 → 7.5 → 8（**冪等な手順は全部走る**。下記） |
| カスタム | 手順を 1 つずつチェックして選ぶ |

2.4 `private-fetch` は dotfiles-private を **switch の前に** 取る（clone があれば取得して fast-forward する。clone が無ければ何もせず、
switch のあとの `bootstrap-dotfiles-private` が clone する）。登録したホストの値を直して push したあと、`--update` 1 回でその値で
switch させるため（[後述](#dotfiles-private-に登録したホスト)）。取れなくても止めない。

「既存マシン更新」は `switch` に加えて `bootstrap-*` と `wsl-mtu-guard`・`exe-exec-trace` を
毎回走らせる。どれも冪等（「既に同じなら何もしない」「既に在れば中身に触らない」）なので、
繰り返しても状態は変わらない。走らせないと、スクリプトを足したときや別マシンで変えたとき
（`claude-skills` など）にそのマシンだけ取り残され、取り込むには `--steps` に名前を
並べるしかなくなる。時間が気になるとき・一部だけ走らせたいときは「カスタム」か
`--steps` で選び直す。

7.5 `wsl-mtu-guard` と 8 `exe-exec-trace` は中で `sudo` を呼ぶが、呼ぶのは unit を入れる・入れ替える・消す・
止まっているのを起こすときだけで、揃っていれば（option が無効なマシンも）呼ばない。
`sudo` がパスワードを訊けないとき（パスワード無しで通らず、端末も無い。Claude の Bash
ツールから打ったときなど）は失敗にせず飛ばし、最後の「残りの手作業」がずれを知らせる
（[後述](#wsl-の-eth0-の-mtu-を上限まで下げ続ける)・[後述](#wsl-の-exe-の起動を常時記録する)）。
setup は失敗した手順で止まるので、7.5 を 8 より前に置いている（トレーサが起動に失敗しても、MTU の見張りは入れ替わる）。

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

対象ホストは次の順で決める。違うものを使うなら `h` で選び直すか `--host <名前>`（`DOTFILES_HOST` も同じ）。

1. `~/dotfiles/flake.nix` が定義しているホスト（`tmp` など。[登録簿を上書きする側](#登録簿に載せずにマシンを足す)）
2. dotfiles-private に登録したこの PC のホスト（`nix/hosts/<user>@<短い hostname>.nix`。ローカル flake が clone の `nix/` を
   読んでいるときだけ。[後述](#dotfiles-private-に登録したホスト)）

1 を先に見るのは、あちらが登録簿を `//` で上書きするための場所だから。名前を書いた時点で「このマシンはこれ」という
意思表示になる。複数書いてあるときは**一番上**のものを採る（既定を変えたいときは行を入れ替える）。2 はその PC の値の
全部を持つホストなので、登録した PC では `--host` を付けなくてよい。ローカル flake・dotfiles-private 由来のときはヘッダに
`(ローカル flake)`・`(dotfiles-private)` と出る。`--host`・`DOTFILES_HOST`・`h` で、この PC を登録した名前と違うホストを選ぶと
警告する（止めない。最後の警告のまとめの `[対象ホスト]` にも載る）。

**どちらも無ければ推測せずに止まる**（終了コード 1。[ADR 027](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/027_stop_guessing_host_20261021T143517JST/README.md)）。
前は `$USER` と `uname` から型のホストを推測していたが、登録した PC でもローカル flake が clone を読んでいないだけで型の
ホストになり、git の署名などの値が黙って外れた。止めるときは選べる道を出す。

| 選べる道 | 向く PC |
| --- | --- |
| この PC を dotfiles-private に登録する（Claude Code で `pjp-dotfiles-register-host` skill） | dotfiles-private を読める PC。登録の前の 1 回は 3 で当てる（[新しいマシン](#新規マシンの手順)） |
| `~/dotfiles/flake.nix` に `tmp` を足す（[後述](#登録簿に載せずにマシンを足す)） | dotfiles-private を読めない PC。足したホストが既定の対象ホストになる |
| `--host <型>` を付ける（型は登録簿の `<user>@<system>`。`sandbox` は出さない） | 登録の前の 1 回・試しに当てるとき。型には WSL・1Password の署名・Dev Tracker などの PC の値が無いので、それらを使う PC で当て続けると外れる |
| `setup-local-flake.sh --initial` で初期用のホスト `initial` を書く（[後述](#新しい-wsl-の-pc)） | SSH 鍵も gh のログインもまだの、新しい WSL の PC。1 回目から Windows のアプリまで入る。登録したら外す |

clone にこの PC のファイルがあるのにローカル flake が読んでいない（入力が無い・本体の stub を指す）ときは、先にそれと
読ませ方（`local-flake-migrate.sh prepare` で今の雛形へ移す。ローカル flake がまだ無ければ `--steps local-flake`）を出す。

止める時機は 2 つ。自動で決めたホストは `private-fetch`（dotfiles-private の取得）と `local-flake` のあとで決め直す
（この実行で作ったローカル flake・取ってきた登録を、同じ実行の switch に効かせる。変われば「対象ホストを選び直した」と出る）
ので、それで決まりうるときは手順を流し、決まらなければ switch の頭で止まる。決まりようがないとき（Nix が無い新しいマシン・
clone が無い・その手順を選んでいない・登録してあるのにローカル flake が読んでいない）は、手順を 1 つも流さずに止まる
（Nix を入れてから・`preflight-unlink` が symlink を外してから止まらないように）。`preflight-unlink` を流す「新しいマシン適用」
（`--new-machine`）では、登録が取得で来るかもしれないだけのときも先へ進まない（clone にこの PC のファイルが今あるときだけ進む）。
`--dry-run` では取得・ローカル flake の手順が流れないので、それに頼る決め直しは switch の行で「決め直せない」と出すだけにする。

どのホストをどう決めたかは `--which-host` で見られる（`<ホスト><TAB><決め方>`。決め方は `--host`・`DOTFILES_HOST`・`local`・
`private`・`menu`。決まらなければ選べる道を出して 1）。

自動化していないのは手順 0（マシンの登録）と
手順 5（mise の `config.toml` 整理）だけ。手順 7 (`chsh`) は
「必要なら」なのでプリセットには入れていないが、カスタムから選べる。

メニューを出さずに実行することもできる。

```sh
~/dotfiles/setup --new-machine            # 「新しいマシン適用」と同じ
~/dotfiles/setup --update                 # 「既存マシン更新」と同じ
~/dotfiles/setup --steps switch,bootstrap-mise
~/dotfiles/setup --list                   # 手順の id 一覧
~/dotfiles/setup --which-host             # 対象ホストと決め方 (自動判定の結果) を見るだけ
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

#### bootstrap の実行順

`bootstrap-*.sh` は glob で自動列挙するので、**スクリプトを足しても `setup.sh` の編集は
要らない**。並びは既定では辞書順だが、それでは表せない依存がある。
`bootstrap-claude-plugins.sh` は `claude` を要求し、その `claude` を入れるのは
`bootstrap-mise.sh` なのに、辞書順では mise が最後尾に来てしまう。

そこで**スクリプト自身のヘッダ**に順序を書く。説明文を冒頭コメントから取っているのと
同じ考え方で、順序を `setup.sh` 側の一覧に持つと二重管理になるため。

```sh
# order: 10
```

小さいほど先に走る。**書かなければ 50** に落ちて従来どおり辞書順に並ぶので、
新しいスクリプトを足すときに意識する必要はない。同じ値のものは辞書順を保つ。

| スクリプト | order | 理由 |
| --- | --- | --- |
| `bootstrap-mise.sh` | 10 | `claude` を入れる |
| `bootstrap-claude-plugins.sh` | 20 | その `claude` を使う |
| その他 | 50（既定） | 依存なし |
| `bootstrap-dotfiles-private.sh` | 50 | private な dotfiles-private を取る。中身を読む `bootstrap-ssh-config.sh` (60)・`bootstrap-windows-ssh-config.sh` (91)・`bootstrap-windows-google-ime.sh` (98)・`bootstrap-windows-port-forward.sh` (99) より先ならよい (既定と同じ値を書いてある)。clone があれば、手順 2.4 `private-fetch` が同じ script を switch の前にも流し、そのときはこの手順を飛ばす |
| `bootstrap-claude-accounts.sh` | 60 | `bootstrap-claude-skills.sh`（50）が `~/.claude/skills` へ張ったリンクを写す |
| `bootstrap-claude-skill-overrides.sh` | 60 | `bootstrap-claude-skills.sh`（50）が張った skill の `SKILL.md`（pack の割り当て）と入口の skill（`pjp-pack-<pack>`）を読む（[後述](#skill-の一覧を枠に収める-pack-と同期された-skill)） |
| `bootstrap-herdr-hub.sh` | 60 | `bootstrap-claude-skills.sh`（50）が張った skill `pjp-herdr-hub` の `hub-init.sh` を打つ（[後述](#herdr-の集約ハブ-h)） |
| `bootstrap-ssh-config.sh` | 60 | dotfiles-private（50）の `ssh/*.ssh_config` を `~/.ssh/config.d/` へ張る（[後述](#ssh-について)） |
| `bootstrap-dev-tracker-inbox.sh` | 70 | `bootstrap-claude-skills.sh`（50）が claude-skills を進め、`bootstrap-herdr-hub.sh`（60）が `~/h` を作った後に、見回り役 `pjp-dev-tracker-inbox` を起こし直す（[後述](#チケットのコメントをハブの会話へ届ける見回り役-pjp-dev-tracker-inbox)） |
| `bootstrap-windows-files.sh` | 90 | 衝突で exit 1 しても、90 より前の bootstrap は済んでいる (setup は失敗した手順で止まるので、後ろの 91〜99 と wsl-mtu-guard・exe-exec-trace、最後の「残りの手作業」は、直して流し直すまで走らない) |
| `bootstrap-windows-powertoys.sh` | 91 | `bootstrap-windows-files.sh` が置いた `Install-PowerToys.ps1` で PowerToys が入っているかを確かめ (無ければ入れる)、Keyboard Manager と自動起動がオフならオンにして PowerToys を起動し直し、置いた `default.json` を Keyboard Manager に読み直させる (exit 1 にしない) |
| `bootstrap-windows-ssh-config.sh` | 91 | dotfiles-private（50）の `ssh/*.ssh_config` を Windows の `%USERPROFILE%\.ssh` へコピーし、`config` を置く。衝突や、書いたあとの確かめの失敗で exit 1 する（後ろの 92〜99 と wsl-mtu-guard・exe-exec-trace は、直して流し直すまで走らない） |
| `bootstrap-windows-fancyzones.sh` | 92 | `bootstrap-windows-powertoys.sh` (91) が PowerToys を入れた後に、`win/powertoys/fancyzones/managed.json` のキーだけを FancyZones の `settings.json` へ書き、`custom-layouts.json` のレイアウトを uuid ごとに PC の `custom-layouts.json` へ足し、PC の `applied-layouts.json` のうちテンプレートのままのディスプレイの組を `layout-rules.json` の決まり (解像度で決める。`powershell.exe` で聞く) のレイアウトで埋める。91 は Keyboard Manager が使えないと早く抜けるので、別の script にしてある (exit 1 にしない。PC のエディターで直したレイアウトも、手であてたレイアウトも、知らせて先へ進む) |
| `bootstrap-windows-google-ime-install.sh` | 95 | `bootstrap-windows-files.sh` が置いた `Install-GoogleJapaneseInput.ps1` で、Windows の Google 日本語入力が固定した版に揃っているかを確かめる (入っていなければ入れる。UAC の確認が出る。上げはしない)。設定を置く `bootstrap-windows-google-ime.sh` (98) より先に走る。`bootstrap-windows-powershell-profile.sh` と同じ 95 で、同じ値は辞書順なのでこちらが先 (どちらも相手を使わない) |
| `bootstrap-windows-powershell-profile.sh` | 95 | `bootstrap-windows-files.sh` が置いた `dotfiles.ps1` を `$PROFILE` から読ませる |
| `bootstrap-windows-openssh.sh` | 96 | `bootstrap-windows-files.sh` が置いた `Install-OpenSSH.ps1` で、Windows の OpenSSH が固定した版に揃っているかを確かめる (入っていなければ入れる。UAC の確認が出る。ずれは揃えない) |
| `bootstrap-windows-herdr-app.sh` | 97 | `bootstrap-windows-files.sh` が置いた `Install-HerdrApp.ps1` で、Windows の herdr-app と herdr-core を固定した版と、固定した版にだけ上がる取得元 (手元のフィード) に揃える (入れる・上げる・フィードと環境変数を書く。下げはしない。揃いきらなければ ⚠ で知らせ、exit 1 にしない)。`bootstrap-windows-herdr.sh` と同じ 97 で、同じ値は辞書順なのでこちらが先 (どちらも相手を使わない) |
| `bootstrap-windows-herdr.sh` | 97 | `bootstrap-windows-files.sh` が置いた `Install-Herdr.ps1` で、Windows の herdr が固定した版に揃っているかを確かめる (入っていなければ入れる。入れ替えはしない) |
| `bootstrap-windows-type-clipboard.sh` | 97 | `bootstrap-windows-files.sh` が置いた `Install-TypeClipboard.ps1` で、Windows の type-clipboard (自作のアプリ) が固定した版に揃っているかを確かめる (`dotfiles.wsl.windowsFiles.typeClipboard.enable = true` のマシンだけ。入っていなければ GitHub の Release から入れる。入れ替えはしない)。`bootstrap-windows-herdr.sh` と同じ 97 で、同じ値は辞書順なのでこちらが後 (どちらも相手を使わない) |
| `bootstrap-windows-google-ime.sh` | 98 | Google 日本語入力の設定を組み立てて配る。衝突や設定画面が開いているときに exit 1 しても、98 より前の bootstrap は済んでいる (後ろの `bootstrap-windows-international.sh`・`bootstrap-windows-port-forward.sh`・`bootstrap-windows-terminal.sh` (どれも 99) と wsl-mtu-guard・exe-exec-trace、最後の「残りの手作業」は、直して流し直すまで走らない) |
| `bootstrap-windows-international.sh` | 99 | `win/international/managed.json` の値だけを、Windows の日付と時刻の形式 (`HKCU\Control Panel\International`) へ `pwsh.exe` の SetLocaleInfoW で書く。ほかの bootstrap が置くものは使わない。`bootstrap-windows-port-forward.sh`・`bootstrap-windows-terminal.sh` と同じ 99 で、同じ値は辞書順なのでこちらが先に走る。衝突で exit 1 しても、それより前の bootstrap は済んでいる (後ろの `bootstrap-windows-port-forward.sh`・`bootstrap-windows-terminal.sh` と wsl-mtu-guard・exe-exec-trace、最後の「残りの手作業」は、直して流し直すまで走らない) |
| `bootstrap-windows-port-forward.sh` | 99 | dotfiles-private（50）の `ssh/port-forward.toml` (ssh の Host 名ごとの port forwarding の組) を JSON にして、Windows の `%USERPROFILE%\.config\port-forward\hosts.json` へ置く (PowerShell 7 の `pf` が読む)。ほかの bootstrap が置くものは使わない。同じ 99 は辞書順で、`bootstrap-windows-international.sh` の後・`bootstrap-windows-terminal.sh` の前に走る。正本の誤りや衝突で exit 1 しても、それより前の bootstrap は済んでいる (後ろの `bootstrap-windows-terminal.sh` と wsl-mtu-guard・exe-exec-trace、最後の「残りの手作業」は、直して流し直すまで走らない) |
| `bootstrap-windows-terminal.sh` | 99 | `win/windows-terminal/managed.json` のキーだけを、Windows Terminal の `settings.json` へ書き足す。ほかの bootstrap が置くものは使わない。同じ 99 の `bootstrap-windows-international.sh`・`bootstrap-windows-port-forward.sh` の後に走る。衝突で exit 1 しても、それより前の bootstrap は済んでいる (後ろの wsl-mtu-guard・exe-exec-trace と最後の「残りの手作業」は、直して流し直すまで走らない) |

> ⚠️ `order:` は**説明の 1 行目より後ろ**に書くこと。先頭に置くとメニューの説明として
> 拾われてしまう。

#### 途中の警告のまとめ

手順を止めない警告（`!!` の行や ⚠ の枠。手順は ✔ のまま進む）は、長い出力の途中に 1 度
出るだけでは流れて気付かない。そこで `setup` は、その場に出すのに加えて、最後の「結果」の
直後に ⚠ の枠でまとめて出し直す（TKT-146）。見出しの行には出した手順の id（`--steps` に
渡す名前。`--self-update` の警告（本体を更新しなかった理由や、fetch を gh の資格情報で取れず ssh で
取ったこと）は `[本体の更新]`）を付け、直し方などの続きの行を下に並べる。警告が無ければ何も足さない。
本体を更新して `exec` し直したときも、それまでの `[本体の更新]` の警告は新しい `setup` が env で
受け取って載せる（一時ファイルは `exec` の前に消す）。

```
==> 結果
  ✔ home-manager switch
  ✔ ./nix/scripts/bootstrap-claude-env.sh
  …

⚠️ ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ ⚠️
⚠️  途中で出た警告が 2 件あります (どれも手順を止めていないので、上の出力に流れています)
⚠️ ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ ⚠️
⚠️  [本体の更新] 未 commit の変更があるので本体は更新しません。自分で pull してください:
         git -C /home/…/dotfiles status
⚠️  [bootstrap-claude-env] gh にログインしていません。Claude の git は gh の資格情報で GitHub へ HTTPS で通します。
       gh auth login を実行するか、このマシンの flake で dotfiles.claude.gitViaGh.enable = false にしてください。
⚠️ ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ ⚠️

==> 残りの手作業
  …
```

途中の手順が ✖ で止まったときも、それより前の ✔ の手順の分は出す。✖ の手順の分は載せない
（まとめるのは手順を止めなかった警告。`setup` は最初の ✖ で止まるので、その手順の警告は
最後の手順の出力、つまり「[N/M] …」の見出しから「結果」までの中にある）。

`home-manager switch` が ✔ なら、その設定のモジュールの `warnings`（switch の出力に nix の
evaluation warning として 1 度出るもの。`dotfiles.claude.notion.profile が未設定です` など）も
`[switch]` で載せる。nix の出力を写すと進捗表示が消えるので、switch の後に同じ設定の
`config.warnings` を `nix eval` で読み直して取る（eval cache が効けば 1 秒ほど。`--dry-run` では
読まない。読めなければ黙って飛ばす）。読めたときは、「残りの手作業」は古い雛形・
`notion.profile` の案内を出し直さない（未設定なら、その warning がまとめに載る）。雛形の版の印が今の雛形と
違うことの案内（[雛形が新しくなったら](#雛形が新しくなったら)）は別の話なので、読めたときも出す。

続きの行が長い警告（`pwsh.exe` の出力ごと残したものなど）は、頭の 6 行と末尾の 3 行（直し方は
末尾に来る）を残して間を省く。全部はその場の出力にある。

`bootstrap-*.sh` などを足す・直すときは、次の形に合わせる。

- 手順を止めない警告は `warn` で出す。引数は 1 つが 1 行で、2 つ目からは字下げした続きの行
  （直し方・手で打つコマンド）になる。各 script が同じ形の `warn()` / `summary_warn()` を持つ
  （単体で配り・テストするので共通のファイルにしない。`warn-helpers-test` が全部の振る舞いを比べる）
- ⚠ の枠のように出し方を自分で決めるときは、その場は今どおり出し、`summary_warn` で見出しと
  直し方だけをまとめに残す（状態の表などは残さない）
- `exit 1` で止まる前のエラーは今のまま `echo … >&2` でよい（まとめに載らない）

受け渡しは環境変数 `DOTFILES_SETUP_WARNINGS`。`setup` が手順ごとにファイルを渡し、`warn` /
`summary_warn` はそこへ同じ行を足す（`setup` の外で流したときは何もしない）。子の stderr を
写して拾う形にしなかったのは、stderr が端末でなくなり、⚠ の枠の色や nix の進捗表示が消える
ため（home-manager の warnings を写さずに読み直すのも同じ理由）。

### 新規マシンの手順

上から順に実行する。**2 と 4 と 6 と 7 は忘れやすいので注意**（前節のスクリプトを使えば漏れない）。

新しい PC の対象ホストは、dotfiles-private を読めるかで決め方が分かれる（setup は推測しない。[前述](#まとめて実行する)）。

| PC | 流れ |
| --- | --- |
| 新しい WSL の PC（SSH 鍵も gh のログインもまだ） | [下の「新しい WSL の PC」](#新しい-wsl-の-pc)。`setup-local-flake.sh --initial` で初期用のホスト `initial` を書き、1 回目から Windows のアプリまで入れる → 鍵と gh のあとで dotfiles-private に登録し、`setup-local-flake.sh --force` で `initial` を外す |
| dotfiles-private を読める（ほか） | 1. `./nix/scripts/setup.sh --new-machine --host <型>` で 1 回当てる（Nix と gh が入る）→ 2. `gh auth login` のあと `~/ghq/github.com/pollenjp/dotfiles/nix/scripts/bootstrap-dotfiles-private.sh` で dotfiles-private を clone する（1 で取れていれば要らない）→ 3. Claude Code で `pjp-dotfiles-register-host` skill（dotfiles-private に登録する PR。入れ直した PC のように登録済みなら飛ばす）→ 4. merge し、`~/dotfiles/setup --steps private-fetch` で手元の clone を新しくする（登録したファイルが clone に来る）→ 5. ローカル flake が clone の `nix/` を読む形にする（下の「指し直し」）→ 6. `~/dotfiles/setup --which-host` が `<user>@<hostname><TAB>private` を出すのを確かめ、`~/dotfiles/setup --update`（`--host` なし。登録したホストが選ばれる） |
| dotfiles-private を読めない | 1. `./nix/scripts/setup.sh --steps local-flake` でローカル flake を置く → 2. `~/dotfiles/flake.nix` に `tmp` を足す（[後述](#登録簿に載せずにマシンを足す)。雛形のコメントの例を 1 段外して直す）→ 3. `~/dotfiles/setup --new-machine`（`tmp` が選ばれる） |

**指し直し**（ローカル flake の dotfiles-private の入力を、本体の空の stub から clone の `nix/` へ）: 1 回目に置いたローカル flake は、
clone がまだ無かったので stub を指している。setup はこれを自動では書き換えない（ユーザーのファイルなので）。

| ローカル flake | 指し直し方 |
| --- | --- |
| 値を書き足していない雛形のまま（`tmp` もほかの行も足していない） | `~/ghq/github.com/pollenjp/dotfiles/nix/scripts/setup-local-flake.sh --force` で作り直す（今の雛形で、clone の `nix/` を読む。退避は取らない） |
| 初期用のホスト `initial` だけを足した雛形（`--initial` で書いたまま） | 同じく `setup-local-flake.sh --force` で作り直す（`initial` も外れる。[下](#新しい-wsl-の-pc)） |
| 値を書き足したあと | `local-flake-migrate.sh` で値を引き継いで移す（[後述](#雛形が新しくなったら)。Claude Code なら `pjp-dotfiles-local-flake-migrate` skill。退避を取る） |

| # | やること | `--steps` の id | 備考 |
| --- | --- | --- | --- |
| 0 | マシンを登録する | — | 実機は dotfiles-private に登録する（`pjp-dotfiles-register-host` skill。Claude Code が入ってから。[後述](#dotfiles-private-に登録したホスト)）。それまでは `--host <型>` か、`~/dotfiles/flake.nix` に足したホストで当てる（上の流れ）。型だけで足りるなら登録は要らないが、毎回 `--host <型>` を付けるか、`DOTFILES_HOST` に書く（[後述](#マシンローカルの環境変数-configpjpenv)） |
| 1 | Nix を入れる（前節） | `nix-install` | |
| 2 | `./nix/scripts/preflight-unlink.sh` | `preflight-unlink` | `main.bash setup` 済みのマシンのみ |
| 2.4 | dotfiles-private を取得 | `private-fetch` | clone があれば switch の前に取得して fast-forward する（無ければ何もしない。6.5.1 が clone する） |
| 2.5 | `./nix/scripts/setup-local-flake.sh` | `local-flake` | `~/dotfiles` を用意する（[前述](#置き場所)） |
| 3 | `nix run ~/dotfiles#home-manager -- switch --flake ~/dotfiles#<host>` | `switch` | 初回はこの形。既存ファイルの扱いは[前述](#既存ファイルを退避するか選ぶ) |
| 4 | `./nix/scripts/bootstrap-mise.sh` | `bootstrap-mise` | mise のグローバル設定・言語ランタイム・`claude`（[後述](#claude-だけ-mise-に置いている理由)）・`cursor-agent`（`dotfiles.cursorAgent.enable` のホストだけ。[後述](#cursor-agent-も-mise-に置いている理由)） |
| 4.1 | `./nix/scripts/bootstrap-claude-plugins.sh` | `bootstrap-claude-plugins` | Claude Code の公式プラグイン導入（後述） |
| 5 | `~/.config/mise/config.toml` を手で整理 | — | 既存マシンのみ（後述） |
| 6 | `./nix/scripts/bootstrap-claude-hook.sh` | `bootstrap-claude-hook` | Claude Code のフック登録（ガード・解説動画の知らせ・走り切りの念押し・1Password の承認の知らせ・ほかの repo への参照で止める・設計の文書を `docs/` に書かせない・PR の assignee の念押し・`op.exe` の直打ちを止める） |
| 6.1 | `./nix/scripts/bootstrap-claude-statusline.sh` | `bootstrap-claude-statusline` | Claude Code の statusLine 登録 |
| 6.2 | `./nix/scripts/bootstrap-claude-env.sh` | `bootstrap-claude-env` | Claude のセッションに渡す env の登録（git の無署名・GitHub へは gh の HTTPS・plugin を https で取るのは[後述](#claude-のセッションだけ-git-の設定を変える)、Bash tool を bash で動かすのは[後述](#claude-code-の-bash-tool-を-bash-で動かす)） |
| 6.3 | `./nix/scripts/bootstrap-claude-skill-overrides.sh` | `bootstrap-claude-skill-overrides` | Claude Code の skill の見え方を `settings.json` の `skillOverrides` に書く。host option どおりの on / off（[後述](#claude-code-の-skill-を-host-ごとに止める)）と、pack の skill を名前だけ・claude.ai から同期された skill を Claude の一覧から外す（[後述](#skill-の一覧を枠に収める-pack-と同期された-skill)）。6.5 の後に走る |
| 6.4 | `./nix/scripts/bootstrap-claude-footer-links.sh` | `bootstrap-claude-footer-links` | Claude Code の footer に会話のチケットと PR と cc-page のリンクを出す設定の登録（[後述](#footer-に会話のチケットと-pr-と-cc-page-のリンクを出す)） |
| 6.5 | `./nix/scripts/bootstrap-claude-skills.sh` | `bootstrap-claude-skills` | private な skill 置き場の取得（後述） |
| 6.5.1 | `./nix/scripts/bootstrap-dotfiles-private.sh` | `bootstrap-dotfiles-private` | private な dotfiles-private の取得 (取れなくても止めない。[`win/README.md`](../win/README.md#google-日本語入力)) |
| 6.6 | `./nix/scripts/bootstrap-local-env.sh` | `bootstrap-local-env` | `~/.config/pjp/env` を置き、頭の「dotfiles が書く欄」を書き直す（[後述](#マシンローカルの環境変数-configpjpenv)） |
| 6.7 | `./nix/scripts/bootstrap-claude-accounts.sh` | `bootstrap-claude-accounts` | `claude-personal` / `claude-work` が使う `~/.claude-<名前>/` を用意（[後述](#claude-code-のアカウントを分ける-claude-personal--claude-work)） |
| 6.7.1 | `./nix/scripts/bootstrap-herdr-hub.sh` | `bootstrap-herdr-hub` | herdr の集約ハブ `~/h` を作る・雛形との差を直す（claude-skills の `pjp-herdr-hub` が張られているマシンだけ。[後述](#herdr-の集約ハブ-h)） |
| 6.8 | `./nix/scripts/bootstrap-windows-files.sh` | `bootstrap-windows-files` | repo 直下の `win/` を Windows 側へ配る（[後述](#windows-側のファイルを配る)） |
| 6.8.1 | `./nix/scripts/bootstrap-windows-powertoys.sh` | `bootstrap-windows-powertoys` | PowerToys が入っていなければ winget で入れ、Keyboard Manager と自動起動がオフならオンにして起動し直し、配った割り当てを Keyboard Manager に読み直させる（[`win/README.md`](../win/README.md#keyboard-manager-と自動起動をオンにする)） |
| 6.8.2 | `./nix/scripts/bootstrap-windows-fancyzones.sh` | `bootstrap-windows-fancyzones` | FancyZones の `settings.json` に、dotfiles が持つキー (Windows スナップのオーバーライドなど) だけを書き、カスタムレイアウトを uuid ごとに足し、テンプレートのままのディスプレイの組に解像度の決まりのレイアウトをあてる。設定画面で変えたキーは戻し、PC のエディターで直したレイアウトと手であてたレイアウトは書き換えずに知らせる（[`win/README.md`](../win/README.md#fancyzones)） |
| 6.8.3 | `./nix/scripts/bootstrap-windows-google-ime-install.sh` | `bootstrap-windows-google-ime-install` | Windows の Google 日本語入力が固定した版に揃っているかを確かめる（無ければ入れる。UAC の確認が出る。上げはしない。[`win/README.md`](../win/README.md#google-日本語入力を入れる-winget)） |
| 6.9 | `./nix/scripts/bootstrap-windows-powershell-profile.sh` | `bootstrap-windows-powershell-profile` | 配った PowerShell の共有設定を `$PROFILE` から読ませる（[後述](#windows-側のファイルを配る)） |
| 6.10 | `./nix/scripts/bootstrap-windows-openssh.sh` | `bootstrap-windows-openssh` | Windows の OpenSSH が固定した版に揃っているかを確かめる（揃えはしない。[`win/README.md`](../win/README.md#openssh)） |
| 6.10.1 | `./nix/scripts/bootstrap-windows-herdr-app.sh` | `bootstrap-windows-herdr-app` | Windows の herdr-app と herdr-core を、dotfiles が固定した版と、固定した版にだけ上がる取得元 (手元のフィード) に揃える（公式の install.ps1 と同じ置き場所。下げはしない。[`win/README.md`](../win/README.md#herdr-app)） |
| 6.11 | `./nix/scripts/bootstrap-windows-herdr.sh` | `bootstrap-windows-herdr` | Windows の herdr が固定した版に揃っているかを確かめる（無ければ入れる。入れ替えはしない。[`win/README.md`](../win/README.md#herdr-を入れる-winget)） |
| 6.11.1 | `./nix/scripts/bootstrap-windows-type-clipboard.sh` | `bootstrap-windows-type-clipboard` | Windows の type-clipboard (自作のアプリ) が固定した版に揃っているかを確かめる（`wsl.windowsFiles.typeClipboard.enable = true` のマシンだけ。無ければ GitHub の Release から入れる。入れ替えはしない。[`win/README.md`](../win/README.md#type-clipboard)） |
| 6.11.2 | `./nix/scripts/bootstrap-windows-google-ime.sh` | `bootstrap-windows-google-ime` | Google 日本語入力の設定とユーザー辞書を、テキストから組み立てて配る。新しいマシンで置き先がまだ無い (「まだ使われていません」と出る) ときは、Google 日本語入力を一度使ってから setup を流し直す（[`win/README.md`](../win/README.md#google-日本語入力を入れる-winget)） |
| 6.11.3 | `./nix/scripts/bootstrap-windows-international.sh` | `bootstrap-windows-international` | Windows の日付と時刻の形式 (短い日付・長い時刻・短い時刻) のうち、dotfiles が持つ値だけを SetLocaleInfoW で書く。形式を設定画面で手で変えてあると、衝突で止まる（[`win/README.md`](../win/README.md#日付と時刻の形式)） |
| 6.11.4 | `./nix/scripts/bootstrap-windows-port-forward.sh` | `bootstrap-windows-port-forward` | dotfiles-private の `ssh/port-forward.toml` (ssh の Host 名ごとの port forwarding の組) を JSON にして Windows に置く。PowerShell 7 の `pf` が読む。正本が無いマシンでは何もしない（[`win/README.md`](../win/README.md#port-forwarding-pf)） |
| 6.11.5 | `./nix/scripts/bootstrap-windows-terminal.sh` | `bootstrap-windows-terminal` | Windows Terminal の `settings.json` に、dotfiles が持つキー (bell の音など) だけを書き足す。新しいマシンで `settings.json` がまだ無いときは、Windows Terminal を一度起動してから setup を流し直す（[`win/README.md`](../win/README.md#windows-terminal)） |
| 6.12 | `./nix/scripts/bootstrap-cc-pages.sh` | `bootstrap-cc-pages` | private な cc-pages を取得してビルドし、daemon を起こす（[後述](#長い応答を読む-web-ビューア-cc-pages)） |
| 6.13 | `./nix/scripts/bootstrap-path-shadow.sh` | `bootstrap-path-shadow` | PATH で Nix の ntn より先に来る、Nix のものでない ntn（前に install script で入れたもの）を警告する。消さない（[後述](#前に手で入れた-ntn-と-setup-の警告)） |
| 7 | `chsh` でログインシェルを変更 | `chsh` | 必要なら |
| 7.5 | WSL の eth0 の MTU を上限まで下げ続ける system の unit を入れる | `wsl-mtu-guard` | `wsl.mtuGuard.enable = true` のマシンだけ入れる（ほかのマシンでは何もしない）。中で `sudo` を呼ぶ（[後述](#wsl-の-eth0-の-mtu-を上限まで下げ続ける)） |
| 8 | WSL の `.exe` の起動を常時記録する system の unit を入れる | `exe-exec-trace` | `wsl.exeExecTrace.enable = true` のマシンだけ入れる（ほかのマシンでは何もしない）。中で `sudo` を呼ぶ（[後述](#wsl-の-exe-の起動を常時記録する)） |

#### 新しい WSL の PC

Windows の新しい PC の WSL には、初めは SSH 鍵 (1Password) も gh のログインも無い。そのうちに Windows のアプリ
(PowerToys・Google 日本語入力・herdr・herdr-app・OpenSSH) まで入れられるよう、ローカル flake に初期用のホスト `initial` を書いて当てる。
`initial` は dotfiles-private に登録するまでの踏み台で、登録したら外す (登録しない PC は [`tmp`](#登録簿に載せずにマシンを足す) を使う。
[ADR 045](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/045_wsl_initial_host_20261108T121659JST/README.md))。

前提: Windows に PowerShell 7 (`winget install --id Microsoft.PowerShell --exact --source winget`) と WSL を入れてある。

```sh
# 1. SSH 鍵も gh のログインも無いうちに
mkdir -p ~/ghq/github.com/pollenjp
git clone https://github.com/pollenjp/dotfiles.git ~/ghq/github.com/pollenjp/dotfiles
~/ghq/github.com/pollenjp/dotfiles/nix/scripts/setup-local-flake.sh --initial   # Windows のユーザー名は自動で引く
~/dotfiles/setup --new-machine     # Nix → switch (initial) → win/ を配り、Windows のアプリを固定した版で入れる

# 2. 手で: 1Password を入れて SSH agent を有効にし、gh auth login

# 3. 登録して、initial を外す
~/ghq/github.com/pollenjp/dotfiles/nix/scripts/bootstrap-dotfiles-private.sh   # gh の資格情報で clone する
#    Claude Code で pjp-dotfiles-register-host (元にするホストは initial) → PR を merge
~/dotfiles/setup --steps private-fetch
~/ghq/github.com/pollenjp/dotfiles/nix/scripts/setup-local-flake.sh --force     # initial を外し、clone の nix/ を読む雛形にする
~/dotfiles/setup --which-host        # <user>@<hostname><TAB>private
~/dotfiles/setup --update
```

- `initial` に書くのは `username`・`system`・`wsl.enable`・`wsl.windowsUserName`・`wsl.windowsFiles.enable` だけ。1Password
  (鍵がまだ無い)・`exeExecTrace`・`mtuGuard`・Dev Tracker は、登録のときに足す
- Windows のユーザー名は `private-host.sh windows-user` (`$env:USERNAME`) で引き、`/mnt/c/Users/<名前>` があるかを確かめる。
  ユーザーのフォルダの名前を変えた PC では、止まって候補を出すので、`--windows-user <フォルダの名前>` で渡す
- 既に `~/dotfiles/flake.nix` があるとき: `initial` があれば触らない。今の雛形のまま (手を入れていない。`tmp` の例の
  Windows のユーザー名の違いは、手を入れたと見ない) なら差し込む。手を入れてあれば書かずに止まり、手で足す塊を出す
  (`--force --initial` で作り直すと、手で足した値は消える)
- 雛形の本文は変えずに、描いたあとで `tmp` の例の後ろに `initial` の塊を差し込む。`tmp` の例 (コメント) の `windowsUserName`
  にも同じ名前を入れる。雛形の版の印は変わらない
- `setup --new-machine` の途中で UAC の確認が出る (Google 日本語入力と OpenSSH で 1 回ずつ。herdr の依存の VCRedist が無い PC
  ではもう 1 回)。最後の「残りの手作業」に出た手順 (PowerToys の設定画面を開く・日本語入力を一度使う・Windows Terminal を
  一度起動する) のあと、`~/dotfiles/setup --update` を流し直す
- 対象ホストが `initial` の間は、setup が残りの手作業に次の段 (上の 2・3) を出す。clone にこの PC のファイルが来たのに
  `initial` を選んでいれば、外し方 (`--force`) を出す (ローカル flake のホストは、登録したホストより先に選ばれる)
- 初回の setup では、private な repo (claude-skills・dotfiles-private・cc-pages) は取れずに警告が出る (鍵も gh のログインも
  無いため。止まらない)。`gh auth login` のあとの `--update` で取れる

#### 1. 初回のブートストラップ (手順 3)

**`home-manager` コマンドはまだ存在しない。** `programs.home-manager.enable` が CLI を
profile へ入れるのは *初回の activate が成功した後* なので、1 回目は flake から直接実行する。

```sh
nix run ~/dotfiles#home-manager -- switch --flake ~/dotfiles#<ホスト>
```

> ⚠️ `nix run home-manager -- ...` (レジストリ経由) は使わないこと。
> nixpkgs 同梱の別バージョンが実行され、`flake.lock` で固定した home-manager
> モジュールとバージョンがずれる。上の `~/dotfiles#home-manager` なら
> lock と同じバージョンが使われる。

`#` の後ろはホストの名前（登録簿の型・dotfiles-private に登録した名前・`~/dotfiles/flake.nix` に足した名前）。

#### 2. mise の初期化 (手順 4)

```sh
./nix/scripts/bootstrap-mise.sh
```

`~/.config/mise/config.toml` は **Nix 管理下に置いていない**（mise が実行時に書き換える
ファイルなので store に置けない）。そのため `home-manager switch` だけでは作られず、
**新規マシンでは go / node が入らないまま**になる。このスクリプトで初期化する。

冪等なので何度実行してもよい。詳細は後述の「mise との役割分担」を参照。遅延（`minimum_release_age`）は
option の値を書く（[遅延を期間付きで緩める](#遅延-minimum_release_age-を期間付きで緩める)）。

`claude` もここで入る。グローバルな CLI なので役割分担どおりなら Nix 側だが、
例外にしている（[理由](#claude-だけ-mise-に置いている理由)）。Cursor の CLI（`cursor-agent`）も同じ理由でここで入るが、
入れるのはホストで `dotfiles.cursorAgent.enable = true` にしたマシンだけ（既定は入れない。[理由と入れ方](#cursor-agent-も-mise-に置いている理由)）。

#### 2.1 Claude Code の公式プラグイン (手順 4.1)

```sh
./nix/scripts/bootstrap-claude-plugins.sh
```

公式 marketplace（`anthropics/claude-plugins-official`）を登録し、
`superpowers` / `frontend-design` / `playwright` / `claude-security` を導入する。
足したいプラグインはスクリプト冒頭の `plugins` 配列に書く。

**なぜ他の `bootstrap-claude-*.sh` のように jq で `settings.json` を書かないのか。**
プラグインだけはそれでは足りない。`enabledPlugins` は「既に入っているものを有効にする」
フラグでしかなく、書いても**実体は取得されない**（使い捨ての `CLAUDE_CONFIG_DIR` に
`enabledPlugins` だけを書いて実セッションを起動し、`installed_plugins.json` が `{}` の
ままであることを確認済み）。marketplace の登録も別途要る。どちらも CLI が
`settings.json` へ書く（`extraKnownMarketplaces` / `enabledPlugins`）ので、
このスクリプトは jq を触らない。

冪等。既に在れば `already installed` と出るだけで、**版は上げない**
（`plugin update` は呼ばない。「先端は取らない」方針に合わせている）。

`claude` が見つからないときは警告を出して **exit 0** する。`setup.sh` は手順が 1 つ
失敗すると残りを走らせないので、ここで落とすと後続の bootstrap が巻き添えになるため。
marketplace の clone は SSH（`git@github.com:`）で行われるので GitHub の鍵が要る。
鍵が無くて失敗した場合も同じく exit 0 で流す。

入れられないプラグインがあっても止めず、警告して残りを入れる（exit 0。警告は[まとめ](#途中の警告のまとめ)にも出る）。
手元の marketplace の一覧が古いと、足したばかりのプラグインは `Plugin "…" not found in marketplace` で入らない。
`claude plugin marketplace update claude-plugins-official` で一覧を新しくしてから、
`~/dotfiles/setup --steps bootstrap-claude-plugins` で入れ直す。`claude-personal` / `claude-work` の dir で
`bootstrap-claude-accounts` が同じ警告を出したら、update に `CLAUDE_CONFIG_DIR=~/.claude-<名前>` を付け、
`--steps bootstrap-claude-accounts` で入れ直す。

**Claude Security（`claude-security`、beta）。** `/claude-security` で、頼んだときだけ repo か diff を多数の agent で
調べ、パッチ案を作る（自動では当てない。[docs](https://code.claude.com/docs/en/claude-security)）。前提は次のとおり。

| 前提 | この dotfiles での扱い |
| --- | --- |
| PATH の `python3`（3.9 以上・標準ライブラリだけ） | nixpkgs の `python3` を入れる（[後述](#python3-と-uv)）。無い・古いと `/claude-security` のメニューが警告を出し、スキャンも修正も動かない |
| dynamic workflows | 有料プランか API が要る。Pro のアカウントは `/config` の Dynamic workflows を on にする（dotfiles では設定しない） |
| git | `programs.git`（`home/modules/git.nix`）が入れる |

- `git push`・`gh pr create` の後に、スキャンを勧める案内がユーザーにだけ出る（plugin のデータの dir、つまりアカウントごとに
  5 回まで。subagent の中では出ない）。止めるなら `CLAUDE_SECURITY_SCAN_TIP=off`
- スキャンの結果は repo の `CLAUDE-SECURITY-<時刻>/` に書かれる（中に自前の `.gitignore` を置く）
- hook は外へ通信しない（metrics は Claude Code に渡す JSON を標準出力に出すだけ）

> ⚠️ `claude` は `bootstrap-mise.sh` が入れるので、**このスクリプトはその後に走る必要がある**。
> 実行順は `bootstrap-mise.sh` の `order: 10` と、こちらの `order: 20` で決めている
> （[後述](#bootstrap-の実行順)）。

#### 3. private な skill の取得 (手順 6.5)

```sh
./nix/scripts/bootstrap-claude-skills.sh
```

`pollenjp/claude-skills`（private）を clone して `~/.claude/` へ繋ぐ。
詳細は後述の「Claude Code > private な skill 置き場」を参照。

**private リポジトリなので SSH 鍵（gitViaGh のマシンでは先に試す gh の資格情報でもよい）が要る**が、
取得に失敗しても**エラーにはならない**。
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
home-manager switch --flake ~/dotfiles#<ホスト>
```

`~/dotfiles/setup --update`（メニューの「既存マシン更新」）は、これに加えて
`bootstrap-*` と `wsl-mtu-guard`・`exe-exec-trace` も走らせる（[前述](#まとめて実行する)。どれも冪等）。ホスト名を
覚えていなくてよく、スクリプトが増えていても取りこぼさないのでこちらが楽。dotfiles-private に登録した PC では
`--host` を付けない（setup が登録したホストを選ぶ。[後述](#dotfiles-private-に登録したホスト)）。登録していない PC では、
`~/dotfiles/flake.nix` に足した `tmp` が選ばれる（どちらも無ければ止まる）。

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

1 エントリが 1 ホスト。マシンごとの差は `mkHome` に渡す値で吸収する。

> public のこの登録簿には、型（`pollenjp@x86_64-linux`・`pollenjp@aarch64-linux`・`pollenjp@aarch64-darwin`）と検証用の
> `sandbox` だけを置く（[ADR 027](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/027_stop_guessing_host_20261021T143517JST/README.md)）。実機（その PC の値の全部を持つホスト）は dotfiles-private の `nix/hosts/` に
> 登録し（[後述](#dotfiles-private-に登録したホスト)・[ADR 026](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/026_dotfiles_private_hosts_20261020T215857JST/README.md)）、
> dotfiles-private を読めない PC は `~/dotfiles/flake.nix` にホストを足す（[後述](#登録簿に載せずにマシンを足す)）。下の `mkHome` の
> 引数は、どちらで書くときも同じ。型は、どちらもまだ無い PC を `--host <型>` で 1 回当てるためのもの。

| 引数 | 既定 | 用途 |
| --- | --- | --- |
| `username` | (必須) | Linux / macOS 側のユーザー名。`$USER` と一致しないと activate が中断する |
| `system` | (必須) | `x86_64-linux` / `aarch64-linux` / `aarch64-darwin` |
| `homeDirectory` | `/home/<username>`（darwin は `/Users/<username>`） | 検証用に逃がしたいときだけ指定する |
| `wsl` | `{ }` | WSL 固有の設定（下記）。省略すれば非 WSL マシン |
| `onePassword` | `{ }` | `onePassword.enable = true` で 1Password を git の署名に使う（WSL ならホスト側 Windows の、それ以外はこのマシンの 1Password。[git について](#git-について)） |
| `claude` | `{ }` | Claude Code まわり（`devTracker.enable`（既定 false）・`gitViaGh.enable`・`notion.*`・`videoOffer.autoStart.enable`・`heavyJobs.limitPercent`。[足したホストに書く値](#足したホストに書く値)） |
| `modules` | `[ ]` | `mkHome` の引数に無い option（`dotfiles.ccPages.port` など）と、home-manager の設定 |

### WSL 固有の設定は入れ子で渡す

`wsl` は入れ子の attrset で、**親が有効なときだけ子が意味を持つ**という関係を
そのまま構造にしてある。平坦なフラグの並びだと「どの組み合わせが有効なのか」が
読み取れないため。

```nix
wsl = {
  enable = true;               # WSL か
  windowsUserName = "alice";   # ホスト側 Windows のユーザー名 (/mnt/c/Users/<名前>。例は作り物)
  windowsFiles.enable = true;  # repo 直下の win/ を Windows 側へ配るか（後述）
  exeExecTrace.enable = true;  # WSL から起動された .exe を常時記録するか（後述）
  mtuGuard.enable = true;      # eth0 の MTU を上限（mtuGuard.maxMtu。既定 1350）まで下げ続けるか（後述）
};
onePassword.enable = true;     # 1Password で git の署名をするか（WSL ならホスト側 Windows の 1Password）
```

`onePassword` は `wsl` の外に置く（WSL でないマシンでも使うため。[ADR 022](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/022_one_password_outside_wsl_20261018T105655JST/README.md)）。
git の署名で見ると、組み合わせは次の 4 通り。

| マシン | 指定 | git の署名 |
| --- | --- | --- |
| 非 WSL / 1Password 無し | どちらも書かない | 署名の設定を書き出さない |
| 非 WSL / 1Password 有り | `onePassword.enable` | openssh の `ssh-keygen` が `SSH_AUTH_SOCK` のエージェントで署名する |
| WSL / 1Password 無し | `wsl.enable = true;` | 署名の設定を書き出さない |
| WSL / 1Password 有り | `wsl.enable`・`windowsUserName`・`onePassword.enable` | Windows 側の `op-ssh-sign-wsl.exe` を経由して署名する |

`windowsFiles.enable` は 1Password と独立に選べる（`windowsUserName` は要る）。
何をするかは[後述](#windows-側のファイルを配る)。

公開の登録簿には WSL の型が無い（型は `<user>@<system>` の 3 つ）。WSL の PC は、初回を `pollenjp@x86_64-linux` で当て、
dotfiles-private に登録するとき（読めない PC は `~/dotfiles/flake.nix` に足すホスト）に `wsl` と `onePassword` の値を書く
（[ADR 027](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/027_stop_guessing_host_20261021T143517JST/README.md)。setup は推測しないので、WSL だからといって `<user>@wsl` を選ぶこともない）。

> 1Password を使わないマシンで署名設定を書き出さないのは、`commit.gpgSign = true`
> だけが残ると署名鍵が見つからず `git commit` そのものが失敗するため。
> 「署名しない」も正当な構成として扱っている。

`windowsUserName` の値は WSL 上で次を実行すると判る（Nix の評価は純粋なので
自動取得はできない。`getEnv` や `--impure` は `nix flake check` を壊す）。

```sh
pwsh.exe -NoProfile -Command '$env:USERNAME'
```

階層で表現しきれない「親が false なのに子が true」は `assertions` で評価時に止まる。

- WSL で `onePassword.enable` が true なのに `wsl.onePassword.windowsUserName`（既定は `wsl.windowsUserName`）が無い
- `wsl.windowsFiles.enable` が true なのに `wsl.enable` が false
- `wsl.windowsFiles.enable` が true なのに `wsl.windowsUserName` が無い
- `wsl.exeExecTrace.enable` が true なのに `wsl.enable` が false
- `wsl.mtuGuard.enable` が true なのに `wsl.enable` が false

`exeExecTrace`・`mtuGuard` は 1Password の有無とは別に選べる。公開の登録簿には WSL のホストが無いので、CI は WSL・1Password・
`windowsFiles`・`exeExecTrace`・`mtuGuard` を入れた作り物のホスト（flake の checks の `home-wsl-example`）を build して確かめる。

### 登録簿に載せずにマシンを足す

dotfiles-private を読めない PC（会社の PC など）や一時的な環境は、`hosts/default.nix` を編集せず `~/dotfiles/flake.nix` に
ホストを足す（git 管理外）。[置き場所](#置き場所)で用意したものがそのまま使える。dotfiles-private を読める PC は、そちらに
登録する（[後述](#dotfiles-private-に登録したホスト)）。**PC の値は、dotfiles-private の登録か、ここに足すホストの 1 か所にだけ書く**
（[ADR 027](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/027_stop_guessing_host_20261021T143517JST/README.md)）。

`setup-local-flake.sh --initial` が書く初期用のホスト `initial` も、ここに足すホストの 1 つ。新しい WSL の PC を登録するまでの
踏み台で、値は WSL と windowsFiles だけ（[前述](#新しい-wsl-の-pc)）。登録しない PC は、値の全部を `tmp` に書く。

```nix
outputs =
  { dotfiles, dotfiles-private, ... }:
  let
    privateHosts = dotfiles.lib.privateHosts dotfiles-private;
  in
  {
    inherit (dotfiles) packages devShells formatter lib;

    homeConfigurations = dotfiles.homeConfigurations // privateHosts // {
      tmp = dotfiles.lib.mkHome {
        username = "pollenjp";
        system = "x86_64-linux";
        wsl = {
          enable = true;
          windowsUserName = "alice";   # ホスト側 Windows のユーザー名 (例は作り物)
          windowsFiles.enable = true;
        };
        onePassword.enable = true;
        claude = {
          devTracker.enable = true;    # Notion Dev Tracker を使う (既定は使わない)
          notion.profile = "work";
        };
        # mkHome の引数に無い option と、home-manager の設定
        modules = [
          {
            dotfiles.ccPages.port = 7778;
          }
        ];
      };
    };
  };
```

```sh
home-manager switch --flake ~/dotfiles#tmp
```

`dotfiles.homeConfigurations // privateHosts // { ... }` としているので、登録簿のホスト（型と `sandbox`）も同じ場所から引ける。
`~/dotfiles#pollenjp@x86_64-linux` と `~/dotfiles#tmp` が並ぶ。`privateHosts`（`dotfiles.lib.privateHosts dotfiles-private`）は
dotfiles-private に登録したホスト（[後述](#dotfiles-private-に登録したホスト)）。重ね順は登録簿 → dotfiles-private →
このマシンだけのホストで、後ろが勝つ。

#### 足したホストに書く値

値は `mkHome` の引数と `modules` に直に書く。dotfiles の option（`nix/home/options.nix`）は、option の既定より強いだけの
普通の定義なので `mkForce` は要らない（登録簿の型も dotfiles-private のホストも、このホストには当たらない）。書かなかった
option は本体の既定になる。本体の module が既に定義している home-manager の設定（`programs.git.settings.user.email` など）を
差し替えるときだけ、`modules` の中で `lib.mkForce` が要る。雛形の `tmp` の例（コメント）に、よく使う値と説明が並んでいる。
WSL の PC で描いた雛形なら、例の `windowsUserName` にはその PC の Windows のユーザー名が入っている（ほかの値は作り物）。
`setup-local-flake.sh` が描くとき（初回・`--force`・`--initial`）に、`--initial` と同じく `private-host.sh windows-user` で引き、
`/mnt/c/Users/<名前>` があって Nix の文字列に書ける名前だけを入れる（`--initial` なら `initial` と同じ名前）。行はコメントのままで、
雛形の版の印も変わらない。

| 値 | 既定 | 書くマシン |
| --- | --- | --- |
| `claude.devTracker.enable` | `false` | Notion Dev Tracker を使うマシン（[Claude Code の skill を host ごとに止める](#claude-code-の-skill-を-host-ごとに止める)） |
| `claude.notion.profile` | `null` | Notion へ書く skill を使うマシン。`"personal"` / `"work"`（[Notion の宛先を host ごとに選ぶ](#notion-の宛先を-host-ごとに選ぶ)） |
| `claude.gitViaGh.enable` | `true` | gh にログインしないマシンだけ `false`（[Claude のセッションだけ git の設定を変える](#claude-のセッションだけ-git-の設定を変える)・[fetch 系を gh の資格情報で通す](#fetch-系を-gh-の資格情報で通す-git-gh)） |
| `claude.videoOffer.autoStart.enable` | `false` | 解説動画の短尺を聞かずに作り始めたいマシンだけ `true`（[解説動画を作る場面を知らせるフック](#解説動画を作る場面を知らせるフック)） |
| `claude.heavyJobs.limitPercent` | `70` | 重い処理（動画の書き出し・推論など）に使わせる CPU とメモリの割合（整数 1〜100）を変えたいマシン（[重い処理の資源の上限を host ごとに決める](#重い処理の資源の上限を-host-ごとに決める)） |
| `dotfiles.ccPages.port`（`modules`） | `null`（7777） | 7777 がほかと衝突するマシンだけ（[待ち受けの port を変える](#待ち受けの-port-を変える)） |
| `dotfiles.osCaBundle.enable`（`modules`） | `true` | 証明書の束を OS の信頼ストアに寄せる 4 つの環境変数を入れたくないマシンだけ `false`（[入れる変数を選ぶ](#入れる変数を選ぶ)） |
| `dotfiles.osCaBundle.requestsCaBundle.enable`（`modules`） | `true` | そのうち `REQUESTS_CA_BUNDLE` だけを外したいマシンは `false`（同上） |
| `dotfiles.ntn.keyring`（`modules`） | `null`（触らない） | ntn の token を keychain でなくファイル（`auth.json`）に置くマシンは `false`（[ntn (Notion CLI) の token をファイルに置く](#ntn-notion-cli-の-token-をファイルに置く-keyring)） |
| `dotfiles.herdrCore.enable`（`modules`） | Linux なら `true` | herdr-core (hc) を入れない Linux のマシンだけ `false`（releases.herdr.dev から落とせないときに switch を止めないためにも使える。[herdr-core (hc) を Nix で入れる](#herdr-core-hc-を-nix-で入れる)） |
| `dotfiles.cursorAgent.enable`（`modules`） | `false`（入れない） | Cursor の CLI（`cursor-agent`）を使うマシンだけ `true`（[`cursor-agent` も mise に置いている理由](#cursor-agent-も-mise-に置いている理由)） |

- 前の雛形（ADR 007〜026 の版）は、登録簿のホストにも当たる「このマシンだけの設定」（`local`。`dotfiles.lib.hostsWith [ local ]` で
  当てる）を持っていた。今の雛形は持たない: 登録した PC では使われず、登録していない PC の値は足したホストに書けば足りる。
  `local` は登録簿のホストと同じ優先度で入るので、本体が定義済みの値を差し替えるのに `mkForce` が要った。前の雛形のままの
  `~/dotfiles/flake.nix` も評価はできる（本体は `hostsWith` を残している）が、`local` の値は型のホストにしか当たらない。
  移し方は[次の節](#雛形が新しくなったら)
- 雛形が変わっても、既にある `~/dotfiles/flake.nix` は触らない（`--force` で作り直すと、手で足したホストが消える）
- `windowsUserName` を `wsl.onePassword` の下に書いた古い形
  （`wsl.onePassword = { enable = true; windowsUserName = "…"; };`）も動く
  （`wsl.onePassword.windowsUserName` の既定が `wsl.windowsUserName` のため）。ただし
  `wsl.onePassword.enable` は `onePassword.enable` へ改名したので、switch のたびに改名の警告が出る。
  `onePassword.enable = true;` を `wsl` の外へ移す（[ADR 022](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/022_one_password_outside_wsl_20261018T105655JST/README.md)）。
  `windowsFiles.enable` を足すときは配り先にも名前が要るので、上の形のように
  `wsl.windowsUserName` へ移す

`~/dotfiles/setup` のホスト選択（`h`）にもここで足したものが出る。`setup.sh` は
登録簿と `~/dotfiles/flake.nix` の両方から名前を拾うため。
コメントアウトした雛形の例は拾わない。

さらに、ここに足した名前は[**既定の対象ホスト**](#まとめて実行する)になる（dotfiles-private に登録したこの PC のホストより
優先する）。`tmp` のように登録簿と揃っていない名前でも毎回 `h` や `--host` で選び直さなくてよい。複数足したときは
一番上のものが既定になるので、切り替えたいときは行を入れ替える。

生成される雛形にはこの例がコメントで入っている。`lib.mkHome` を公開しているのは
このためで、引数は[登録簿](#マシン登録簿-hostsdefaultnix)と同じ。

#### 雛形が新しくなったら

`setup-local-flake.sh` は雛形の先頭のコメントに**雛形の版の印**（`# 雛形の版: <8 桁の 16 進>`）を書く。印は
heredoc の原文（展開する前）の cksum で、雛形を直すと変わる（[ADR 024](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/024_local_flake_template_migrate_20261020T120111JST/README.md)）。
印が今の雛形と違うと（印の無い、印を入れる前の雛形も）、setup が知らせる。

| いつ | どこに |
| --- | --- |
| `--update` などの手順が通ったとき | 残りの手作業 |
| `--steps local-flake` を流したとき | `setup-local-flake.sh` の警告（最後の警告のまとめにも載る） |
| switch が落ちたとき | 失敗の案内のあと（本体で option が削除・改名されると、旧い `local` のままでは評価が止まる） |

値（手で足したホスト・手で書いた module・前の雛形の `local` の option）を引き継いで今の雛形へ移すのは
[`local-flake-migrate.sh`](./scripts/local-flake-migrate.sh)。Claude Code に任せるなら
`pjp-dotfiles-local-flake-migrate` skill（差分を見せて確認を取ってから書く）。

```sh
m=~/ghq/github.com/pollenjp/dotfiles/nix/scripts/local-flake-migrate.sh
w=$(mktemp -d)               # 作業場所 (共有の /tmp に決まった名前で作らない)
$m status                    # 印が今の雛形と同じか
$m prepare --out "$w"        # 元の雛形を決めて 3-way merge し、$w/new/flake.nix を作る
$m compare "$w"              # 旧い flake と移した flake で、全ホストの drvPath を比べる
diff -u ~/dotfiles/flake.nix "$w/new/flake.nix"
$m apply "$w"                # flake.nix.bak-<日時> と flake.lock.bak-<日時> に退避してから書く
```

- 先に本体を新しくしておく（新しい雛形の option が旧い本体に無いと、評価が止まる）
- `local` を持つ前の雛形から今の雛形（[ADR 027](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/027_stop_guessing_host_20261021T143517JST/README.md)）へ移すと、`local` の塊が消える。dotfiles-private に登録した PC
  （登録の仕上げで `local` を雛形の既定に戻してある）は衝突なく移る。`local` に値が残っていれば、塊ごと衝突として残るので、
  値を dotfiles-private の登録か足したホスト（`tmp`）へ移してから、雛形どおりに消す。移したあとは型のホストに `local` の値が
  当たらなくなるので、compare は型のホストの違い（Notion の宛先など）を出す（setup の対象でなければ受け入れてよい）
- dotfiles-private の入力（[前述](#dotfiles-private-に登録したホスト)）も移す。今の雛形は clone の `nix/` があればそこを、無ければ本体の
  stub を指すので、clone ができたあとは印が同じでも `status` が 1 になり、`prepare` がその 1 行を指し直す。移したあと、この PC を
  登録したホストが dotfiles-private から足されるなら、`compare` はそれを違いとして出す（setup の選ぶホストが変わる）
- 元の雛形は印の版。印が無ければ `setup-local-flake.sh` の履歴の各版を描き（古い版の script は実行しない）、
  旧いファイルとの差分が最も小さい版。`--base <rev>` で選び直せる
- 片側が元の行の前後に足しただけの衝突（コメントを外した行の直後に雛形が節を足した、など）は自動で解く。
  残った衝突は diff3 の印のまま `new/flake.nix` に残る
- WSL の PC で描いた雛形の `tmp` の例の `windowsUserName`（その PC の名前）は、`prepare` が元の雛形と今の雛形の例にも同じ名前を
  入れてから merge するので、今の雛形が例の行の隣を直しても衝突にならずに残る（`base.nix`・`template.nix` にも入る）。例が元の雛形の
  作り物の名前のままなら入れず、今の雛形の作り物の名前になる
- compare は評価用の写しで lock を張り直して評価する（1 回 20〜60 秒）。drvPath が全部同じなら home-manager の
  世代の中身は変わらないので、switch は要らない。違えば `config.dotfiles` の違いを出す。setup が文字列から拾う
  ホストの並び（一番上が既定の対象）も比べる。検証専用の `sandbox` は比べない（setup も対象にしない。前の雛形の
  `local` は、登録簿の `sandbox` が持つ値とぶつかって落ちる）
- ホストごとに評価するので、一部のホストで評価が落ちても、ほかのホストは比べる。両方で落ちるホストは比べずにそう
  出す。旧い flake でだけ落ちるホストがある（本体で option が消えた・`local` が登録簿の値とぶつかる、など）なら
  compare が 3 で終わり、そのホストを評価し直した原因のエラーを出す。評価が通るだけの直しを当てた基準を作り、
  `compare <作業場所> --baseline <dir>` で比べ直す
- apply は、prepare のあとに `~/dotfiles/flake.nix` が書き換わった・衝突の印が残る・今の中身で compare を流して
  いない、なら書かない。compare が同じでない（`--baseline` で比べたときも）なら `--accept-changes` が要る

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

### dotfiles-private に登録したホスト

実機（その PC の値の全部を持つホスト）は、private な [pollenjp/dotfiles-private](https://github.com/pollenjp/dotfiles-private) の
`nix/hosts/<user>@<hostname>.nix` に 1 PC 1 ファイルで置ける（[ADR 026](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/026_dotfiles_private_hosts_20261020T215857JST/README.md)）。
登録した PC では、`~/dotfiles/setup --update` が `--host` なしでそのホストを選ぶ。値は git（private）に残るので、雛形が新しくなっても
PC ごとに移さなくてよい。

```
dotfiles-private/
└── nix/
    ├── hosts/
    │   └── <user>@<hostname>.nix    ファイル名から .nix を除いたものがホストの名前
    └── shared/
        └── <名前>.nix               登録した全ホストに足す home-manager の module (無くてよい)
```

中身は[登録簿](#マシン登録簿-hostsdefaultnix)の 1 エントリと同じ形で、`mkHome` を受け取って呼ぶ関数にする。その PC の値は全部
このファイルに書く（`claude.*`・`wsl.*`・`onePassword.*` は `mkHome` の引数、ほかの `dotfiles.*` は `modules`。前の雛形の `local` に
書いていた値も）。Dev Tracker を使う PC は `claude.devTracker.enable = true` を書く（本体の既定は使わない）。

```nix
# 例 (値は作り物)
{ mkHome, ... }:
mkHome {
  username = "alice";
  system = "x86_64-linux";
  claude = {
    devTracker.enable = true;
    notion.profile = "work";
  };
  modules = [
    {
      dotfiles.ccPages.port = 7801;
    }
  ];
}
```

#### 読み方

- ローカル flake の雛形が clone の `nix/` を 2 つ目の `path:` の入力（`inputs.dotfiles-private`。`flake = false`）に取り、
  本体の `dotfiles.lib.privateHosts` が `hosts/*.nix` からホストを組み立てる。本体の flake は dotfiles-private を input に持たない
  （public の lock に private の rev を残さない。ADR 015 / 016）
- **ローカル flake の値は当たらない。** 素の `mkHome` で組むので、ファイルがその PC の値の全部を持つ（前の雛形の `local` も当たらない）
- **`shared/*.nix` は登録した全ホストに足す。** home-manager の module（`{ dotfiles.… = …; }` の形）を、各ホストのファイルが
  `mkHome` に渡す `modules` の前に足す（ファイル名の順）。脆弱性への対応（[mise の遅延の上書き](#遅延-minimum_release_age-を期間付きで緩める)）
  のように、登録した全 PC に効かせたい値を 1 か所に書くため。list の option はホストのファイルの値とつながる（順は module system が
  決める）。list でない option に両方で違う値を書くと評価が止まるので、片方を `lib.mkDefault` にする。拾い方は `hosts/` と同じ
  （`.nix` で終わり、`.` で始まらないファイル）。`shared/` が無ければ何も足さない。`~/dotfiles/flake.nix` に足したホスト（`tmp`）と
  登録簿の型には足さない
- **`shared/` に書く option は、全 PC の本体が持つものだけにする。** `--update` は dotfiles-private を取るが本体は進めない
  （`--self-update` は別）ので、本体の新しい option を `shared/` に書くと、本体が古い PC の switch が「option が無い」で止まる
  （ホストのファイルと違って全 PC に効く）。新しい option なら本体を先に merge し、各 PC で `--self-update --update` してから書く
- 重ね順は登録簿 → dotfiles-private → `~/dotfiles/flake.nix` に足したホスト（後ろが勝つ）。登録簿と同じ名前なら dotfiles-private が勝つ
- 読むのは `nix/` の下だけで、中身は誰でも読める `/nix/store` に入る（`ssh/` や辞書は入らない）。秘密（API キー・トークン）は置かない
  （[`~/.config/pjp/env`](#マシンローカルの環境変数-configpjpenv)）
- 雛形を書いたときに clone の `nix/` が無かったマシン（dotfiles-private を取れない会社の PC・clone する前の新しい PC）は、入力が本体の
  空の stub（`nix/private-stub`）を指す。clone ができたら、[値を引き継いで今の雛形へ移す](#雛形が新しくなったら)ときに
  clone の `nix/` へ指し直る（`local-flake-migrate.sh status` は、印が同じでも入力が違えば知らせる）
- 本体と同じく narHash で lock される。setup は switch の前に、`path:` の入力のうち合っていないものをまとめて張り直す
  （[後述](#ローカル-flake-の-lock-も張り直す)）

#### setup が選ぶ

この PC の名前は `<user>@<短い hostname>`（user は `$USER`、hostname は macOS なら `LocalHostName`、ほかは `uname -n` の最初の `.` まで）。
clone に `nix/hosts/<その名前>.nix` があり、ローカル flake がその clone の `nix/` を読んでいれば、`--host` が無くてもそのホストを選ぶ
（[決める順](#まとめて実行する)）。名前と clone の場所を決めるのは `nix/scripts/private-host.sh` だけ（`name`・`dir`）。

```sh
~/dotfiles/setup --which-host        # <user>@<hostname><TAB>private のように、選ぶホストと決め方を出す
```

| 起きていること | setup の知らせ |
| --- | --- |
| clone にこの PC のファイルがあるのに、ローカル flake が読んでいない（入力が無い・stub を指す） | `--host` なしで switch を選べば、手順を流す前に止まって直し方（`local-flake-migrate.sh prepare`）とそれまでの当て方（`--host <型>`）を出す。止まらないとき（`--host` で当てた・switch を選ばない）は残りの手作業に直し方 |
| `--host`・`DOTFILES_HOST`・`h` で、この PC を登録した名前と違うホストを選んだ | 警告（止めない。明示した方で当てる。値は登録したファイルではなく、そのホストの定義（前の雛形なら `local` も）から来る） |
| ローカル flake の dotfiles-private の入力の指す先が無い（clone を消した・動かした） | 警告（clone し直すか、指し直す） |

「既存マシン更新」と「新しいマシン適用」は、dotfiles-private を switch の前に取る（手順 2.4 `private-fetch`）。値を直して push すれば、
`--update` 1 回でその値で switch する。clone が無ければ何もせず、switch のあとの `bootstrap-dotfiles-private` が clone する。

#### 登録する

その PC で Claude Code に `pjp-dotfiles-register-host` skill を使わせる。調べる → 下書きの確認 → dotfiles-private の branch に書く →
比べる → PR → merge 後にローカル flake を今の雛形へ移す、の順で、書く前に確認を取る。決まった処理は `nix/scripts/private-host.sh`:

```sh
p=~/ghq/github.com/pollenjp/dotfiles/nix/scripts/private-host.sh
bash $p inspect                                          # この PC・登録の有無・今の世代と一致するホスト (元にするホストの候補)
bash $p draft --base <ホスト>                             # 元のホスト (前の雛形なら + local) から nix/hosts/<名前>.nix の下書きを描く (stdout)
bash $p compare --base <ホスト> --private <作業ツリー>     # 旧い形と登録したホストを同じ本体・同じ lock で評価し、drvPath を比べる (shared/ を外しても比べる)
```

- `draft` は元のホストの `options.dotfiles` を歩き、option の既定より強い定義を持つ値を描く（既定と同じ値を明示した行も描く）。
  前の雛形の `local` の dotfiles の外の行（`programs.git…` など）は描かず、下書きの頭のコメントで知らせる
- 型を元にする（新しい PC）と、下書きは `username`・`system` だけになる。WSL の値（`wsl`・`onePassword`）・Dev Tracker
  （`claude.devTracker.enable = true`）など、その PC で要る値を足す（`compare` は足した分だけ違う）
- 元にするホストが公開の登録簿から消えた PC（`pollenjp@wsl` などで当てていた PC。[ADR 027](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/027_stop_guessing_host_20261021T143517JST/README.md)）は、消す前の本体を
  `git archive` で写して `--nix-dir` に渡し、draft・compare する（手順は `pjp-dotfiles-register-host` skill）
- `compare` が 0 なら、ホストのファイルは元のホストの値を全部写せている（drvPath が同じなら、この登録で home-manager の世代の中身は
  変わらない。`shared/` の値だけ違うときも 0 で、世代は `shared/` の値の分だけ変わる。下の項目）。今の世代との一致は参考として
  出すだけ（本体を進めると、skill を 1 つ足しただけでも世代が変わる）
- dotfiles-private の `nix/shared/` の値は、登録した全ホストに足す値で、ホストのファイルの外にある（[ADR 031](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/031_register_host_compare_shared_20261023T025916JST/README.md)）。
  作業ツリーの `nix/shared/` に module があると、`compare` は新しい形を `shared/` を外しても評価し、それが旧い形と同じなら
  「同じ (shared/ の値だけ違う)」で 0 を返す。`shared/` が足す値（`mise.releaseAgeOverrides: [] → [{…}]` など。元のホストが型・`tmp`
  なら、登録で増える値）は、ホストのファイルの違いと分けて出す。`shared/` を足した形が評価できなければ 4（list でない option を
  両方に書いた、など）
- 元のホストが dotfiles-private に登録したホスト（値を直す・merge のあとに clone と比べ直す）なら、そのホストにもローカル flake の読む
  `shared/` が当たっているので、`draft` と `compare` の旧い形は `shared/` を外して評価する（下書きに `shared/` の値を描かない。違いは
  ホストのファイルどうし）。`compare` は clone と作業ツリーの `shared/` が同じかをファイルで比べて出す（同じでホストのファイルも同じ
  なら、0 で「世代の中身は変わらない」）。外すのは dotfiles-private の `nix/` の写しで、clone には書かない
- merge のあと、ローカル flake を今の雛形へ移し（dotfiles-private の入力が clone の `nix/` を指す）、登録したファイルへ移した値を
  ローカル flake から外す（前の雛形の `local` の値・足していた `tmp`）。移したあとの `local-flake-migrate.sh compare` は、この PC の
  ホストが dotfiles-private から足されることを「違い」として出す（setup の選ぶホストが変わるため。受け入れるなら
  `apply --accept-changes`）。ローカル flake が既に今の雛形で clone を読んでいれば、`prepare` は「移すものはありません」になるので、
  `prepare --always` で作業場所を作って直す

#### 値を一時的に試す

登録した PC ではローカル flake の値が当たらないので、dotfiles-private の作業ツリーのファイルを直して `~/dotfiles/setup --update` する
（`path:` の入力は commit していない変更も見える。git status に残るので戻し忘れにも気づける。ただし、そのまま `--update` すると
`private-fetch` は未コミットの変更があるので取得を飛ばす）。

## 日常運用

```sh
# 何が配置されるかを $HOME に触れず確認する
nix build ~/dotfiles#homeConfigurations.'"<ホスト>"'.activationPackage -o /tmp/hm
find -L /tmp/hm/home-files -mindepth 1 -maxdepth 3   # home-files は symlink なので -L 必須

# 適用 (既存ファイルは .bak へ退避。setup なら --backup=bak / メニューの b)
home-manager switch --flake ~/dotfiles#<ホスト> -b bak

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

### 使わなくなったデータの定期削除

`dotfiles.cleanup.enable` (既定で有効) のマシンでは、週 1 回 (systemd の weekly = 月曜 0:00) に
次の 2 つが走る (`nix/home/modules/cleanup.nix`)。マシンを止めていて逃した回は、次に起動したときに走る。

| timer | すること |
| --- | --- |
| `nix-gc.timer` | `nix-collect-garbage --delete-older-than 14d` (home-manager の `nix.gc`)。14 日より古い世代を消してから、どこからも辿れない store path を消す |
| `mise-prune.timer` | `mise prune --yes` と、mise の `downloads/` に残った 7 日より古いアーカイブの削除 |

```sh
systemctl --user list-timers nix-gc.timer mise-prune.timer   # 次に走る時刻
journalctl --user -u nix-gc.service -u mise-prune.service    # 走った結果
systemctl --user start nix-gc.service mise-prune.service     # 今すぐ走らせる
```

darwin では同じものが launchd の agent (`org.nix-community.home.nix-gc` / `org.nix-community.home.mise-prune`) で動く。

- 14 日より古い世代へは、ロールバックできなくなる
- root を張っていない devShell や `nix build` の結果も消え、次に使うときは取り直し (手元でビルドするものは再ビルド) になる。残したい devShell は `nix develop --profile <パス>` で root を張っておく。direnv の `use flake` で入る devShell は、nix-direnv が root を張るので残る ([後述](#direnv))
- mise は、使ったことのある設定ファイルのどれもが指していない版を消す。プロジェクトの `mise.toml` が固定している版は残る
- WSL では、消しても `ext4.vhdx` は縮まない。C: の空きにするには、`wsl --shutdown` してから管理者の PowerShell で `Optimize-VHD -Path <ext4.vhdx> -Mode Full` を打つ
- 止めたいマシンは、そのホストの `modules`（dotfiles-private に登録したファイルか、`~/dotfiles/flake.nix` に足したホスト）で
  `dotfiles.cleanup.enable = false;` にする

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
| `~/.ssh/config` | `nix/home/modules/ssh.nix` (生成。Include の骨組みと、このマシンを名乗る `SetEnv PJP_SSH_CLIENT`) |
| `~/.ssh/rc` | `nix/home/modules/agent-link.nix` (生成。接続を記録する `pjp-agent-link rc` を呼ぶ。[後述](#forward-された-agent-を固定名で見せる)) |
| `~/.config/git/ignore` | 同上 (`programs.git.ignores`) |
| `~/.config/direnv/direnv.toml`・`~/.config/direnv/lib/hm-nix-direnv.sh` | `nix/home/modules/direnv.nix` (生成。lib は nix-direnv の direnvrc。[後述](#direnv)) |
| `~/.config/uv/uv.toml` | `nix/home/modules/python.nix` (生成。`programs.uv` の settings。uv 本体は入れない。[後述](#python3-と-uv)) |
| `~/.local/bin/ssh` | `nix/files/bin/ssh-wsl.sh` (WSL + 1Password のマシンだけ。[後述](#wsl-では-ssh-自体を-windows-側に差し替える)) |
| `~/.local/bin/ssh-add` | `nix/files/bin/ssh-add-wsl.sh` (同上) |
| `pjp-who-is-asking` (PATH) | `nix/pkgs/pjp-who-is-asking/` (WSL のマシンだけ。[後述](#wsl-の-exe-の起動を常時記録する)) |
| `pjp-exe-exec-trace` (PATH) | `nix/pkgs/pjp-exe-exec-trace/` (`wsl.exeExecTrace.enable` のマシンだけ。同上) |
| `xdg-open` (PATH) | `nix/pkgs/pjp-wsl-xdg-open/` (WSL のマシンだけ。[後述](#wsl-の-xdg-open)) |
| `op`・`pjp-op-log` (PATH) | `nix/pkgs/pjp-op/` (WSL + 1Password のマシンだけ。[後述](#wsl-の-op-を理由つきで呼ぶ-1password-cli)) |
| `~/.local/state/dotfiles/claude-op-reason.json` | `nix/home/modules/op-reason.nix` (生成。上の `op` があるマシンか。Claude の hook が読む。[後述](#opexe-の直打ちを止め承認の拒否のあとは問いを出させるフック)) |
| `pjp-google-ime` (PATH) | `nix/pkgs/pjp-google-ime/` (`wsl.windowsFiles.enable` のマシンだけ。[後述](#windows-側のファイルを配る)) |
| `pjp-pr-diff` (PATH) | `nix/pkgs/pjp-pr-diff/` (全ホスト。[後述](#pr-の差分からファイルを選んで見る-pjp-pr-diff)) |
| `pjp-ghq-pull` (PATH) | `nix/pkgs/pjp-ghq-pull/` (全ホスト。Rust。[後述](#ghq-の-repo-をまとめて最新にする-pjp-ghq-pull)) |
| `ntn` (PATH) | `nix/pkgs/ntn/` (全ホスト。Notion の CLI の公式の配布物を版と sha256 で固定したもの。[後述](#ntn-notion-cli-を-nix-で入れる)) |
| `herdr-core`・`hc` (PATH)・`~/.local/bin/herdr-core`・`~/.local/bin/hc` | `nix/pkgs/herdr-core/` (`dotfiles.herdrCore.enable` のマシン。既定は Linux の全ホスト。公式の Linux 版を Windows と同じ版と sha256 で固定したもの。`~/.local/bin` のものは同じ binary へのリンク。[後述](#herdr-core-hc-を-nix-で入れる)) |
| `herdr`・`pjp-agent-link`・`ssh-agent-link` (PATH) | `nix/pkgs/pjp-agent-link/` (全ホスト。herdr は固定名を渡す実行ファイルで包んだもの。[後述](#forward-された-agent-を固定名で見せる)) |
| `~/.local/share/dotfiles/systemd/dotfiles-exe-exec-trace.service` | `nix/home/modules/exe-exec-trace.nix` (生成。`/etc` へは setup の手順が入れる。同上) |
| `~/.local/share/dotfiles/systemd/dotfiles-wsl-mtu-guard.service` | `nix/home/modules/wsl-mtu-guard.nix` (生成。`wsl.mtuGuard.enable` のマシンだけ。`/etc` へは setup の手順が入れる。[後述](#wsl-の-eth0-の-mtu-を上限まで下げ続ける)) |
| `~/.config/systemd/user/{nix-gc,mise-prune}.{service,timer}` | `nix/home/modules/cleanup.nix` (生成。`dotfiles.cleanup.enable` のマシンだけ。[前述](#使わなくなったデータの定期削除)) |
| `~/.local/state/dotfiles/mise-release-age.json` | `nix/home/modules/mise-release-age.nix` (生成。`dotfiles.mise.*` の値。`bootstrap-mise.sh` が読んで `~/.config/mise/config.toml` に書く。[後述](#遅延-minimum_release_age-を期間付きで緩める)) |
| `~/.local/state/dotfiles/cursor-agent.json` | `nix/home/modules/cursor-agent.nix` (生成。`dotfiles.cursorAgent.enable` の値。`bootstrap-mise.sh` が読み、on なら `~/.config/mise/conf.d/dotfiles-cursor-agent.toml` に版を指した宣言を書く。宣言は home-manager の管理ではない。[後述](#cursor-agent-も-mise-に置いている理由)) |
| `~/.local/state/dotfiles/ntn.json` | `nix/home/modules/ntn.nix` (生成。`dotfiles.ntn.keyring` の値。`bootstrap-ntn.sh` が読んで ntn の `config.json` の `keyring` に書く。[後述](#ntn-notion-cli-の-token-をファイルに置く-keyring)) |
| `~/.config/systemd/user/pjp-agent-link-watch.{path,service}` | `nix/home/modules/agent-link.nix` (生成。Linux だけ。[後述](#forward-された-agent-を固定名で見せる)) |
| `~/.config/systemd/user/cc-pages.service` | `nix/home/modules/cc-pages.nix` (生成。バイナリの `~/bin/cc-pages` は `bootstrap-cc-pages.sh` が置く。[後述](#長い応答を読む-web-ビューア-cc-pages)) |
| `~/.config/cc-pages/config.toml` | 同上 (生成。`dotfiles.ccPages.port` を選んだマシンだけ。[後述](#待ち受けの-port-を変える)) |
| `~/.config/systemd/user/pjp-dev-tracker-inbox.service` | `nix/home/modules/dev-tracker-inbox.nix` (生成。`dotfiles.claude.devTracker.inbox.enable` のマシンだけ。本体の `ticket.sh` は claude-skills にある。[後述](#チケットのコメントをハブの会話へ届ける見回り役-pjp-dev-tracker-inbox)) |

複製時に `~/dotfiles/...` への参照を書き換えている（store 管理では解決できないため）。

| 元の記述 | 書き換え後 |
| --- | --- |
| `source ~/dotfiles/vim_common/common.vim` | `source ~/.vim/common.vim` |
| `source-file ~/dotfiles/tmux/home.tmux.conf` | `source-file ~/.tmux.conf` |

## Windows 側のファイルを配る

Windows 側のアプリの設定（Orca のキーバインドなど）は repo 直下の
[`win/`](../win/README.md) に置き、WSL から `/mnt/c` 越しにコピーして配る。置き先は
アプリ自身が書き換えるので Nix では置けず、Claude Code の `settings.json` と同じく
「Nix が値を置き、bootstrap が写す」2 段にしてある。

| 段 | すること | 決める場所 |
| --- | --- | --- |
| `switch` | 配り先と on / off (と、type-clipboard を入れるか) を `~/.local/state/dotfiles/windows-files.json` に置く（全ホスト）。`windowsFiles.enable` のホストでは `pjp-google-ime` も PATH に入れる | `home/modules/windows-files.nix`（`dotfiles.wsl.windowsFiles.enable` / `dotfiles.wsl.windowsUserName` / `dotfiles.wsl.windowsFiles.typeClipboard.enable`） |
| bootstrap | checkout の `win/manifest.toml` を計画にし、置き先ごとに判定してコピーする | `scripts/bootstrap-windows-files.sh` + `lib/windows-files.nix` |
| bootstrap (FancyZones) | `win/powertoys/fancyzones/managed.json` のキーを、値が違えば FancyZones の `settings.json` へ書き、`custom-layouts.json` のレイアウトを、uuid ごとに前回足した中身と比べて PC の `custom-layouts.json` へ足し、`layout-rules.json` の解像度の決まりで、テンプレートのままのディスプレイの組にレイアウトをあてる | `scripts/bootstrap-windows-fancyzones.sh` |
| bootstrap (Google 日本語入力) | `win/google-japanese-input/` と dotfiles-private の辞書から組み立て、時刻を除いた中身で比べて置き、変換サーバーを落とす | `scripts/bootstrap-windows-google-ime.sh` + `pkgs/pjp-google-ime/` |
| bootstrap (日付と時刻の形式) | `win/international/managed.json` の値を、値ごとに前回書いた値・地域の既定と比べて、ユーザーのレジストリ (`HKCU\Control Panel\International`) へ `pwsh.exe` の SetLocaleInfoW で書く | `scripts/bootstrap-windows-international.sh` |
| bootstrap (port forwarding の組) | dotfiles-private の `ssh/port-forward.toml` を確かめて JSON にし、前回置いた中身と比べて `%USERPROFILE%\.config\port-forward\hosts.json` へ置く | `scripts/bootstrap-windows-port-forward.sh` |
| bootstrap (Windows Terminal) | `win/windows-terminal/managed.json` のキーを、キーごとに前回書いた値と比べて、Store 版の `settings.json` へ書き足す | `scripts/bootstrap-windows-terminal.sh` |
| bootstrap (type-clipboard) | `windows-files.json` の `typeClipboard` が true のマシンだけ、配った `Install-TypeClipboard.ps1` で、固定した版の exe が入っているかを確かめる (無ければ GitHub の Release から落とし、SHA-256 が合えば置く) | `scripts/bootstrap-windows-type-clipboard.sh` |

**`win/` は home-manager からは読まない。** ローカル flake は本体を `path:<repo>/nix` で
読むので、その評価から repo 直下は見えない（`/nix/store/win/...` への access が
forbidden になる）。CI の `nix flake check ./nix` は `git+file` になって見えてしまうので、
CI では通るのにマシン上の switch で落ちる。module から `../../../` で repo 直下を指さないこと。

### 反映（冪等。更新時も毎回走る）

```sh
~/dotfiles/setup --update                           # switch + bootstrap をまとめて
./nix/scripts/bootstrap-windows-files.sh            # 配る部分だけ
./nix/scripts/bootstrap-windows-files.sh --dry-run  # 判定だけ見る
./nix/scripts/bootstrap-windows-files.sh --check    # manifest の検証だけ（CI の lint でも走る）
./nix/scripts/bootstrap-windows-powershell-profile.sh  # $PROFILE に読み込みの 1 行を足す部分だけ
./nix/scripts/check-herdr-keys.sh                    # herdr のキーバインドと [ui]（sidebar の幅と行・toast）が WSL と Windows で同じか（CI の lint でも走る）
./nix/scripts/check-winget-version.sh herdr         # winget で固定した版が winget の最新か（名前は openssh・herdr・google-japanese-input。CI の winget-versions が週 1 回流す。gh のログインが要る）
./nix/scripts/bootstrap-windows-herdr-app.sh        # herdr-app と herdr-core を固定した版とフィードに揃える部分だけ（--apply は確かめずに揃える）
./nix/scripts/check-herdr-app-version.sh            # herdr-app と herdr-core の固定した版の成果物 (core は Windows と Linux) が変わっていないかと、7 日たった新しい版（CI の herdr-app-installers が週 1 回流す。gh のログインが要る）
./nix/scripts/check-herdr-app-installers.sh         # herdr-app の公式の install.ps1 が、写したときから変わっていないか（CI の herdr-app-installers が週 1 回流す）
./nix/scripts/bootstrap-windows-powertoys.sh         # PowerToys が無ければ入れ、Keyboard Manager と自動起動をオンにし、配った割り当てを読み直させる部分だけ
./nix/scripts/bootstrap-windows-fancyzones.sh        # FancyZones の settings.json に持つキーだけを書き、カスタムレイアウトを uuid ごとに足し、ディスプレイの組にレイアウトを解像度であてる部分だけ（--dry-run / --force / --import <名前> / --check）
./nix/scripts/bootstrap-windows-google-ime-install.sh  # Google 日本語入力が固定した版かを確かめる部分だけ（無ければ入れる。--apply で揃える）
./nix/scripts/bootstrap-windows-google-ime.sh        # Google 日本語入力の設定を組み立てて配る部分だけ（--dry-run / --import / --force / --check / --show-words）
./nix/scripts/bootstrap-windows-international.sh    # Windows の日付と時刻の形式に持つ値だけを書く部分だけ（--dry-run / --import / --force / --check）
./nix/scripts/bootstrap-windows-port-forward.sh    # dotfiles-private の port forwarding の組を Windows の hosts.json へ写す部分だけ（--dry-run / --force / --check）
./nix/scripts/bootstrap-windows-terminal.sh         # Windows Terminal の settings.json に持つキーだけを書き足す部分だけ（--dry-run / --import / --force / --check）
./nix/scripts/bootstrap-windows-type-clipboard.sh  # type-clipboard が固定した版かを確かめる部分だけ（typeClipboard を入れるマシンだけ。無ければ入れる。--apply で揃える）
```

- 配るのは `dotfiles.wsl.windowsFiles.enable = true` のマシンだけ（dotfiles-private に登録したファイルか、
  `~/dotfiles/flake.nix` に足したホストで書く）。
  それ以外は「このマシンは Windows 側へ配りません」と言って exit 0
- 配るのは setup を走らせた checkout の `win/` の作業ツリー。commit していない変更も配られる
- 置き先の中身が「前回置いた中身」（`~/.local/state/dotfiles/windows-files.deployed.json` の
  sha256）と違えば **衝突**。上書きせずに diff を出して exit 1（setup はこの手順で止まり、後ろの
  91〜99 の bootstrap と wsl-mtu-guard・exe-exec-trace、最後の「残りの手作業」は流し直すまで走らない）。
  取り込むか `--force` で解く（[`win/README.md`](../win/README.md#衝突したら)）
- 書き換えたファイルには manifest の `hint` を出す。Orca は置いたファイルを監視しないので、
  設定画面の「ディスクから再読み込み」が要る
- PowerShell の共有設定 (`win/powershell/dotfiles.ps1`) は、続く `bootstrap-windows-powershell-profile.sh`
  (order 95) が `$PROFILE` に読み込みの 1 行を足して読ませる。`$PROFILE` の場所はマシンごとに
  変わる (OneDrive のドキュメント) ので `pwsh.exe` に聞く。interop が落ちていたら手で打つ
  コマンドを出して exit 0。配る経路 (コピー) には exe を挟まない（[`win/README.md`](../win/README.md#powershell)）
- PowerToys と Google 日本語入力の本体は、`bootstrap-windows-powertoys.sh` (order 91) と
  `bootstrap-windows-google-ime-install.sh` (order 95) が、配った `Install-PowerToys.ps1`・
  `Install-GoogleJapaneseInput.ps1` を `pwsh.exe` で呼び、入っていなければ winget で入れる。Google 日本語入力は
  版を固定し、ずれは ⚠ で知らせるだけ (上げるのは手で打つ。UAC の確認が出る)。PowerToys は版を固定せず、91 が
  Keyboard Manager と自動起動がオフならオンにして起動し直す
  （[`win/README.md`](../win/README.md#google-日本語入力を入れる-winget)、[ADR 017](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/017_win_apps_winget_20261012T115007JST/README.md)）
- herdr-app (herdr の desktop app) と herdr-core は winget に無いので、`bootstrap-windows-herdr-app.sh` (order 97) が、配った
  `Install-HerdrApp.ps1` を `pwsh.exe` で呼び、dotfiles が固定した版を公式の install.ps1 と同じ置き場所に入れる (遠くの script は流さない。
  sha256 と署名を確かめる)。app と core は自分で上がるので、取得元 (`HERDR_RELEASES_URL`) を固定した版だけを載せた手元のフィードに向け、
  固定した版を上げる PR の後の setup がフィードを書き直す。版と sha256 は `nix/pkgs/herdr-core/releases.json` (manifest の `base = "nix"` で
  `herdr-releases.json` として配る。Linux のホストの herdr-core も同じ版で入る。[後述](#herdr-core-hc-を-nix-で入れる))。外すのは人が PowerShell で
  `Install-HerdrApp -Uninstall` を打つときだけ（[`win/README.md`](../win/README.md#herdr-app)、[ADR 048](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/048_win_herdr_app_official_layout_20261109T230034JST/README.md)）
- FancyZones の設定は持つキー (`win/powertoys/fancyzones/managed.json`) だけを、カスタムレイアウト (`custom-layouts.json`) はレイアウトごとに、
  `bootstrap-windows-fancyzones.sh` (order 92) が書く。どちらも manifest では配らない。`settings.json` は PowerToys が全部のキーを書くので
  ファイルごとは配らず、設定画面で変えていても dotfiles の値へ戻す (衝突で止めない)。`custom-layouts.json` は PC のエディターで作ったレイアウトも
  入るので、repo のレイアウトを uuid で突き合わせて足し、PC にだけあるものには触らない。PC のエディターで直した・消したものは、前に足した中身の
  記録 (`~/.local/state/dotfiles/windows-fancyzones.applied.json`) で見分け、書き換えずに知らせて先へ進む (`--force` で戻す・`--import` で取り込む)。
  どのディスプレイにどのレイアウトをあてるか (`applied-layouts.json`) はシリアルが入るので持たず、解像度からレイアウトを決める決まり
  (`layout-rules.json`) を持つ。同じ script が、テンプレートのままのディスプレイの組を決まりのレイアウトで埋める (解像度は `powershell.exe` で
  聞く。手であてたものは残し、`--force` で上書きする。あてた組は `~/.local/state/dotfiles/windows-fancyzones.assigned.json` に覚える)。
  FancyZones は `LastWriteTime` の変更しか見ていないので、`mv` の後に `touch` して読み直させる（[`win/README.md`](../win/README.md#fancyzones)、
  [ADR 042](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/042_win_powertoys_fancyzones_20261106T100504JST/README.md)・
  [ADR 046](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/046_win_fancyzones_layouts_by_uuid_20261109T200910JST/README.md)・
  [ADR 053](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/053_win_fancyzones_layout_by_resolution_20261110T213751JST/README.md)）
- Google 日本語入力の設定 (`win/google-japanese-input/`) は manifest では配らない。protobuf のバイナリで
  保存のたびに時刻が入るので、`bootstrap-windows-google-ime.sh` (order 98) が `pjp-google-ime` で
  組み立て、時刻を除いた中身で比べて配り、変換サーバーを落として読み直させる。辞書は private な
  dotfiles-private (`bootstrap-dotfiles-private.sh`) から取る（[`win/README.md`](../win/README.md#google-日本語入力)、
  [ADR 015](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/015_win_google_ime_powertoys_20261011T234247JST/README.md)）
  - 衝突で出すのは、設定は diff、辞書は辞書ごとの行の数だけ (辞書の語は setup の出力に出さない。
    語の diff は自分の端末で `--dry-run --show-words`)
  - 変換サーバーを落とせなかったら落とし直しの印を残し、次の回が置くものが無くても落とし直す
  - `--import` は、取り込みが書き換えるテキスト (`config.txtpb`・`keymap.tsv`・`romaji.tsv` と、dotfiles-private の辞書のディレクトリ `dictionaries/` の中身) に commit していない変更があると何も書かずに止まる
- Windows Terminal の設定 (`win/windows-terminal/managed.json`) も manifest では配らない。`settings.json` は
  Windows Terminal 自身も書き換え (新しい profile を見つけたとき・設定画面で保存したとき)、PC ごとに違う profile の
  一覧も入るので、`bootstrap-windows-terminal.sh` (order 99) が持つキーだけを書き足し、キーごとに前回書いた値
  (`~/.local/state/dotfiles/windows-terminal.applied.json`) と比べて衝突を見る（[`win/README.md`](../win/README.md#windows-terminal)、
  [ADR 018](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/018_win_terminal_settings_keys_20261016T105116JST/README.md)）
- Windows の日付と時刻の形式 (`win/international/managed.json`) はファイルでなく、ユーザーのレジストリ
  (`HKCU\Control Panel\International`) の値。`bootstrap-windows-international.sh` (order 99。Windows Terminal より先) が `pwsh.exe` で
  SetLocaleInfoW を呼んで持つ値だけを書き、WM_SETTINGCHANGE (`"intl"`) を送る。前回書いた値
  (`~/.local/state/dotfiles/windows-international.applied.json`) と比べて衝突を見るのは Windows Terminal と同じで、記録が無く
  地域の既定のままなら黙って書く（[`win/README.md`](../win/README.md#日付と時刻の形式)、
  [設計](https://github.com/pollenjp/dotfiles-private/blob/main/docs/superpowers/specs/2026-11-07-windows-international-format-design.md)）
- PowerShell 7 の `pf` (`win/port-forward/Start-PortForward.ps1`。manifest で配る) が出す port forwarding の組は、dotfiles-private の
  `ssh/port-forward.toml` が正本。`bootstrap-windows-port-forward.sh` (order 99。international の後・Windows Terminal の前) が
  `nix-instantiate` の `builtins.fromTOML` で読み、書き方と手元の port の重なりを確かめてから JSON にして
  `%USERPROFILE%\.config\port-forward\hosts.json` へ置く。前回置いた中身 (`~/.local/state/dotfiles/windows-port-forward.deployed.json`
  の sha256) と比べて衝突を見るのは ssh の設定の手順と同じ。その PC で足した組は pf が同じ場所の `local.json` に持ち、この手順は触らない
  （[`win/README.md`](../win/README.md#port-forwarding-pf)、[設計](https://github.com/pollenjp/dotfiles-private/blob/main/docs/superpowers/specs/2026-11-07-pf-port-forward-design.md)）
- 自作の Windows のアプリ type-clipboard は winget に無いので、`dotfiles.wsl.windowsFiles.typeClipboard.enable = true` のマシン (既定は
  false) だけ、`bootstrap-windows-type-clipboard.sh` (order 97) が配った `Install-TypeClipboard.ps1` を `pwsh.exe` で呼び、入っていなければ
  GitHub の Release から固定した版の exe を落として、SHA-256 が合えば `%LOCALAPPDATA%\Programs\type-clipboard` に置きスタートメニューに出す。
  版と SHA-256 は ps1 で固定し、ずれは ⚠ で知らせるだけ（[`win/README.md`](../win/README.md#type-clipboard)、
  [ADR 049](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/049_win_type_clipboard_release_pin_20261110T001612JST/README.md)）

経緯は [ADR 010](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/010_win_files_from_wsl_20260928T003933JST/README.md)。

## git について

`programs.git` で `~/.config/git/config` を **生成** している（素のファイル配置ではない）。
目的は 1Password `op-ssh-sign` のパスで、従来は WSL 用と Windows 用がコメントアウトで
並んでおり手で切り替える運用だった。これを登録簿の指定による分岐に置き換えている。

署名まわりは `dotfiles.onePassword.enable` で丸ごと切り替わる
（マシンごとの指定は[マシン登録簿](#マシン登録簿-hostsdefaultnix)を参照）。

| 生成される項目 | 有効 | 無効 |
| --- | --- | --- |
| `commit.gpgSign` / `tag.gpgSign` | `true` | 書き出さない |
| `gpg.format` | `ssh` | 書き出さない |
| `gpg.ssh.defaultKeyCommand` | ssh-agent の鍵から `Signing` を含むものを選ぶ | 書き出さない |
| `gpg.ssh.program` | WSL は Windows 側の `op-ssh-sign-wsl.exe`、それ以外は openssh の `ssh-keygen`（home-manager の既定） | 書き出さない |

`defaultKeyCommand` は 1Password が鍵に付ける名前で引くものなので、1Password の
無いマシンでは当たらない。片方だけ残すと「署名しようとして鍵が見つからず commit が
失敗する」状態になるため、無効のマシンでは署名設定を丸ごと省いている。

> ⚠️ **WSL の `defaultKeyCommand` は `ssh-add` が Windows 側であることに依存している。**
> 鍵を持っているのはホスト側 Windows の 1Password なので、`ssh-add -L` が Linux の
> ssh-agent を引くと鍵が並ばず、署名鍵が見つからないまま `commit.gpgSign = true`
> だけが残る。`op-ssh-sign` のパス指定だけでは足りない。差し替えは
> [ssh ラッパー](#wsl-では-ssh-自体を-windows-側に差し替える)が行う。

**WSL でないマシンでは、`ssh-keygen` が `SSH_AUTH_SOCK` のエージェントで署名する**
（[ADR 022](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/022_one_password_outside_wsl_20261018T105655JST/README.md)）。ssh と同じ経路なので、
手元ではそのマシンの 1Password（`SSH_AUTH_SOCK` を `~/.1password/agent.sock` へ向けるのは system の側。
NixOS の laptop は nixos-config の ADR 009）、ssh 先では転送されてきたエージェント、herdr の pane では
固定名の指す先の、同じ "Signing" の鍵で署名する。ラッパーは置かない。

署名が入るのは `onePassword.enable = true` のマシンだけ（公開の登録簿の型には入らない。dotfiles-private に登録したファイルか、
`~/dotfiles/flake.nix` に足したホストで書く）。dotfiles-private に登録した PC は `--host` を付けない（setup が登録したホストを選び、署名を
入れるかもそのファイルの `onePassword` で決まる。[前述](#dotfiles-private-に登録したホスト)）。登録していない PC の `--host` なしの
`setup` は、ローカル flake がホストを定義していなければ止まる（推測で汎用の `<user>@<system>` を選んで署名が外れることはない。
[ADR 027](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/027_stop_guessing_host_20261021T143517JST/README.md)）。登録した PC で `--host <型>` などを付けると、値は登録したファイルではなくそのホストの定義から来るので、
setup が警告する（[ADR 026](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/026_dotfiles_private_hosts_20261020T215857JST/README.md)。ADR 022 の `--host pollenjp@laptop` の
手順は、登録する前の記録で、そのホストは公開の登録簿から消した）。

`git log --show-signature` は `gpg.ssh.allowedSignersFile` が無いのでエラーになる（WSL も同じ）。
署名されたかは `git cat-file -p HEAD` の `gpgsig` か、push したあとの GitHub の Verified で見る。

> ⚠️ **`~/.gitconfig` の symlink は必ず外すこと。**
> git は `~/.config/git/config` を読んだ **後に** `~/.gitconfig` を読むため、
> `main.bash` が張った symlink が残っていると home-manager の設定を黙って上書きする。
> `preflight-unlink.sh` が対象に含めている。

**`git config --global` は使えなくなる。** 書込先の `~/.config/git/config` が store 上の
read-only ファイルになるため。マシン固有の設定を足したい場合は `~/.gitconfig` を作れば
よい（git の読み込み順により home-manager の設定を上書きできる）。

なお **Claude のセッションからの commit だけは署名しない**。1Password の承認ダイアログで
止まるため。また既定では、Claude のセッションの GitHub への push / fetch は ssh ではなく
gh の資格情報（HTTPS）で通す。[Claude のセッションだけ git の設定を変える](#claude-のセッションだけ-git-の設定を変える)を参照。
自分のターミナルでも、fetch 系の abbr / alias（`gf`・`gfp`・`gpul` など）は同じ option で gh を通る
（[fetch 系を gh の資格情報で通す](#fetch-系を-gh-の資格情報で通す-git-gh)）。

### PR の差分からファイルを選んで見る (pjp-pr-diff)

`pjp-pr-diff`（fish の abbr と bash の alias は `gdp`）は、PR 全体の変更ファイルを fzf で選び、
選んだファイルだけの `git diff` を出す（実体は `nix/pkgs/pjp-pr-diff/`。全ホストの PATH に入る）。
Claude に PR を作らせた後、確かめるファイルを絞って読むためのもの。PR の branch の checkout
（herdr の worktree など）の中で打つ。選んでいる間は、カーソルの行のファイルの差分をプレビューに
出す（端末の 60% の幅で 100 桁が取れれば右、取れなければ下）。

| 操作 | すること |
| --- | --- |
| 文字を打つ | パスで絞る（状態の文字 `M` / `A` / `D` / `R` には当たらない） |
| Tab / Shift-Tab | 選んで、下 / 上の行へ動く（複数選べる。もう一度押すと外れる。端では反対の端へ回る） |
| Enter | 選んだファイル（選んでいなければカーソルの行）の差分を `git diff` で出す。pager は git の設定（delta） |
| Esc | 何も出さずにやめる |

一覧は上からパスの順に並ぶ（`--layout=reverse`。fzf.fish の一覧と同じ向き）。

比べる範囲は `merge-base(<base>, HEAD)` から `HEAD` まで（`<base>...HEAD`）。GitHub の PR の
Files changed と同じ三点の比較で、`<base>` 側が後から進めた変更は混ざらない。作業ツリーの
未コミットの変更は含めない。`<base>` は上から順に決める。

1. `--base <ref>`（`--base=<ref>` でもよい）
2. `gh pr view` が返す、この branch の PR の base（`origin/<名前>`）。main 以外へ向けた PR でも、その PR の差分になる
3. `origin/HEAD`（PR が無い・gh が無い・ログインしていない・通信できないとき）

- PR の base が手元に無い（fetch していない）ときは、3 へ落とさずに止まる。別の base と比べると、
  PR に無いファイルまで並ぶため
- 2 の remote はいつも `origin` と読む。fork から upstream へ出した PR では `--base upstream/<名前>` で指定する
- 2 で GitHub にある PR の head が `HEAD` と違う（push していない・pull していない commit がある）
  ときは、比べるのは手元の `HEAD` のまま、そのことを知らせる
- どれに決めたか・merge-base・ファイルの数は、fzf のヘッダ（`--list` では stderr）に出る

```sh
gdp                          # 選んで出す
gdp --base origin/develop    # 比べる相手を指定する (gh を引かない)
gdp --list | sort            # 選ばずに並べる。push 済みなら gh pr diff --name-only | sort と同じ集合になる
```

`gh pr diff --name-only` は ASCII 以外を含むパスを `"nix/\346\227\245..."` のように引用して出す。
`--list` は git の設定どおり（`core.quotepath = false` なので引用しない）に出すので、日本語などを
含むパスだけ書き方が違う。

rename は元と先の両方を `git diff` に渡すので、rename として出る（`--list` では先のパスだけ）。
空白・改行・タブ・glob の文字（`[ab].txt` など）を含むパスも、そのままのファイルを指す。

### fetch 系を gh の資格情報で通す (git gh)

`git gh <コマンド>` は、GitHub との通信だけを gh の資格情報（HTTPS）に向けて git を呼ぶ（実体は
`nix/pkgs/git-gh/`。全ホストの PATH に入る。`git-gh <コマンド>` と直に呼んでも同じ）。Claude のセッションに
渡しているのと同じ組（`nix/lib/git-via-gh.nix`。[Claude のセッションだけ git の設定を変える](#claude-のセッションだけ-git-の設定を変える)）を
`-c` で付けて git を呼ぶだけで、効くのはそのコマンドの間だけ。origin の URL も git の設定ファイルも書き換えない。
GitHub との通信と認証は、WSL でも `ssh.exe` と 1Password の承認ダイアログを通らない（`pull` が merge commit を
作るときの署名は別で、今までどおり 1Password を通る）。

host option **`dotfiles.claude.gitViaGh.enable`**（既定 true）のマシンでは、fish の abbr と bash の alias の
fetch 系がこれを使う。false なら今までどおり `git`（ssh）で打つ。

| 名前 | true（既定） | false |
| --- | --- | --- |
| `gfp` | `git gh fetch --prune && git gh pull`（`gfp-gh` と同じ中身） | `git fetch --prune && git pull`（`gfp-base` と同じ中身） |
| `gfp-gh` | `git gh fetch --prune && git gh pull` | 同じ |
| `gfp-base` | `git fetch --prune && git pull`（今までの `gfp`） | 同じ |
| `gf`・`gpul`・`gpull`・`gcl` | `git gh fetch --prune` などで打つ | `git fetch --prune` などで打つ |
| `gpr` と `git_*` の関数 | `remote show`・`fetch`・`pull` を `git gh` で打つ | `git` で打つ |
| `gp`・`gpf`・`gpup`（push） | `git`（ssh）のまま | 同じ |

関数は `git_get_default_branch`・`git_fetch_branch`・`git_fetch_base`・`git_branch_cleanup`（`_force` も）・
`git_fetch_pull_request`（`gpr`）。

- `gfp` には `gfp-gh` / `gfp-base` の名前ではなく中身を書いている。fish の abbr は展開した結果をもう一度は
  展開しないので、名前に展開すると、その名前のコマンドが無くて落ちるため
- `gfp-base`・`gfp-gh`・`git gh` は option によらず使える。true のマシンで 1 回だけ ssh で通すなら、`gfp-base`
  か、`git` で直に打つ
- gh が無い・github.com にログインしていないと、`git gh` は git を呼ばずに止まり、gh を通さない打ち方
  （`gfp` なら `gfp-base`）を案内する。ログインしていなければ `gh auth login` と、gh が出した理由も出す
  （そのまま git を呼ぶと、資格情報が取れずに Username の入力待ちになるため）
- 読み替わるのは GitHub の ssh の URL（`git@github.com:` と `ssh://git@github.com/`）だけ。GitHub 以外の remote と
  ssh のホスト別名は ssh を通る
- git の設定ファイルに別の credential helper（`store` など）があっても、github.com には gh だけを使う。`git gh` は
  github.com の helper をいったん空にしてから gh を足す（`gh auth setup-git` が書くのと同じ形）。ほかの host の
  helper はそのまま使われる
- 自分のターミナルの素の git は変わらない。git の設定ファイルで全部を読み替える形にしないのは、エディタの git や
  push まで gh に向く（`insteadOf` は push の URL も読み替える）ため。`programs.gh` を使わない理由と同じ
  （`home/modules/packages.nix`）
- abbr / alias は `home-manager switch` だけで変わる（開き直したシェルから）。Claude の側の反映は `setup --update` まで要る

```sh
gfp                       # true のマシンでは git gh fetch --prune && git gh pull に展開される
git gh ls-remote origin   # 1 回だけ gh で通す
gfp-base                  # true のマシンで 1 回だけ ssh で通す
```

#### setup の取得も gh で先に試す

`dotfiles.claude.gitViaGh.enable` のマシンでは、`setup` が GitHub から取るところも `git gh` を先に試す（TKT-221）。
ssh を張り直したあとの herdr の中のように `SSH_AUTH_SOCK` が消えた socket を指していても、gh が使えれば
ssh-agent に触れずに取れる。

| どこ | 取るもの |
| --- | --- |
| `bootstrap-claude-skills.sh` | claude-skills の clone と取得 |
| `bootstrap-cc-pages.sh` | cc-pages の clone と取得 |
| `bootstrap-dotfiles-private.sh` | dotfiles-private の clone と取得 |
| `setup.sh`（`--self-update`） | 本体の fetch（origin が GitHub の ssh の URL のとき。https の origin は ssh-agent に頼らないので、今までどおり `git` で取る） |

4 つとも同じ関数 `git_github` を持ち（単体で配るので共通のファイルにしない。`git-github-helpers-test` が
本文の一致と振る舞いを見る）、次の順に試す。

1. `~/.local/state/dotfiles/git-via-gh.json`（home-manager が option の値を書く。jq を使わずに読む）の
   `enable` が `true` でなければ、今までどおり `git`（ssh）だけで取る
2. gh か git-gh が無い・`gh auth token --hostname github.com` が通らないなら、その理由を 1 行出して ssh で取る
3. `git gh` で取る。取れたら「gh の資格情報 (HTTPS) で取りました。」を出す
4. `git gh` で取れなければ ssh で取り直し、取れたら警告する。最後のまとめにも出る（gh の token が切れていると
   Claude の git も通らないため。`gh auth status` で確かめる）

- どちらでも取れなければ、今までどおり手元の clone のまま続ける。警告の続きの行は、試した経路に合わせて
  `ssh -T git@github.com`・`gh auth login`・`gh auth status` を案内する
- gh が使えずに ssh へ回したことは、まとめに出さない（未ログインは `bootstrap-claude-env` が既にまとめに出す）
- bootstrap の 3 つは、取得（`fetch`）と `merge --ff-only` を分けている。ssh で取り直すのは取得の失敗だけで、
  履歴が分岐して fast-forward できないときは、その警告を 1 回だけ出す
- 状態ファイルは switch で置かれるので、option を変えた直後の `setup --update` では switch の後の手順から効く。
  本体の更新は switch より前に走るので、前の世代の値で動く
- `git gh clone` で取っても origin の URL は ssh の形のまま残る。option を false にしても、その clone は ssh で取れる

### ghq の repo をまとめて最新にする (pjp-ghq-pull)

`pjp-ghq-pull` は、ghq の repo を org（`host/owner`）・repo 単位の木で選び、選んだ repo の既定 branch を
`fetch --prune` と fast-forward で最新にする TUI（実体は `nix/pkgs/pjp-ghq-pull/`。Rust。全ホストの PATH に入る）。
そのまま進められない repo は確認待ちに回し、答えを待つ間もほかの repo は並列（既定 8 本）で進める。端末で起こす
（端末でなければ何もせずに止まる）。

```sh
pjp-ghq-pull                  # 選ぶ画面を開く
pjp-ghq-pull -j 4             # 並列を 4 本にする
pjp-ghq-pull --no-via-gh      # この回だけ fetch を素の git (ssh) で打つ (--via-gh はその逆)
pjp-ghq-pull --timeout 300    # fetch の時間切れを 300 秒にする (既定 120)
pjp-ghq-pull --root /tmp/x    # ghq の root の代わりに /tmp/x の下を出す (GHQ_ROOT=/tmp/x で ghq を呼ぶ)
```

選ぶ画面のキー:

| キー | すること |
| --- | --- |
| Space | カーソルの行を on/off。org の行は、下の repo が全部 on なら全部 off、でなければ全部 on |
| a / n | 全選択 / 全解除（絞り込み中は絞り込んだ repo だけ） |
| ← / → | org を畳む / 開く |
| / | 絞り込む（repo の相対パスに含むか。大文字小文字は区別しない。Enter で確定、Esc で消す） |
| Enter | 選んだ repo で始める |
| q / Esc | 何もせずにやめる |

- org の印は、下の repo が全部 on なら `[x]`、一部なら `[-]`、全部 off なら `[ ]`
- repo の行の右に今の branch を出す。既定 branch でない branch は黄、追跡中のファイルに変更がある repo には赤の
  「変更あり」（手元だけを見る。通信しない）。外したい repo は Enter の前に外す
- 上の行に経路（`git gh (gitViaGh)` か `git`）と選んだ数
- Enter で選んだ組を `$XDG_STATE_HOME/pjp-ghq-pull/deselected`（無ければ `~/.local/state/pjp-ghq-pull/deselected`）に
  残し、次に開いたときの初期値にする（外していた repo の絶対パスを 1 行 1 つ）。新しく `ghq get` した repo は on で出る。
  読めないときは全部 on で始める

1 つの repo の流れ:

1. git の work tree の直下でない entry（bare の repo など。ghq の hg などの repo は初めから出さない）は、何もせずに
   スキップ。作業途中（rebase・merge・cherry-pick・revert の途中か、`index.lock` がある = ほかの git が動いている）・
   origin が無い repo は、fetch せずに確認待ち
2. `fetch --prune origin`（gitViaGh なら `git gh fetch --prune origin`）。確認が要る repo でも先に流す
3. 既定 branch（`origin/HEAD` の指す branch。無ければ `origin/main`、`origin/master` の順。`git remote set-head` は
   打たない）と、その upstream で ahead / behind を数える
   upstream が origin の branch でない（fork で `upstream/main` を追うなど）ときは、fetch していない remote と比べて
   「最新」と言わないよう、確認待ちにする
4. behind = 0 なら「最新」で終える（未 push の commit・変更・別の branch があっても問わない）
5. 既定 branch にいて、追跡中のファイルに変更が無く（未追跡のファイルは数えない）、ahead = 0 なら
   `merge --ff-only` で進める（結果は `git pull --ff-only --prune` と同じで、通信は fetch の 1 回だけ）
6. それ以外は確認待ち

確認待ちの理由と選べること（理由が重なったら上から先のものを問う）:

| 理由 | 選べること |
| --- | --- |
| 作業途中・既定 branch か upstream が無い・upstream が origin でない | s 何もしない |
| fetch の失敗（時間切れ・認証など） | s 何もしない / t もう一度 |
| 既定 branch でない（別の branch・detached） | s / u checkout せずに既定 branch だけ進める / c 既定 branch に切り替えて進める（変更が無いときだけ。detached なら、HEAD の commit がどれかの branch にあるときだけ） |
| 追跡中のファイルに変更がある | s / f そのまま fast-forward を試す（重なるファイルがあれば git が止め、変更は残る） |
| 分岐している（merge commit が要る） | s / m merge commit を作る / r rebase する（途中で止まったら中断して元に戻す） |

実行中の画面:

- 上に「完了 n/m」と「確認待ち k」、中に repo ごとの状態（待ち・fetch 中・更新 +N・最新・確認待ち・スキップ・失敗）、
  下に確認待ちの欄（来た順）
- 答えのキー（s t u c f m r）は、確認待ちの欄にいるときだけ効く（Tab で一覧と行き来する）。d で詳細
  （`git status -sb` と、既定 branch と upstream の log。fetch の失敗は stderr も）
- 答えると、その repo の続きを作業の列に積み、すぐ次の問いへ移る。答えを流す前に判定をやり直し、問いの後に repo が
  変わっていれば（変更を足したなど）流さずに問い直す
- 今の問いの repo は ▶ の行で目立たせる。問いが替わってから 1 秒は、repo の形を変える答え（u・c・f・m・r）を受けず、
  受けなかったと知らせる（答えると次の問い = 別の repo が同じ所に出るので、二度押しや押しっぱなしの 2 打目が別の repo の
  merge などにならないように）。押しっぱなしの間は待ちが延びる。s・t・d はすぐ効く
- m・r が途中で止まったら `--abort` で元に戻す。未解決のファイルがあれば「衝突」、無ければ（commit の署名の失敗・hook
  など）「衝突ではない」として stderr を添え、分けて出す。`--abort` も失敗したら「元に戻せなかった」と repo のパスを
  出す（手で直す）
- q（Ctrl-C も）で終えると、確認待ちとまだ始めていない repo は「何もしない」になる。動いている git は止めずに、
  終わるのを待ってから閉じる（git を途中で止めると `index.lock` や途中の merge が残るため。通信は時間切れで終わる）。
  その repo の次の git（fetch の後の fast-forward など）は起こさず、「やめたので途中で止めた」にする
- 閉じると、更新・最新・スキップ・失敗の一覧を端末（stdout）に残す。失敗には git の stderr の最後の 3 行を添える。
  失敗があれば終了コード 1

gitViaGh（`dotfiles.claude.gitViaGh.enable`。[前述](#fetch-系を-gh-の資格情報で通す-git-gh)）:

- `~/.local/state/dotfiles/git-via-gh.json` の `enable` が `true` なら、fetch を `git gh` で打つ。merge・rebase・
  checkout は通信しないので、経路によらず素の git で打つ
- on なのに `git-gh` か `gh` が無い・gh が github.com にログインしていないときは、画面を開く前に止まって
  `gh auth login` を案内する。ssh へは黙って倒さない（WSL では repo の数だけ 1Password の承認が出かねないため）。
  `--via-gh` / `--no-via-gh` でその回だけ上書きできる

安全のための決まり:

- push・stash（`merge.autoStash` の設定があっても）・reset・branch の削除はしない。選んでいない repo と、既定 branch
  以外の branch（問いで選んだときを除く。`rebase.updateRefs` の設定があっても）は触らない
- git は端末から切り離して（新しい session・stdin なし・`GIT_TERMINAL_PROMPT=0`）呼び、パスワードの入力待ちを失敗に
  する。`core.sshCommand` などのユーザーの設定はそのまま効く
- 1 つの repo に git を 2 本同時に流さない。merge commit を作るのは m を選んだときだけ（commit の署名の設定があれば
  1Password の承認が出るので、m と r には時間切れを付けない）

対象の外: push・submodule・LFS・ghq の外の repo（herdr の worktree など）・端末の無い所（cron・Claude の Bash）・
Windows のネイティブ（WSL と macOS は対象）。

**試すときは `~/ghq` に向けない**（fetch と merge で checkout が変わる）。一時ディレクトリに bare の remote と clone を
作り、`--root` でその ghq root を指す。テストは `nix/pkgs/pjp-ghq-pull/tests/`（何を確かめるかは各ファイルの先頭）に
あり、flake の checks の `pjp-ghq-pull-test`（package の build の中の `cargo test`。全 system）と `pjp-ghq-pull-lint`
（`cargo fmt --check`・`cargo clippy --all-targets -- -D warnings`。Linux だけ）が流す。直すときの道具は
`nix/pkgs/pjp-ghq-pull` の中で `nix develop ../..#pjp-ghq-pull`（cargo・rustc・clippy・rustfmt・git・ghq）。
crate の版は公開から 7 日以上経ったものに限る（cargo には猶予の設定が無いので、`Cargo.lock` を作り直したら
crates.io の公開日時を見て、新しすぎる版は `cargo update -p <名前> --precise <前の版>` で下げる）。

## ssh について

`programs.ssh` で `~/.ssh/config` を**生成**しているが、中身は Include の 1 行と、このマシンを名乗る `SetEnv` だけ。

```
Include config.d/*.ssh_config

Host *
  SetEnv PJP_SSH_CLIENT="%u@%L"
```

（`ssh` は相対パスの `Include` を `~/.ssh/` 基準で解決する。`SetEnv` は ssh 先の herdr が「同じマシンから来た接続」を
見分けるのに使う。[後述](#forward-された-agent-を固定名で見せる)）

接続先の実体は private な [pollenjp/dotfiles-private](https://github.com/pollenjp/dotfiles-private) の
`ssh/*.ssh_config` にある（公開したくないので、この repo にも `/nix/store` にも置かない）。
`bootstrap-dotfiles-private.sh`（order 50）が clone / pull し、`bootstrap-ssh-config.sh`（order 60）が
`~/.ssh/config.d/` へ symlink する。どちらも `setup --update` で毎回走る。

```sh
./nix/scripts/bootstrap-ssh-config.sh
```

冪等。dotfiles-private を取れていない・`ssh/` が空なら、今ある symlink を外さずに警告だけ出す（処理は止めない）。

| `~/.ssh/config.d/` の中身 | 出所 |
| --- | --- |
| `*.ssh_config` (symlink) | dotfiles-private の `ssh/`。スクリプトが張る |
| それ以外 | 手で置いたマシン固有の設定や、ほかのツール（my-cloud など）が書いた設定。スクリプトは触らない |

正本からファイルが消えた場合、それを指す symlink はスクリプトが外す（以前の `.ssh` submodule を指す
symlink も外して張り替える）。手で置いたファイルや、ほかを指す symlink には触らず、同じ名前のものが
あれば上書きせずに警告する。

マシン固有の設定を足すときは `~/.ssh/config.d/` にファイルを置く。
`ssh` は同じキーワードについて**最初に得た値**を採るので、**ファイル名の順序が
優先順位**になる。実効値は `ssh -G <ホスト名>`、読んだファイルは `ssh -v -G <ホスト名>` の
`Reading configuration data` の行で確認できる。

Windows 側（`%USERPROFILE%\.ssh`）へは `bootstrap-windows-ssh-config.sh`（order 91）が同じ形で
コピーする。[`win/README.md`「ssh の設定」](../win/README.md#ssh-の設定) を参照。

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
> [ADR 003](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/003_nix_ssh_config_20260810T210714JST/README.md) を参照。
> 接続先を `.ssh` submodule から dotfiles-private へ移し、Windows へも配るようにした経緯は
> [ADR 016](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/016_ssh_config_from_dotfiles_private_20261012T131912JST/README.md)。

### WSL では ssh 自体を Windows 側に差し替える

1Password の ssh-agent は**ホスト側 Windows**にいる。この dotfiles は npiperelay や
socat で `SSH_AUTH_SOCK` を橋渡ししていないので、WSL 側の Linux ssh からは agent が
見えない。そこで `ssh` / `ssh-add` そのものを Windows 側の実体へ `exec` する
ラッパーに差し替える。

| 配置先 | 実体 | 何をする |
| --- | --- | --- |
| `~/.local/bin/ssh` | `nix/files/bin/ssh-wsl.sh` | `exec ssh.exe "$@"` |
| `~/.local/bin/ssh-add` | `nix/files/bin/ssh-add-wsl.sh` | `exec ssh-add.exe "$@"` |

置かれるのは **WSL で `onePassword.enable = true` のマシンだけ**（レガシーの
`main.bash` は `uname` と `ssh.exe` の有無で実行時に判定していたが、Nix 経路では
[登録簿](#マシン登録簿-hostsdefaultnix)の指定で決まる）。`$HOME/.local/bin` は
`home.sessionPath` で PATH の前に入るので、これがディストリの `ssh` より先に当たる。

Linux 側の ssh を使いたいときは `USE_LINUX_SSH=1` を渡す（ラッパー側の分岐）。

```sh
USE_LINUX_SSH=1 ssh <ホスト名>
```

このため、WSL の `ssh` が読む設定は Windows 側の `%USERPROFILE%\.ssh\config` になる（WSL 側の
`~/.ssh/config` が効くのは `USE_LINUX_SSH=1` のときだけ）。Windows 側の設定は
`bootstrap-windows-ssh-config.sh` が置く（[`win/README.md`「ssh の設定」](../win/README.md#ssh-の設定)）。

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

Windows (Git for Windows) 用の `bin/ssh-*-git-for-win.sh` は移さず、旧経路と一緒に削除した
（[ADR 013](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/013_remove_legacy_tree_20261007T015646JST/README.md)）。

### WSL の .exe の起動を常時記録する

上のラッパーで、WSL の `ssh` は Windows の `ssh.exe` として 1Password に届く。そのため
**1Password の承認ダイアログは要求元を「Windows Terminal」としか出さない。** しかも承認は
タブ（`wsl.exe`）単位で効くので、一度承認すると同じタブのどのプロセス（herdr の別ペインや
Claude Code など）もダイアログ無しで鍵を使える。要求元が分かるのは Linux 側で `.exe` の
起動を見たときだけなので、そのための道具を 2 つ置く（経緯は
[ADR 012](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/012_wsl_exe_exec_trace_service_20260930T153253JST/README.md)）。

| 道具 | 置かれるマシン | 使いどころ |
| --- | --- | --- |
| `pjp-who-is-asking` | `wsl.enable` | ダイアログが出たら打つ。直近の要求（下の記録。入っていれば）と、いま動いている要求元を Windows と Linux をまたいだ木で出す |
| `pjp-exe-exec-trace` | `wsl.exeExecTrace.enable` | root の systemd の unit で常時動かす。WSL から起動された `.exe` を祖先付きで journald に残す（黙って通った要求も残る） |

#### 入れる

使うマシンは、dotfiles-private に登録したファイルか `~/dotfiles/flake.nix` に足したホストで `wsl.exeExecTrace.enable = true`
（`mkHome` の引数）を書く。eBPF には root が要るので、
**switch だけでは動かない。** unit を `/etc/systemd/system` へ入れるのは setup の手順
`exe-exec-trace` で、「既存マシン更新」（`--update`）の最後に走り、中で `sudo` を呼ぶ。
**`sudo` を付けて打たないこと**（`HOME` が root のものになり、生成された unit を見失うので、
手順は root では断る）。

```sh
~/dotfiles/setup --update   # unit ファイルを生成し、/etc へ入れて起こす (中で sudo を呼ぶ)
```

パスワード無しで `sudo` できないマシンで、端末の無いところ（Claude の Bash ツールなど）から
打つと、手順は入れずに飛ばし、最後の「残りの手作業」に「unit がまだ入っていない」と出る。
そのときは端末から `~/dotfiles/setup --steps exe-exec-trace` を打つ。

unit は `Type=notify` なので、手順の `restart` はトレーサが BPF を読み込み終えるまで待ち、
読み込みに失敗すれば手順も失敗する。起動に失敗し続けたら（WSL のカーネルが更新されて
BPF が読み込めなくなったときなど）10 分に 5 回で諦めて `failed` になる。手順は止まっている
unit を起こし直すので、直るまでは `--update` の最後のこの手順が失敗する
（理由は `sudo journalctl -u dotfiles-exe-exec-trace -n 30` で見る。止めておきたいなら
option を false にする）。

unit の `ExecStart` は store の固定パスにしてある（root がユーザーの書き換えられるパスを
実行しないため）。その代わり、トレーサが更新されたら unit を入れ替える必要がある。
`--update` が switch の後にこの手順も走らせるので、更新と一緒に入れ替わる。手順を外して
走らせたときや `sudo` を訊けずに飛ばしたときは古い版が動き続け、最後の「残りの手作業」に
「入っている unit が古い」と出る。
手順は unit の store パスへ GC root（`/nix/var/nix/gcroots/dotfiles-exe-exec-trace`）を
張るので、`nix-collect-garbage` で動いているトレーサが消えることはない。

#### 読む

```sh
journalctl -u dotfiles-exe-exec-trace -o cat | pjp-exe-exec-trace --pretty           # 全部
journalctl -u dotfiles-exe-exec-trace -o cat --since today | pjp-exe-exec-trace --pretty
journalctl -u dotfiles-exe-exec-trace -o cat -f | pjp-exe-exec-trace --pretty        # 流れてくるのを見る
```

ADR 012 の検証で、agent を使わない `ssh.exe` を git から起動したときの記録（cwd・env・
祖先の cmdline の行は略）:

```
2026-10-01T00:53:26.981+09:00  ssh.exe  pid=446394 uid=1000 distro=this
    argv[0]: ssh.exe
    argv[1]: -o
    argv[2]: IdentityAgent=none
    argv[3]: -o
    argv[4]: BatchMode=yes
    argv[5]: -o
    argv[6]: ConnectTimeout=3
    argv[7]: -o
    argv[8]: SendEnv=GIT_PROTOCOL
    argv[9]: fake@192.0.2.1
    argv[10]: git-upload-pack '/pollenjp/example.git'
    at exec: git(446393) <- zsh(446388) <- claude(15259) <- fish(1328) <- herdr(972) <- …
```

- 引数は 1 引数 1 行で、祖先のコマンドラインは 1 プロセス 1 行で、記録してある分（1 つ 1 KiB
  まで）を切らずに出す。Claude の Bash ツールは `zsh -c 'source <スナップショット> … && eval '<実際の
  コマンド>''` の形で、実際のコマンドが長い前置きの後ろにあるので、祖先の行は長くなる
- 祖先のコマンドラインは、1 つの引数に空白があっても区切りが分かるようシェルの引用でつないで
  記録する（`zsh -c 'echo a b'`）。2026-10-02 より前の記録は空白でつないだまま

- `adm` か `systemd-journal` のグループに入っていれば `sudo` は要らない
- agent に届く `.exe`（`ssh.exe`・`ssh-add.exe`・`scp.exe`・`sftp.exe`・`op-ssh-sign*.exe`）
  以外には「踏み台かもしれない .exe」と付く。`wsl.exe` や `cmd.exe` を経由した要求は、
  `ssh.exe` の祖先が新しいセッションの `/init` で途切れるので、直前に起動した踏み台の祖先を見る
- agent に届くものだけ見るなら `pjp-exe-exec-trace --pretty --only-agent`
- 1 行 1 イベントの JSON。`-o cat` には systemd の「Started …」のような JSON でない行も
  混ざるので、`jq` で読むなら `jq -cR 'fromjson? | select(.agent)'` のように読めない行を飛ばす
- 表示では、記録の中の改行や ESC などの制御文字を `\xNN` にする（記録される側が argv で
  偽の行を差し込んだり端末を操作したりできないように）

ダイアログが出たら `pjp-who-is-asking` を打つ。先に直近 3 分の記録（agent に届く `.exe` と、
`cmd.exe /c ssh.exe …` のようにそれを引数で呼ぶ踏み台）を要求元までの木で出し、そのあとに、
いま動いている要求元を Windows と Linux をまたいだ木で出す。
要求元はダイアログに気付く前に終わっていることが多いので（Claude Code の GitHub SSH の確かめは
3 秒で kill されるが、ダイアログは約 60 秒残る）、たいていは記録の節に答えがある
（[ADR 020](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/020_who_is_asking_recent_journal_20261017T110906JST/README.md)）。

```sh
pjp-who-is-asking                # 直近 3 分の記録と、いま動いている木 (Windows 側は powershell.exe で 1〜2 秒)
pjp-who-is-asking --recent 600   # 直近 10 分まで遡る
pjp-who-is-asking --recent 0     # 記録を読まない
pjp-who-is-asking --no-windows   # Windows 側を省く (記録の節は出す)
```

- 記録の節は古い順で、ダイアログの要求はたいてい一番下（一番新しいもの）。要求元がまだ動いていれば
  「動いている (下の木にも出る)」、終わっていれば「終了済み」と付く
- 記録は「起動された」ことしか分からない。承認済みのセッションから黙って通った要求も並ぶので、
  どれがいまのダイアログの要求かは時刻から推す
- `exeExecTrace.enable` が無いマシンでは、記録の節は「入っていない」の 1 行だけになり、
  いま動いている木は今までどおり出る

#### 外す

`exeExecTrace.enable` を false にして `--update` を打つ。switch の後に走る手順が、
生成された unit が無いので、入っている unit を止めて消す（GC root も消す）。

```sh
~/dotfiles/setup --update
```

#### 気を付けること

- **閉包が約 1.5 GiB 増える。** bcc は実行時に BPF のプログラムを clang でコンパイルするので、
  clang と LLVM を丸ごと持つ
- 常駐中のメモリは約 160 MB。起動のたびに数秒 CPU を使う（BPF のコンパイル）
- 他ディストロの起動も記録されるが、祖先は comm と PID だけになる（その `/proc` は見えない）
- 親が先に終了した要求（`cmd & exit` や `nohup`）は、祖先がセッションの `/init` で途切れる。
  代わりに env（`CLAUDE_CODE_SESSION_ID` / `HERDR_PANE_ID` / `WT_SESSION`）と cwd が残る
- **隠れようとする相手の記録には使えない。** 記録するのは名前が `.exe` で終わる実行ファイルの
  起動だけで、`.exe` でない名前にした Windows の実行ファイル・`$WSL_INTEROP` のソケットを直接
  叩く interop・journald の流量制限を超える大量の起動では抜けられる。パスワード無しで
  `sudo` できるマシンなら、同じユーザーのプロセスは unit ごと止められる。記録できるのは
  「隠れる気の無い呼び出し元」（普通のツールやエージェント）までと考える
- 記録には argv と祖先のコマンドライン（それぞれ 1 KiB まで）が残る。`/var/log/journal` は
  `adm` のグループで読め、`wsl --export` にも入るので、コマンドラインに秘密を渡す使い方には
  向かない

### forward された agent を固定名で見せる

ssh 先で herdr を常駐させると、**ssh を張り直したときに中から agent が引けなくなる。**
sshd が接続ごとに作る agent の socket（OpenSSH 10.1 からは `~/.ssh/agent/s.<hash>.sshd.<乱数>`）は接続が閉じると
消えるのに、herdr server は起動したときの env を抱えて常駐し、実行中のプロセスの env は外から書き換えられないため。

そこで herdr の **session ごとの固定名**（symlink）を挟み、server と pane には固定名を渡して、その先だけを生きている
接続の socket へ向け直す。判断の経緯は [ADR 008](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/008_ssh_agent_stable_sock_20260909T144947JST/README.md)
（固定名）・[ADR 022](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/022_one_password_outside_wsl_20261018T105655JST/README.md)（手元の 1Password）・
[ADR 025](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/025_herdr_agent_borrow_20261020T210555JST/README.md)（session ごと・hr・同じマシンの接続を借りる）。

| session | 固定名 |
| --- | --- |
| default | `~/.ssh/agent.sock` |
| ほか（`s2` など） | `~/.ssh/agent.<session>.sock` |

| 部品 | 役割 |
| --- | --- |
| `herdr`（`nix/pkgs/pjp-agent-link/herdr.sh` で包んだもの） | server を起こしうる呼び出し（`herdr`・`herdr session attach <名前>`・hr の `remote-client-bridge`・`herdr server`）で、`SSH_AUTH_SOCK` をその session の固定名にしてから本物の herdr を exec する。`herdr server` 以外では、その前に向け先を決め直す。`h` / `ha` / `hss` などの alias もここを通る |
| `pjp-agent-link` | 向け先を決める script（`nix/pkgs/pjp-agent-link/pjp-agent-link.sh`）。決め方は下の表。`ssh-add` と `flock` は PATH の system のもの（ssh 先の OpenSSH と util-linux）を使う |
| `~/.ssh/rc` | sshd が接続のたびに走らせる。forward された socket・`PJP_SSH_CLIENT`・開いた時刻を記録するだけ（張り替えない） |
| `pjp-agent-link-watch.path`（systemd の user の unit。Linux だけ） | `~/.ssh/agent` と記録の場所に変化があると `pjp-agent-link watch` を起こす。接続が閉じたときに向け直せるのはこれだけ |
| `ssh-agent-link`（コマンド） | 今の session（引数・`HERDR_SESSION`・default の順）の固定名を、この shell の接続へ強制で向ける逃げ道 |
| init の `299_ssh_agent` ブロック | `SSH_AUTH_SOCK` が固定名の shell（herdr の pane）と、そのマシンの 1Password の shell では、ローカル agent へのフォールバックをしない |

| きっかけ | 固定名の今の先 | 決め方 |
| --- | --- | --- |
| herdr を開いた（attach） | 生きていて、持ち主が開いた接続と同じ値 | 変えない（切断前の接続を優先する） |
| herdr を開いた（attach） | 死んでいる・持ち主が分からない・別の値 | 開いた接続へ向け、持ち主をその値にする |
| 接続が増えた・減った（見張り） | 生きている | 何もしない（覗くだけの接続は奪わない） |
| 接続が増えた・減った（見張り） | 死んでいる | 持ち主と同じ値の、生きている一番古い接続を借りる。無ければ dangling のまま |

- attach は開いた session の固定名だけを動かし、見張りは全部の固定名を見直す。default と s2 がどちらも切断され、
  同じ PC からの接続が 1 本だけ生きていれば、両方がそれを指す
- 「生きている」は `ssh-add -l` が 1 秒以内に返事をすること（回線断で返事をしない socket で固まらない）
- 持ち主は、固定名を張ったときの開いた接続の `PJP_SSH_CLIENT`（`~/.local/state/pjp-agent-link/owner/<session>`）。
  この仕組みを入れる前に張られた固定名は、持ち主が分からないものとして扱う
- 手元（`SSH_CONNECTION` が無い）で張り替えるのは、`SSH_AUTH_SOCK` がそのマシンの 1Password のときだけ
  （NixOS の laptop。ADR 022）。持ち主は `local` で、socket が無くても張る。**WSL の手元の挙動は変わらない**
- `ssh -a` で入った shell・フォールバックのローカル agent（`SSH_AGENT_PID` がある）からは張らないが、ssh 先なら
  server には固定名を渡す

#### 同じマシンは `PJP_SSH_CLIENT` で見分ける

各マシンの ssh は `SetEnv PJP_SSH_CLIENT=%u@%L` で自分のユーザー名とホスト名を名乗る（Nix の `~/.ssh/config` と、
Windows は `bootstrap-windows-ssh-config.sh` が置く `%USERPROFILE%\.ssh\config`）。

- **受け取る側の sshd に `AcceptEnv PJP_SSH_CLIENT` が要る**（無い sshd は捨てる）。NixOS のホストは nixos-config が
  入れる（TKT-255）。ほかの ssh サーバーは、下の警告を見て都度足す。届かない接続は借りない・借りられないだけで、
  attach し直せば鍵は使える
- 値は ssh の実体ごとに違い、違う値は別のマシンとして扱う（大文字小文字は揃えない）。**同じ PC でも、Windows の ssh.exe
  （hr の `herdr.exe` と、WSL の `ssh`）は `<Windows のユーザー名>@<PC の名前>`、WSL の Linux の ssh は別になる**（`/usr/bin/ssh` の
  9.6p1 は下のとおり届いていない扱い、nix の OpenSSH なら `<WSL のユーザー名>@<PC の名前>`）
- `%u@%L` が展開されるのは OpenSSH 10.0 から。WSL の `/usr/bin/ssh`（9.6p1）など古い ssh は `%u@%L` のまま送るので、
  `%` を含む値は届いていないものとして扱う
- ssh は最初に当たった `SetEnv` の行だけを使う。`config.d` の `Host` に自分の `SetEnv` がある接続先では、そこにも
  `PJP_SSH_CLIENT=%u@%L` を足す
- 値は名乗るだけなので、なりすましは防げない（誤作動を防ぐ保険）

**値が届いていないと、プロンプトに `⚠ PJP_SSH_CLIENT なし` が出る**（starship の `custom.pjp_ssh_client`）。ssh で入った
shell では `PJP_SSH_CLIENT` が空のとき、herdr の pane ではその session の固定名の持ち主が空のとき（pane の env には
server を起こした接続の値が残るので、記録を見る）。この仕組みを入れる前に張られた固定名と、`herdr server` で起こしただけで
まだ誰も開いていない session も持ち主が空なので、値の届く接続から 1 回開くまで出る。

> ⚠️ 適用しても**すでに走っている herdr server には効かない**（固定名を持たずに起きている）。都合のよいときに
> 1 回作り直す。pane のプロセスは終わる（Claude Code は herdr の agent session restore で会話へ戻れる）。
>
> ```sh
> herdr server stop             # default
> herdr session stop s2         # named session ごとに
> herdr.exe --remote <ssh 先>.local   # Windows の PowerShell から開き直す (包んだ herdr を通って server が起きる)
> ```

herdr の中で鍵が引けなくなったら、detach して開き直す（attach が今の接続へ向け直す）か、herdr の外の ssh の shell で
`ssh-agent-link` を打つ。ssh 先の PC の前 (手元) で開き直すときは、新しい端末から開く（前からある端末の shell は、フォールバックが
起こしたローカル ssh-agent を `SSH_AUTH_SOCK` に持っていることがあり、手元の分岐に当たらない）。

確認は ssh 先で次のとおり。

```sh
pjp-agent-link status        # 固定名ごとの先・生死・持ち主と、記録にある接続
# herdr の pane の中で
echo "$SSH_AUTH_SOCK"        # ~/.ssh/agent.sock (named session は ~/.ssh/agent.<名前>.sock)
ssh-add -l                   # 鍵が並ぶ
```

- 張り替えと接続の記録（rc）のたびに `~/.local/state/pjp-agent-link/log` に 1 行残る（どの接続がいつ固定名を動かしたか）
- **ssh 先の PATH で、包んでいない herdr が先に見つかると固定名は渡らない。** herdr.exe は ssh 先の herdr と版が合わないとき
  `~/.local/bin/herdr` へ入れることを提案する（既定は Yes。`~/.local/bin` は `~/.nix-profile/bin` より前）。断るか、入れて
  しまったら `~/.local/bin/herdr` を消す。`pjp-agent-link status` の最後の行で、PATH の herdr が包んだものかを見られる
- 見張りが動いているかは `systemctl --user status pjp-agent-link-watch.path`。何かで failed になっていたら
  `systemctl --user reset-failed pjp-agent-link-watch.path pjp-agent-link-watch.service` のあとで
  `systemctl --user start pjp-agent-link-watch.path`
- `~/.ssh/rc` を置くと、sshd は xauth を自分では呼ばず（rc が PATH の `xauth` へ渡す。X11 forwarding を使うホストでは
  `xauth` を PATH に置く）、`/etc/ssh/sshrc` も走らせない。sftp・ForceCommand・
  `PermitUserRC no`・authorized_keys の `restrict` / `no-user-rc` の接続では rc が走らず、見張りはその接続を借りない。
  手で置いた `~/.ssh/rc` があると、switch が「would be clobbered」で止まる（中身を確かめて退避する）
- 見張りは OpenSSH 10.1 より古いホスト（socket が `/tmp/ssh-*/`）と macOS では動かない（attach の張り替えだけが効く）
- 削除した session の固定名と持ち主の記録は残る（害は無い。要らなければ `~/.ssh/agent.<名前>.sock` と
  `~/.local/state/pjp-agent-link/owner/<名前>` を消してよい）

## WSL の eth0 の MTU を上限まで下げ続ける

VPN のトンネルの実効 MTU が WSL の eth0 の MTU より小さく、トンネルの奥から返る ICMP（Fragmentation Needed）が
WSL（NAT モード）まで届かないと、実効 MTU を超える大きさのパケットが黙って捨てられ続ける（PMTU ブラックホール）。
ping や小さい GET は通るので、**つながっているのに大きな送信だけが止まる**（本文が数十 KB ある Claude Code の API の
リクエストは、応答しないまま時間切れになる）。WSL はホスト側のネットワークが変わるたびに（VPN の接続・切断など）
eth0 の MTU を設定し直すので、`/etc/wsl.conf` の `[boot]` の `command` のように起動時に 1 回下げるだけでは足りない
（[設計](https://github.com/pollenjp/dotfiles-private/blob/main/docs/superpowers/specs/2026-11-05-wsl-mtu-guard-design.md)）。

`wsl.mtuGuard.enable` のマシンには、eth0 の MTU を上限（`wsl.mtuGuard.maxMtu`。既定 1350）まで下げ続ける見張り
（`nix/pkgs/pjp-wsl-mtu-guard/`）を root の systemd の unit `dotfiles-wsl-mtu-guard` で置く。

- 起動したときに 1 回と、`ip monitor link` のイベントのたびに、eth0 の MTU が上限を超えていたら上限まで下げる
  （イベントが来なくても 30 秒ごとに見直す）。**上げはしない。** VPN を使っていないときも上限のまま（パケットが少し
  小さくなるだけ）
- 下げたときだけ、journal に `eth0 mtu 1392 -> 1350` の形で残す
- 既定の 1350 は、実効 MTU が 1382 のトンネルで測った上限に 32 バイトの余裕を持たせた値。トンネルの実効 MTU が
  もっと小さい回線では下げる（下限は IPv6 の最小の MTU の 1280）

### 入れる

使うマシンは、dotfiles-private に登録したファイルか `~/dotfiles/flake.nix` に足したホストで `wsl.mtuGuard.enable = true`
（`mkHome` の引数の `wsl` の中）を書く。MTU を変えるには root が要るので、**switch だけでは動かない。** unit を
`/etc/systemd/system` へ入れるのは setup の手順 `wsl-mtu-guard` で、「既存マシン更新」（`--update`）で走り、中で `sudo` を
呼ぶ（入れ方は [WSL の .exe の起動を常時記録する](#wsl-の-exe-の起動を常時記録する) の `exe-exec-trace` と同じ。
**`sudo` を付けて打たないこと**）。

```sh
~/dotfiles/setup --update   # unit ファイルを生成し、/etc へ入れて起こす (中で sudo を呼ぶ)
systemctl status dotfiles-wsl-mtu-guard
```

- パスワード無しで `sudo` できないマシンで、端末の無いところ（Claude の Bash ツールなど）から打つと、手順は入れずに
  飛ばし、最後の「残りの手作業」に「unit がまだ入っていない」と出る。そのときは端末から
  `~/dotfiles/setup --steps wsl-mtu-guard` を打つ
- unit の `ExecStart` は store の固定パス（root がユーザーの書き換えられるパスを実行しないため）。手順は unit の store
  パスへ GC root（`/nix/var/nix/gcroots/dotfiles-wsl-mtu-guard`）を張るので、`nix-collect-garbage` で動いている見張りが
  消えることはない
- 見張りの `ip monitor` が落ちたら、systemd が 5 秒おいて起こし直す（諦めない）

### 上限を変える

`wsl.mtuGuard.maxMtu = 1300;` のように書いて `--update` を打つ。unit の中身が変わるので、手順が入れ替えて起こし直し、
eth0 はすぐ新しい上限まで下がる。**上限を上げたときは、見張りは上げないので手で上げる。**

```sh
sudo ip link set dev eth0 mtu <新しい上限>
```

### 読む

```sh
journalctl -u dotfiles-wsl-mtu-guard              # 下げた記録 (eth0 mtu 1392 -> 1350)
ip link show eth0                                  # 今の MTU
```

### 外す

`wsl.mtuGuard.enable` を false にして `--update` を打つ。手順が、生成された unit が無いので、入っている unit を止めて
消す（GC root も消す）。eth0 の MTU はそのまま残る（戻すなら `sudo ip link set dev eth0 mtu <値>`。次に WSL の
ネットワークが変わったときも、WSL が設定し直す）。

### 気を付けること

- **VPN をつないでいる間に見張りが止まっていると、WSL の中の Claude Code 自身が応答しなくなる。** MTU を手で上げて
  試すのは、見張りが動いているときだけにする。固まったら、Windows の PowerShell から
  `wsl -d <ディストロ> -u root -- ip link set dev eth0 mtu 1350` で戻せる
- 前に手で入れた見張り（別の名前の unit）や `/etc/wsl.conf` の boot command は、setup は触らない。dotfiles の見張りが
  enabled・active になってから手で消す（2 つが同時に動いても、どちらも下げるだけなので害は無い）
- WSL を mirrored モード（`networkingMode=mirrored`）にするのも一つの手だが、Docker と `localhost` の挙動が変わるので
  ここでは使っていない

## WSL の xdg-open

`wsl.enable` のマシンの PATH に、URL とファイルを Windows の既定のアプリで開く `xdg-open`（`nix/pkgs/pjp-wsl-xdg-open/`）を
置く（[設計](https://github.com/pollenjp/dotfiles-private/blob/main/docs/superpowers/specs/2026-11-07-wsl-xdg-open-design.md)）。
root は要らないので option は無く、WSL でないマシンには入らない。

Linux 版の herdr は、pane のリンクの Ctrl+クリックで `xdg-open` を呼ぶ（WSL かどうかを見ない。
[herdr の中の Claude Code にリンクを出させる](#herdr-の中の-claude-code-にリンクを出させる)）。WSL の Ubuntu には `xdg-open` が
入っていないので、無いと開かず、画面にも何も出ない（`~/.config/herdr/herdr-client.log` に `failed to open pane URL` が残るだけ）。
PATH に入るので、`gh browse` など `xdg-open` を呼ぶほかの CLI もこれを使う。

| 渡すもの | すること | 終了コード |
| --- | --- | --- |
| `http://`・`https://` の URL | 既定のブラウザで開く。空白・`"`・制御文字・ASCII の外の文字は `%XX` にする | 0 |
| あるファイル・ディレクトリ | `wslpath -w` で変換して、既定のアプリで開く | 0 |
| `file:///…`・`file://localhost/…` | `%XX` を戻して、上のファイルと同じに開く（`#`・`?` の後ろは外す） | 0 |
| 無いファイル | 開かない | 2 |
| Windows が実行するファイル（`.exe`・`.bat`・`.js`・`.ps1`・`.py`・`.lnk` など。網羅ではない） | 開かない。実行したいなら直に打つ | 4 |
| 末尾が `.` か空白の名前・途中のディレクトリの末尾が `.` のパス | 開かない（Windows では別のファイルを指す） | 4 |
| ほかの scheme（`mailto:`・`ms-msdt:` など）・ほかのホストの `file://` | 開かない | 4 |

終了コードの意味は xdg-utils の `xdg-open` と同じ（ほかに 1 は引数の誤り、3 は `rundll32.exe` が無いとき）。

Windows へは `rundll32.exe url.dll,FileProtocolHandler` で渡す。シェルを通らないので、URL の `&` で切れず、`%` も展開されない。
渡した先の ShellExecute は `xdg-open` より広く、実行ファイルをそのまま起動し、`ms-msdt:` のような scheme を別のアプリへ渡す。
サーバーから受け取った URL を開く CLI からも呼ばれるので、上の表の「開かない」ものは渡さない。

### 反映

`~/dotfiles/setup --self-update --update` で入る（本体の checkout を最新にしてから switch する。[前述](#本体を最新にする---self-update)）。
herdr は Ctrl+クリックのたびに PATH から `xdg-open` を引くので、起こし直さなくてよい（herdr を起こしたシェルの PATH に
`~/.nix-profile/bin` があること）。

### 確かめる

```sh
command -v xdg-open                 # ~/.nix-profile/bin/xdg-open
xdg-open 'https://example.com/?a=1&b=2'   # 既定のブラウザのタブが開く (アドレス欄の & の後ろが残る)
grep 'failed to open pane URL' ~/.config/herdr/herdr-client.log | tail -n 3   # herdr が xdg-open を起動できなかった記録
```

### 気を付けること

- 開けたかどうかは `rundll32.exe` の終了コードでは分からない。0 で終わっても開いたとは限らない
- interop が外れていると（`Exec format error`）`rundll32.exe` を起こせず、4 で終わる
- herdr は起動した `xdg-open` の stdout・stderr を捨て、終了コードも記録しない（log に残るのは起動できなかったときだけ）。
  Ctrl+クリックで開かないときは、シェルで `xdg-open <URL>` を打つと理由が出る
- `url.dll` の入口には ANSI 版しかないので、ファイルの名前に Windows の ANSI のコードページに無い文字があると開けない
  （コードページが 65001 の PC では当たらない）。URL は `%XX` にしてから渡すので当たらない
- apt の `xdg-utils` を入れても、`~/.nix-profile/bin` が `/usr/bin` より先なのでこちらが当たる。Linux のアプリで開きたいなら
  `/usr/bin/xdg-open` を直に打つ

## WSL の op を理由つきで呼ぶ (1Password CLI)

WSL で 1Password を使うマシン（`wsl.enable` と `onePassword.enable` が両方 true。[ssh の wrapper](#wsl-では-ssh-自体を-windows-側に差し替える)
と同じ）の PATH に、呼ぶ理由を必須にした `op`（`nix/pkgs/pjp-op/`）と、その記録を見る `pjp-op-log` を置く
（[設計](https://github.com/pollenjp/dotfiles-private/blob/main/docs/superpowers/specs/2026-11-07-op-wrapper-reason-design.md)・[ADR 044](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/044_op_reason_wrapper_20261108T010145JST/README.md)）。option は無い。

```sh
op --reason "<なぜ op を呼ぶか>" <op の引数…>
op --reason "infra-v2 の VM を作るのに Proxmox の API の token を読む" read "op://Private/proxmox/token"
```

WSL から `op.exe` を直に打つと、1Password の承認は `op.exe` の直の親に付く。WSL のどの pane から打っても親は同じ `wsl.exe`
（herdr の server の `WSL_INTEROP`）なので、1 回の許可が後の呼び出しにも、ほかの pane（Claude の作業も）にも効き、承認の画面が
出なくなる。承認の画面はどの呼び出しでも「Allow wslhost」としか出ず、誰が何のために呼んだかも分からない。`op` はこれを次のように閉じる。

| すること | 中身 |
| --- | --- |
| 理由を必須にする | `--reason "<理由>"`（`--reason=<理由>` も。op の引数のどこに置いてもよく、`--` より後ろは op の引数）。人が打つときも要り、無ければ 2 で断る。理由なしで通すのは `--version` と help（`--help`・`-h`・`help`）だけ。引数なしの `op` は wrapper の使い方を出す（[後述](#使い方を見るfish-の補完)） |
| 呼び出しごとの powershell | 呼び出しのたびに新しい `powershell.exe`（Windows PowerShell 5.1）を起こし、その子として `op.exe` を起こす。承認はこの powershell に付き、終わると同じ powershell の中で閉じる（`op whoami` で確かめ、承認があれば `op signout --all`） |
| 窓 | 承認の画面と同時に、画面の右上に「時刻・呼び手（Claude Code か人・herdr の workspace と pane）・場所（repo・branch・cwd）・理由・コマンド」の窓を出す。最前面だが focus は奪わず、許可は求めない（決めるのは 1Password の画面だけ）。op が終われば閉じる |
| 通知 | 窓と同じ中身を Windows の通知にも出す（補助。出せなければ黙って飛ばす） |
| 記録 | `~/.local/state/pjp-op/log.jsonl` に 1 回 2 行（start・end）。op の出力と token は書かず、`--session`・`--secret-key` の値と `name=value` の値は `***` に伏せる。1 MiB を超えたら `log.1.jsonl` へ回す |
| 1 つずつ | 呼び出しを flock で 1 つずつにし、窓と承認の画面を 1 対 1 にする。前の呼び出しの承認待ちが 90 秒で終わらなければ、待っている側は 75 で断る（待たせている呼び出しの呼び手と理由を出す。90 秒は Claude の Bash の既定の時間切れ 120 秒より短くしてある）。op どうしのパイプで後ろの op が先に lock を取ったときだけ、前の op は待たずに打つ（下の stdin の段落） |
| 共有の承認の見張り | 始まりと終わりに WSL から直の `op.exe whoami` を打ち、通れば（どの pane からも使える承認が残っている）`op.exe signout --all` で消し、記録と通知（Windows・herdr）で知らせる。`whoami` は承認を求めないので、1Password がロック中でも画面は出ない |

op の stdout（`op document get` の binary も）・stderr・終了コードは変えない。引数は空白・引用符・`&`・`%`・`^`・日本語を含んでも
そのまま届く（launcher が Windows の規則で command line を組む）。引数は環境変数に載せて渡すので、合わせて base64 で 28000 字を
超えると 2 で断る（長い値は `--template` やファイルで渡す）。

stdin はそのまま `op.exe` に渡す。ただし op の出力を別の op に渡すパイプ（`op --reason … item list --format json | op --reason …
item get -`。間に `jq` などを挟んでもよい）では、後ろの op が lock を持ったまま前の op の出力を待ち、前の op が lock を待って止まる
ことがある（前の op が先に lock を取っても、出力がパイプのバッファの 64 KiB を超えると、lock を待つ後ろの op が読まないので前の op が
書けずに止まる）。どちらが先に起き、先に lock を取っても止まらないよう、次のようにする。

| 場合 | すること |
| --- | --- |
| 前の op が先に lock を取る | 後ろの op は lock を取る前（と、lock を待つ間）に stdin のパイプを遡って前の op を見つけ、stdin を読み切ってから渡す（前の op が終わるまで待つ） |
| 後ろの op が先に lock を取る（前の op が遅れて起きた） | 前の op は lock を待つ間に、lock を持つ op が自分の出力を読んでいると見て、lock を待たずに打つ。2 つの `op.exe` が同時に動き、窓も 2 つ出る。前の op の窓には、そのわけと後ろの op の理由を「注意」の行に出し、`pjp-op-log` の結果に「(lock を待たず)」を添える。共有の承認の見張りは lock を持つ後ろの op に任せる |

前に op の無いパイプ（`cat file | op …`・`ssh … | op …`。ssh のように閉じないものもある）と socket（Claude の Bash の stdin）は
読み切らず、待ち時間も増えない。パイプを遡って書き手を見るのは lock の前に 1 回と、lock を待つ間の 1 秒ごとで、1 回はプロセスが
130 ほどの WSL で 2 ms だった。

### service account・Connect の token

呼び手の環境に `OP_SERVICE_ACCOUNT_TOKEN`（か `OP_CONNECT_HOST` と `OP_CONNECT_TOKEN` の両方）があれば、デスクトップアプリの承認を
使わない呼び出しとして扱う。token はその 1 回の Windows のプロセスにだけ渡し（`WSLENV` の `/w`）、`OP_BIOMETRIC_UNLOCK_ENABLED=false`
を付けて、token が効かなくてもデスクトップアプリに落ちないようにする。承認の画面が出ないので、窓・通知・承認の閉じ方は省く。
理由は必須のまま、記録には service account（Connect）で動いたことを残す。

### 記録を見る (`pjp-op-log`)

```sh
pjp-op-log               # 直近 1 時間
pjp-op-log --since 1d    # 期間を広げる (s・m・h・d)
pjp-op-log --all         # 残っている記録を全部
pjp-op-log --json        # 1 呼び出し 1 行の JSON (理由とコマンドを切らない)
```

列は 時刻・結果（許可・拒否・時間切れ・失敗・成功・中断）・秒・呼び手・理由・コマンド。終わっていない（止められた）呼び出しは
「実行中か中断」、断った呼び出しと共有の承認を消したことも行に出る。

### 使い方を見る・fish の補完

引数なしの `op`（`--reason` だけのときも）は、wrapper の使い方（理由の書き方・理由なしで通るもの・`pjp-op-log`・op 本体の help
の出し方）を stdout に出して 0 で終わる。`powershell.exe` も `op.exe` も起こさず、記録にも書かない。op 本体の使い方は今までどおり
`op --help`（コマンドごとは `op <コマンド> --help`）で、呼び出しごとの powershell を通って `op.exe` が出す。

fish には、op を呼ばない op の補完を `~/.config/fish/completions/op.fish` に置く（`nix/pkgs/pjp-op/op-completion.fish` を
`programs.fish.completions` で）。fish に同梱の op の補完は `op completion fish | source` の 1 行で、補完を初めて使うとき（Tab・
自動補完の候補）に `op completion fish` を打つ。wrapper は理由が無いので断り、使い方と断りの文が端末に出ていた（fish を起こす
たびに 1 回。記録にも refused が残る）。fish は `~/.config/fish/completions` を同梱の補完より先に探すので、置いた方が読まれる。

| 出すもの | 中身 |
| --- | --- |
| `--reason` | まだ書いていなければ出す（`op <Tab>` でもコマンドと並べて出す）。理由の値には何も出さない |
| コマンド | トップのコマンドと 2 段目（`op item <Tab>` → `get`・`list`…）。`--reason`・`--account` などの値をコマンドと読まない |
| flag | global の flag と、よく使うコマンド（read・inject・run・signin・signout・item・document）の flag（短い形の `-o`・`-i`・`-f`・`-n` も）。ファイルを取る flag（`--out-file`・`-o` など）と `op document create` の引数ではファイルを出す |
| `--` の後ろ | `op run -- <コマンド>` の子のコマンドは、そのコマンドの補完に任せる |

item・vault の名前のように op に聞かないと分からないものは出さない（op を呼ぶと、補完のたびに powershell と `op.exe` が起き、
承認の画面も出うる）。一覧は op 2.41.0 から写してある。op を上げてコマンドが変わったら、ファイルの先頭のコメントの手順で
写し直す。wrapper の無いマシンの fish は、同梱の補完（本物の op を呼ぶ）のまま。`fish --no-config` は置き場を読まないので、
同梱の補完が動く。

### 守る決まり

- **窓が出ていない 1Password CLI の承認の画面は拒否する。** 窓の無い画面は `op` を通らずに `op.exe` を直に打ったもの（道具の中
  など）で、許可すると WSL のどの pane からも使える承認ができる。窓に「ほかにも op.exe が動いています」と出たときも、どれの承認か
  分からなければ拒否する。op どうしのパイプで前の op が lock を待たずに打ったとき（その窓の「注意」に出る）は、窓が 2 つ出て承認の
  画面も 2 つ出うる。画面が窓より多ければ拒否する
- **うっかり許可したら、WSL で `op.exe signout --all` を打つ**（`op` を通さずに直に。WSL 全体の承認が消える）。次に `op` を
  打ったときの見張りも消す
- **`op` を止めた後（Claude の Bash の時間切れ・Ctrl+C）に窓の無い承認の画面が残ったら、拒否する。** 止めると Windows 側の
  powershell も終わり、窓が消える（下の「気を付けること」）。許可してしまったら、1Password をロックして消す

### 反映

`~/dotfiles/setup --self-update --update` で入る。Claude の hook（[後述](#opexe-の直打ちを止め承認の拒否のあとは問いを出させるフック)）
の登録も同じコマンドが行う（Claude Code を起こし直すと効く）。fish の補完は新しく起こした fish から効く（同梱の補完をもう読んだ
fish は、起こし直すまでそのまま）。

### 確かめる

```sh
command -v op                              # ~/.nix-profile/bin/op
op                                         # wrapper の使い方 (powershell も op.exe も起こさない)
fish -c 'complete -C "op "'                # fish の op の補完の候補。op を呼ばず、断りの文も出ない
op --version                               # 理由なしで通る (承認の画面は出ない)
op --reason "動くかを確かめる" vault list  # 窓と承認の画面が出る。60 秒以内に許可すると vault の一覧が出る
pjp-op-log                                 # 上の呼び出しが「許可」で残る
op.exe whoami                              # WSL の直の op.exe は account is not signed in のまま (承認が漏れていない)
```

確かめに `op --reason … whoami` は使えない。`whoami` は承認を求めず、呼び出しごとの powershell には承認が無いので、窓だけが
出て `account is not signed in` で終わる。

### 気を付けること

- 1Password の承認の画面は、出てから約 60 秒で時間切れになる。op は `[ERROR] <日時> authorization timeout` を出して 1 で終わり、
  記録は「時間切れ」になる。拒否すると `[ERROR] <日時> authorization prompt dismissed, please try again` で「拒否」になる
  （wrapper はこの 2 つの文言で見分ける。op 2.41.1 で確かめた）。1Password がロック中なら、同じ画面から Windows Hello で解く
- Claude Code の Bash の時間切れや端末の Ctrl+C で `op` を止めると、`powershell.exe` の relay も止まり、Windows 側の powershell
  （launcher）も終わる。op が承認を待っていれば、窓は消えて 1Password の承認の画面だけが残る（窓の無い画面なので拒否する）。
  許可してしまうと、その承認は終わった powershell に付いたまま閉じられず（WSL の `op.exe signout --all` では消えない）、1Password の
  10 分の期限まで残るので、1Password をロックして消す。lock も離れるので、次の `op` の窓に「ほかにも op.exe が動いています」と出る。
  止められる機会を減らすため、Claude の hook は op を打つ Bash の timeout を長く（600000）するよう促す。止められた呼び出しは
  `pjp-op-log` に「中断」か「断った (始める前に止められた)」で残る
- 道具の中で `op.exe` を直に打つものは止めない（Claude の hook はコマンドの文字だけを見る）。上の「窓が出ていない承認は拒否」と
  見張りで守る。Windows 側から service account の token で `op.exe` を起こす道具は承認の画面を出さないので、関わらない
- 承認の画面の名前は、挟む powershell にしても「wslhost」と出る（1Password が決める）。誰が呼んだかは窓と記録で見る
- 見張りの `op.exe whoami` は 1 回およそ 1 秒かかる（1 回の呼び出しで 2 回）

## シークレットを .env の参照から渡す (pjp-op-env)

1Password を使うマシン（`onePassword.enable`。WSL もそれ以外も）の PATH に、`.env` の `op://` の参照を 1 回の op で解き、値を
環境変数に入れて program を起こす `pjp-op-env`（`nix/pkgs/pjp-op-env/`）を置く（[設計](https://github.com/pollenjp/dotfiles-private/blob/main/docs/superpowers/specs/2026-11-10-secrets-op-env-design.md)）。
名前の参照を ID の参照に直す `pjp-op-ref`（`nix/pkgs/pjp-op-ref/`。[後述](#参照を-id-の形に直す-pjp-op-ref)）も並べて置く。
値は 1Password にだけ置き、`.env` には参照だけを書く。Claude にこの扱いを決めるのは skill `pjp-secrets` と、ユーザーの CLAUDE.md の
「シークレット」の節（値を会話に貼らせない・ファイルに平文で書かない・値を表示するコマンドを打たない）。

```sh
pjp-op-env --reason "<なぜ値を読むか>" -- <program> [<引数>…]                    # 今の dir の .env を読む
pjp-op-env --reason "kabu の bot を起こすのに API パスワードを読む" -- ./target/release/kabu-bot
pjp-op-env --reason "<理由>" --env-file .env --env-file .env.local -- <program>   # 後のファイルが勝つ
pjp-op-env --dry-run                                                              # op を呼ばず、名前と種類 (参照か値か) を出す
```

`.env` には値の代わりに参照を書く。参照は 1Password のアプリの欄のメニュー「Copy Secret Reference」で取れる。アプリが出すのは
名前の参照で、名前を変えると切れるので、`pjp-op-ref` で ID の参照に直してから書く（[後述](#参照を-id-の形に直す-pjp-op-ref)）。
どちらの参照も同じく解ける。

```sh
KABU_API_PASSWORD=op://vaultid0000000000000000001/itemid00000000000000000001/fieldid0000000000000000004  # ID の参照 (ID は作り物)
KABU_API_KEY="op://Private/kabu station/api key"   # 名前の参照。名前に空白があれば引用符で囲む
LOG_LEVEL=info                                      # 参照でない値はそのまま渡す
```

| 段 | すること |
| --- | --- |
| 1. `.env` を読む | 1 行ずつ文字列として読む（`source`・`eval` をしない）。読めない行があれば、ファイル名と行番号だけを出して 2 で止める |
| 2. program を引く | 実行ファイルを PATH から引く（`.env` を入れる前に引くので、`.env` の `PATH` で替わらない）。無ければ op を呼ばずに 127 |
| 3. 参照を解く | 値の全体が `op://` で始まるものを集め、`op [--reason "[pjp-op-env: <program> に参照 <N> 件] <理由> (読む参照: <参照>, …)"] inject` を 1 回だけ呼ぶ。参照は stdin のテンプレート（参照ごとに乱数の境界の印の行と `{{ <参照> }}` の行）で渡し、解いた値は stdout のパイプで受けてメモリにだけ置く。`--reason` は WSL の op（pjp-op。`~/.local/state/dotfiles/claude-op-reason.json` の `enable` が true）にだけ付ける |
| 4. 起こす | op が終わってから（WSL の op の lock と承認の窓を放してから）、op の認証の環境変数を外し、値を環境変数に入れて `exec` で program に置き換わる。program は Linux のプロセスとして、同じ pid・stdin・stdout・stderr で動く |

WSL では `op run --env-file=.env -- <program>` を使わない。op は Windows の `op.exe` なので子のコマンドも Windows のプロセスとして
起きる見込みで、WSL の op（[前述](#wsl-の-op-を理由つきで呼ぶ-1password-cli)）は op が終わるまで lock と承認の窓を持つ。長く動く
program を `op run` で起こすと窓が出たままになり、ほかの pane の op は 90 秒待って 75 で断られる。値ごとの `op read` は承認が
値の数だけ出る。

### `.env` の書き方

| 書き方 | 読み方 |
| --- | --- |
| `KEY=値`・`export KEY=値` | 名前は `[A-Za-z_][A-Za-z0-9_]*`。`=` の前に空白を置かない。行頭の空白はよい |
| 空行・`#` で始まる行 | 飛ばす |
| `KEY=値 # コメント` | 引用符なしの値は、空白に続く `#` から後ろを外し、前後の空白を外す（`a#b` の `#` は値） |
| `KEY='値'` | 中をそのまま（エスケープなし） |
| `KEY="値"` | `\\` と `\"` だけを戻し、ほかはそのまま。`$`・`` ` `` は展開しない |
| `KEY=op://vault/項目/欄` | 値の全体が `op://` で始まれば参照（値の途中の `op://` は解かない）。`{`・`}`・制御文字を含む参照は読めない行 |
| 行末の `\r`・頭の UTF-8 の BOM | 外す（Windows のエディタで書いたファイル） |

- 変数の展開・コマンドの置き換え・複数行の値は無い。ファイルはデータとして読む
- 同じ名前は後の行・後のファイルが勝つ。呼び手の環境に同じ名前があっても `.env` が勝つ
- bash が特別に扱う名前は読めない行にして、op を呼ぶ前に止める。整数の属性の名前（`OPTIND`・`RANDOM`・`SRANDOM`・`HISTCMD`・`LINENO`・
  `SECONDS`）は代入で値が算術式として評価され（`$(…)` まで走る）、`_`・`EPOCHSECONDS` などは値が替わり、配列（`GROUPS`・`FUNCNAME`
  など）と読み取り専用の名前（`EUID`・`PPID`・`UID`・`SHELLOPTS` など）は書いた値のまま渡せない。`BASH` で始まる名前・`IFS`・`TMOUT`・
  `GLOBIGNORE`・`POSIXLY_CORRECT` と、`pjp-op-env` が中で使う `_poe_` で始まる名前も同じ

### なぜ安全か

まとめて解いても、値が通る道は「op（`op.exe`）→ パイプ → `pjp-op-env` のメモリ → program の環境変数」の 1 本だけで、ディスク・
引数・端末・記録には出ない。どれも `nix/tests/pjp-op-env.test.sh` が偽の op・vault（WSL の分は本物の `op.sh` も）で確かめる。

| 値が出うる所 | どう防いだか |
| --- | --- |
| ディスク | 一時ファイルを使わない。テンプレート（参照だけ）は stdin のパイプで渡し、値は stdout のパイプで受ける。WSL の op は stdin の写しを作らず（前段が op の wrapper のときだけ作る）、stderr の写し（値は出ない）は tmpfs に置いて終わりに消す |
| 引数（`/proc/<pid>/cmdline`・`ps`） | 値を引数に載せない。op に渡すのは理由と `inject` だけ。環境変数は bash の組み込みの `export` で入れ、外のコマンドを起こさずに `exec` で program に置き換わる（テストは strace ですべての `execve` の引数を見る） |
| `.env` の評価 | `source`・`eval` をしない。値の `$(…)`・`` ` ``・`;`・引用符・空白は文字のまま渡す。代入で値を評価する bash の特別な名前（`OPTIND` など）は読めない行にする。入れた変数の数をループの後で数え、足りなければ program を起こさない |
| 解けない参照・出力の取り違え | fail closed。op が 0 以外で終われば program を起こさない（参照が 1 つでも解けなければ op は 0 以外）。出力は起動ごとの乱数（128 bit）の境界の印で区切り、印の数・順・前後が合わない・NUL がある（環境変数にできない）なら 70 で止める |
| 端末・記録 | 値を表示しない。誤りの文はファイル名・行番号・名前・件数・終了コードだけ。`pjp-op-env` は記録を書かない。WSL の op の記録（`pjp-op-log`）に入るのは理由と `inject` だけ |
| xtrace | 最初の行で `set +x +a +m`（呼び手の `SHELLOPTS`・`BASH_ENV` が xtrace や job control を付けていても外す。job control が付いていると op の出力を受け損なう） |
| op の認証 | `OP_SERVICE_ACCOUNT_TOKEN`・`OP_CONNECT_HOST`・`OP_CONNECT_TOKEN`・`OP_SESSION_*` は op に渡し、program を起こす前に外す |
| 承認の画面 | op を呼ぶのは何件でも 1 回。WSL の op の窓の理由には、頭に program と参照の件数、後ろに読む参照が並ぶ（`inject` は参照を stdin で受けるので、足さないと窓のコマンドが `op inject` だけになる）。窓は理由を 200 字で切るので、件数より並んだ参照が少なければ切れている（全部は記録に入る。`pjp-op-log --json`） |
| lock と窓 | op の出力を読み切り、op が終わってから program を起こす。program が動いている間、ほかの pane の op は待たされない |

守らないもの（op を素で使うとき・`op run` と同じで、`pjp-op-env` で増えも減りもしない）:

- 環境変数は、同じユーザーのプロセスと root から読める（`/proc/<pid>/environ`）
- 値は program の子にも受け継がれる。起こすのはなるべく実行ファイルそのものにする（`cargo run`・`npm run` は build の script や
  依存のコードにも値を渡すので、build してから `pjp-op-env … -- ./target/release/<名前>` で起こす）
- program が値をどう扱うか（ログに出す・外へ送る）

### 終了コード

| コード | いつ |
| --- | --- |
| program の終了コード | 起こした後（`exec` で置き換わる） |
| 0 | `--dry-run`・`--help` |
| 2 | 引数の誤り（理由が無い・空、program が無い、知らない option）、`.env` が無い・読めない行がある |
| 70 | op は 0 で終わったが、出力の形が合わない（NUL・境界の印のずれ）か、環境変数を入れきれない。program は起こさない |
| 127 | 起こす program か op が見つからない（op は参照があるときだけ見る） |
| 126・127 | 承認の後に `exec` に失敗した（実行の権限が無いなど。bash が出す） |
| op の終了コード | op が 0 以外で終わった（1 = 拒否・時間切れ・解けない参照など、75 = ほかの op の承認待ちが終わらない、130 = 止められた）。program は起こさない |

### 参照を ID の形に直す (pjp-op-ref)

参照は vault・項目・セクション・欄のどれも、名前の代わりに ID で書ける（[参照の書き方](https://www.1password.dev/cli/secret-reference-syntax/)）。
名前は 1Password のアプリで変えられ、変えると名前の参照は切れる。項目の ID が変わるのは、項目を別の vault に移したときだけ。
ID は英小文字と数字なので、名前に空白や記号があっても `.env` で引用符で囲まずに済む。`pjp-op-ref` は参照を ID の参照に直して、
渡した順に 1 行ずつ stdout に出す。値は出さない。

```sh
pjp-op-ref --reason "<なぜ読むか>" <参照>…
pjp-op-ref --reason "bot の .env に書く参照を ID の形にする" "op://Dev/Example Service/prod/API_TOKEN" "op://Dev/Example Service/stg/API_TOKEN"
```

出力の例（ID は作り物。最後の 1 行は stderr）:

```text
op://vaultid0000000000000000001/itemid00000000000000000001/sectionid00000000000000001/fieldid0000000000000000001
op://vaultid0000000000000000001/itemid00000000000000000001/sectionid00000000000000002/fieldid0000000000000000002
pjp-op-ref: 参照 2 件を ID の形に直しました (op を 1 回呼びました)。
```

| 段 | すること |
| --- | --- |
| 1. 参照を分ける | `op://<vault>/<項目>/[<セクション>/]<欄>[?<attribute など>]` に分ける。`op://` で始まらない・部分が 3 つか 4 つでない・空の部分・制御文字・`-` で始まる vault か項目（op が option と読む）なら、op を呼ばずに 2 |
| 2. 項目ごとに op を 1 回 | vault と項目の部分の組（大文字小文字は問わない）ごとにまとめ、初めて出た順に `op [--reason "[pjp-op-ref: 参照 <N> 件を ID の形に直す (項目 <k>/<M>)。ID だけを抜き出し、値は捨てる] <理由>"] item get <項目> --vault <vault> --format json` を呼ぶ（`(項目 …)` は項目が 2 つ以上のときだけ）。`--reason` は WSL の op（pjp-op）にだけ付ける。同じ項目の参照は何件でも 1 回 |
| 3. ID を抜き出す | op の出力は jq にだけ流し、vault と項目の ID と、セクションと欄を ID か名前（大文字小文字は問わない）で当てた結果だけを受ける |
| 4. 出す | どの参照も直せたら、渡した順に 1 行ずつ出す。1 つでも直せなければ何も出さずに止まり、残りの項目は読まない |

- もう ID の部分は、その ID のまま。`?attribute=…`（`?attr=…`・`?ssh-format=…`）は後ろにそのまま付ける
- セクションの無い欄は `op://<vault>/<項目>/<欄>`。参照にセクションが無くても、欄にセクションがあればセクションの ID を入れる
- セクションか欄が見つからない・同じ名前で 2 つ以上あるときは、参照と件数を出して 1 で止まる（2 つ以上なら、セクションを足すか
  ID で書く）
- 作りつけのセクションの ID には空白のあるもの（`add more` など）がある。出した参照に空白があれば stderr で知らせるので、`.env` では
  `"…"` で囲む
- 項目が 2 つ以上なら op もその数だけ呼ぶ（WSL では承認の画面もその数だけ出る）。同じ項目でも書き方（名前か ID か）が違えば
  別に読む
- 項目を別の vault に移すと項目の ID が変わるので、移したら直し直す
- `.env` を読んで書き換えはしない。既にある `.env` の名前の参照は、`pjp-op-env --dry-run` で参照を見て、`pjp-op-ref` で直し、行を
  入れ替える（skill `pjp-secrets` の手順）

`op item get --format json` の出力は、隠す欄（CONCEALED）の値も含みうる。`pjp-op-ref` はその出力を op から jq へのパイプだけに通し、
shell の変数・ファイル・端末・引数に入れない。jq が出すのは ID と件数だけで、jq の stderr は捨てる（jq の型の誤りの文は、入力の値を
入れて出すことがある）。誤りの文に書くのは参照（名前）・件数・終了コードだけ。どれも `nix/tests/pjp-op-ref.test.sh` が偽の op と
偽の項目（WSL の分は本物の `op.sh` も）で確かめる。

| コード | いつ |
| --- | --- |
| 0 | 直せた・`--help` |
| 1 | セクションか欄が見つからない・同じ名前で 2 つ以上ある |
| 2 | 引数の誤り（理由が無い・空、参照が無い、知らない option、参照の形） |
| 70 | op は 0 で終わったが、出力の形が合わない（JSON でない・項目が 1 つでない・ID が無い） |
| 127 | op か jq が見つからない |
| op の終了コード | op が 0 以外で終わった（1 = 拒否・時間切れ・項目が無いなど、75 = ほかの op の承認待ちが終わらない）。残りの項目は読まない |

### 反映

`~/dotfiles/setup --self-update --update` で入る（`pjp-op-ref` も）。skill `pjp-secrets` と CLAUDE.md の節も同じコマンドで配られる
（Claude Code を起こし直すと効く）。

### 確かめる

```sh
command -v pjp-op-env pjp-op-ref                         # ~/.nix-profile/bin/pjp-op-env・pjp-op-ref
pjp-op-env --dry-run                                     # .env の名前と種類。参照でない値は出さず、op を呼ばない
pjp-op-env --reason "参照が解けるかを確かめる" -- true   # 承認の画面が 1 回だけ出て、全部解ければ 0
pjp-op-log                                               # WSL: inject の 1 行。理由の後ろに読む参照が並ぶ
pjp-op-ref --reason "参照を ID の形にする" "<参照>"      # 承認の画面が項目ごとに 1 回出て、ID の参照を出す
```

### 気を付けること

- program が自分で `.env` を読む作り（dotenvy・python-dotenv など）でも、既にある環境変数を上書きしない既定なら `pjp-op-env` が
  入れた値が勝つ。上書きする設定（`override=True` など）にしていると、参照の文字列に戻る
- 知らない repo の `.env` を `pjp-op-env` で読まない。読む参照は WSL の承認の窓に並ぶので、頼んだ覚えの無い項目があれば拒否する。
  参照でない値も環境変数として program に渡るので、`LD_PRELOAD`・`NODE_OPTIONS` のような名前で program に別のコードを読ませられる
  （env-file を読むほかの道具と同じ）
- 承認を待つ間に Claude の Bash の時間切れで止められないよう、Claude に起こさせるときは timeout を長く（600000）し、常駐する program は
  裏で起こす（skill `pjp-secrets`）
- service account の token（`OP_SERVICE_ACCOUNT_TOKEN`）が環境にあれば、op はそれで解く（WSL の op は承認の画面を出さない）。cron の
  ような人が承認できない処理は、専用の vault だけを読める service account で動かす（skill `pjp-secrets`）

## fish

`.fish/*.fish` (17 ファイル / 610 行) は `nix/home/modules/fish.nix` へ**全面移植**した。
レガシー側の数字プレフィックスによる読み込み順制御はやめ、役割別に整理してある。
順序が本質的に効くもの (PATH の前置、mise activate、starship init) だけを
`interactiveShellInit` の並び順で表現している。

内訳: abbr / function / `interactiveShellInit`。

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
内訳: alias / 関数 / `initExtra`。

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

## direnv

ディレクトリに入ると、そこの `.envrc` が書く環境をシェルに読み込み、出ると戻す（`nix/home/modules/direnv.nix` の
`programs.direnv`）。hook は fish の `interactiveShellInit` と bash の `initExtra` の、mise の hook より後ろに入る。
`.envrc` の `use flake` は nix-direnv が受け持つ。

```sh
# 1 つの flake に devShell を並べ、ディレクトリごとに選ぶ例
# (repo の直下の flake.nix が devShells.<system>.ch01 を持つとき)
echo 'use flake ../..#ch01' > chapters/ch01/.envrc
echo 'dotenv_if_exists' >> chapters/ch01/.envrc   # 秘密の値は隣の .env に置いて読む (無ければ何もしない)
cd chapters/ch01   # direnv: error … .envrc is blocked. Run `direnv allow` to approve its content
direnv allow       # 中身を確かめてから許す。.envrc を書き換えると、また止められる
```

- 評価した devShell は `.envrc` のディレクトリの `.direnv/` に cache し、`flake.nix`・`flake.lock`（と `devshell.toml`）が
  変わるまで評価し直さない。flake.nix から読む別のファイルを変えたときは `direnv reload` を打つか、`.envrc` に
  `watch_file <ファイル>` を足す
- devShell と flake の inputs には `.direnv/` から GC root が張られ、週 1 回の GC（[前述](#使わなくなったデータの定期削除)）でも
  消えない。要らなくなったら `.direnv/` を消せば root も外れる
- 読み込むたびの `direnv: export +AR +AS … ~PATH`（devShell では数十個の変数が 1 行に並ぶ）は出さない（`direnv.toml` の
  `hide_env_diff`）。`direnv: loading …` と、止められたときのエラーは出る。初めての評価・ビルドが 5 秒を超えると
  `… is taking a while to execute. Use CTRL-C to give up.` が出る（`warn_timeout` は既定のまま）
- mise の hook と並べて動く。devShell が mise の global のツールと同じコマンド（`node` など）を持つときは、
  そのディレクトリの中では devShell の方が先に引かれ、出ると mise の方に戻る
- `.envrc` は global gitignore で無視しないので、repo に置いて共有できる（その repo の `.gitignore` に `!.envrc` は要らない）。
  秘密の値は `.envrc` に書かず、global gitignore が無視する `.env` に置いて、`.envrc` から `dotenv_if_exists` で読む
  （`.env` が無ければ何もしない。書き換えると読み直す）。commit しない手元だけの `.envrc` は、その repo の
  `.git/info/exclude` に書く
- `.direnv/` は global gitignore に入る

## 証明書の束を OS の信頼ストアに寄せる

自前の証明書の束を持つツール（nixpkgs の python の certifi・uv・venv の requests・gcloud）にも OS の信頼ストア
（`/etc/ssl/certs/ca-certificates.crt`）を読ませるため、Linux のホストでは `NIX_SSL_CERT_FILE`・`SSL_CERT_FILE`・
`REQUESTS_CA_BUNDLE`・`CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE` を session の環境変数に入れる
（`nix/home/modules/os-ca-bundle.nix`。どのツールがどれを読むかは、その先頭のコメント。
[ADR 028](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/028_os_ca_bundle_env_20261022T180804JST/README.md)）。OS の束から危ない CA を外せば、
これらのツールも揃って拒否するようになる。

- 入れるのは、Linux で束のファイルがあるときだけ（無いホストで入れると、nix 自身も含めて TLS が通らなくなる）
- すでに束を指している変数があれば、残りをそれに揃える（`SSL_CERT_FILE`、無ければ `NIX_SSL_CERT_FILE` の値。
  どちらも無ければ OS の束）。値がある変数は書き換えない。空の変数は値が無いものとして扱う
- bash は login の shell（`~/.profile`）で、fish はすべての fish（`config.fish`）で入る。login でない bash は、
  開いた親（fish など）から継ぐ
- このマシンだけ別の束に向けたいときは、ホストの module で `home.sessionVariables.SSL_CERT_FILE` を書く
  （dotfiles-private の `nix/hosts/` のファイルか `~/dotfiles/flake.nix` の tmp の `modules`）。残りの 3 つもそれに揃う。
  コマンド 1 回だけなら、4 つとも同じ値で打つ（nixpkgs の OpenSSL は `NIX_SSL_CERT_FILE` を `SSL_CERT_FILE` より
  先に読むので、`SSL_CERT_FILE` だけを変えても python の標準の https・git などには届かない）

### 入れる変数を選ぶ

ホストの module（dotfiles-private の `nix/hosts/` のファイルか `~/dotfiles/flake.nix` の tmp の `modules`）で、
`dotfiles.osCaBundle`（`nix/home/options.nix`）に書いて選ぶ。

| 書くもの | 入る変数 |
| --- | --- |
| （書かない） | 4 つとも（既定） |
| `dotfiles.osCaBundle.requestsCaBundle.enable = false;` | `REQUESTS_CA_BUNDLE` 以外の 3 つ |
| `dotfiles.osCaBundle.enable = false;` | 入れない（`requestsCaBundle.enable` は意味を持たない） |

```nix
modules = [
  { dotfiles.osCaBundle.requestsCaBundle.enable = false; }
];
```

### 効かないところ・副作用

- shell を通らずに起動するもの（systemd の user service・デスクトップのランチャーから直に開くアプリ）には入らない
- **cacert を含む devShell（nixpkgs の python の devShell など）の中では、`NIX_SSL_CERT_FILE` が nixpkgs の cacert の
  束に戻る。** cacert の setup hook が立て、`nix develop` は derivation の値を残す（呼び出し元の値を残すのは
  `SSL_CERT_FILE` だけ）。その中の nixpkgs の certifi と OpenSSL（python の標準の https など）は OS の束を読まない。
  直すなら、その repo の devShell の `shellHook` で向け直す

  ```sh
  [ -f /etc/ssl/certs/ca-certificates.crt ] && export NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
  ```

- **`REQUESTS_CA_BUNDLE` は、アプリが requests の `Session` に置いた `verify`（私設 CA の束・`False`）より先に効く。**
  1 回ごとに `verify=` を渡す呼び方は変わらない。`Session` の `verify` で自己署名の機器などに繋ぐ script は検証に
  失敗するようになるので、`REQUESTS_CA_BUNDLE= <コマンド>`（空）で打つ。requests は空を無いものとして扱い、
  `Session` の `verify` に戻る。そういう script をよく動かすホストは、`REQUESTS_CA_BUNDLE` だけを外す
  （[入れる変数を選ぶ](#入れる変数を選ぶ)）
- `CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE` は、gcloud の設定（`gcloud config set core/custom_ca_certs_file`）より先に効く。
  設定で別の束を指しているホストは、同じパスをホストの module の `home.sessionVariables` にも書く

### 反映

`~/dotfiles/setup --update` のあと、**新しい login から開いた shell** に入る。

home-manager の `hm-session-vars` は 1 つの session で 1 回しか読まない（読んだ印の `__HM_SESS_VARS_SOURCED` を
子へ継ぐ）。反映の前から続いている process の下で開いた shell は、印を継いでいるので読み直さない。

| どこで | 入れ方 |
| --- | --- |
| 端末・ssh | 開き直す（ssh を張り直す・ログインし直す） |
| herdr の pane | pane は server の env を継ぐ。server を止め、新しい login（ssh を張り直した shell・`herdr.exe --remote <ssh 先>`）から開き直す（前からある shell から起こすと、古い env を継いで入らない）。pane のプロセスは終わる（Claude Code は herdr の agent session restore で会話へ戻れる）。1 つの pane だけなら `exec env -u __HM_SESS_VARS_SOURCED fish -l` |

```sh
herdr server stop             # default
herdr session stop s2         # named session ごとに
```

> ⚠️ **OS の束が直っていないホストでは、自前の束が先に直ったツールがむしろ通すようになる。**
> 2026-10 の eMudhra の侵害では、PyPI の certifi 2026.10.19 がもう該当のルートを外していて、それを入れた venv は
> 変数が無くても拒否する。`REQUESTS_CA_BUNDLE` で直っていない OS の束に向けると通す。反映の前に、そのホストの
> OS の束が直っているかを下の `curl` で確かめる。

### 確かめる

```sh
printenv SSL_CERT_FILE   # /etc/ssl/certs/ca-certificates.crt (fish でも bash でも。herdr の pane でも見る)

# 2026-10 の eMudhra の侵害のテスト用ホスト。OS の束が直っていれば、どれも証明書のエラーになる
curl -sS -o /dev/null https://dv-g3b-emudhra.we-have-a-problem.com/
echo idna | uv pip compile - --index-url https://dv-g3b-emudhra.we-have-a-problem.com/simple --no-config
```

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

ファイルの頭には、dotfiles と skill が受け取る環境変数の一覧を「dotfiles が書く欄」として置き、
手順 6.6 が流れるたびに書き直す（[後述](#一覧の欄-adr-021)）。**書き換えるのは欄の中だけで、欄の外は
1 バイトも変えない。** 実際の API キーが入っているファイルなので、値は欄より下に書く。group と other の
権限があれば外す（644 なら 600。600 より狭くしてあれば広げない）。

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

### 一覧の欄 (ADR 021)

ファイルの頭に、dotfiles と skill が受け取る環境変数の一覧を、印で囲んだ欄として置く
（[ADR 021](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/021_local_env_header_20261017T224146JST/README.md)）。値を書くときに開くファイルで、
書ける変数とその意味が読めるようにするため。

```
# >>> dotfiles が書く欄 (setup --update のたびに書き直す。ここには書かない) >>>
#
# マシンローカルの環境変数。git にも /nix/store にも入らない。
# …(形式の決まり)
#
# ---- dotfiles ----
#
# setup が対象にするホストを決めるための変数 (--host と同じ)。取り得る値: …。
# DOTFILES_HOST=xxxxxx
# …
# ---- skill: pjp-notion-profile ----
# …
#####################################################
# <<< dotfiles が書く欄ここまで。この行より下に生の KEY=VALUE を書く (setup はここから下を書き換えない) <<<
PJP_NOTION_TOKEN_PERSONAL=ntn_…
```

- `# >>> dotfiles` で始まる行から `# <<< dotfiles` で始まる行までが setup のもの。すべて `#` で始まるので、
  ローダは欄を読まない。印として見るのは行の頭だけ（行末の CR と、1 行目の頭の UTF-8 BOM は外して見る）
- 使う変数は、欄より下へ `#` を外して書き写し、値を入れる

手順 6.6 がすること:

| ファイルの様子 | すること |
| --- | --- |
| 無い | 欄だけのファイルを作る |
| 印が 1 組 | 印の間を新しい欄に替える。印より上と下は 1 バイトも変えない |
| 印の間に `#` で始まらない行がある | その行を元の順のまま、終わりの印のすぐ下へ移し、変数名を `!!` で知らせる |
| 印が無く、頭がこの ADR の前のテンプレート (10 行) | その 10 行を欄に替える |
| 印が無く、それ以外 | 欄を頭に足す。今の行は 1 行も消さない |
| 印が壊れている・symlink・書けない・NUL を含む（UTF-16 で保存した）・`env.bak` がディレクトリ | 書かずに `!!` で知らせる（setup は止めない） |

- 書き上がりが今と同じなら何も書かない。違えば前の版を `env.bak`（600、1 世代）に写し、同じディレクトリの
  一時ファイルから `mv` する。値は画面に出さない
- 欄の中に手で書いたコメントは、次に欄が変わったときに消える（`env.bak` に 1 世代だけ残る）
- テンプレートを手で直していたファイルは、テンプレートを残したまま欄が頭に足される。要らなければ欄の下に
  残った古いテンプレートを手で消す

一覧の文言は、変数を読むコードの隣に置いた断片から集める。

| 変数を読むもの | 断片 | 欄の節 |
| --- | --- | --- |
| dotfiles の script | `nix/pjp-env/dotfiles.txt` | `# ---- dotfiles ----` |
| skill | skill のディレクトリの `pjp-env.txt`（`~/.claude/skills/*/pjp-env.txt` から、名前の順） | `# ---- skill: <名前> ----` |

- 断片の書き方は [`files/claude/skills/README.md`「環境変数を受け取るとき」](files/claude/skills/README.md#環境変数を受け取るとき-pjp-envtxt)
- 載せるのは「このファイルに書いて、そのマシンで常に効かせる意味がある」変数。1 回だけコマンドの前に付ける上書きと、
  devShell・テストが自分で張る変数は載せない。ここに書くと困る変数（`NOTION_API_TOKEN` など）は「ここには書かない」の
  行でだけ触れる
- skill の文言は skill と一緒に届く。claude-skills の断片を直して push すれば、各 PC の次の `setup --update` で欄に出る

## ntn (Notion CLI) の token をファイルに置く (keyring)

ntn は `ntn login` の token を OS の keychain に置く。keychain の無い・続かないマシン（SSH で入る Linux の VM など）では
`ntn login` が keychain のエラーで落ちるので、ntn の `config.json` に `"keyring": false` を書き、token を ntn の
config directory の `auth.json` に置かせる。どのマシンで切るかを host option `dotfiles.ntn.keyring`（`nix/home/options.nix`）で選ぶ
（[設計](https://github.com/pollenjp/dotfiles-private/blob/main/docs/superpowers/specs/2026-11-01-ntn-keyring-design.md)）。

| 値 | ntn の `config.json` |
| --- | --- |
| `null`（既定） | 触らない（`false` から `null` に戻しても、書いた `keyring` は残る。keychain に戻すなら `true`） |
| `false` | `"keyring": false` を書く（token は config directory の `auth.json`。秘密のファイルとして扱い、config directory を 700・`auth.json` を 600 にそろえる。[後述](#ntn-の-config-directory-と-authjson-の-mode)） |
| `true` | `"keyring": true` を書く（OS の keychain に戻すとき） |

使うマシンのホストの `modules`（dotfiles-private の `nix/hosts/<ホスト>.nix` か、`~/dotfiles/flake.nix` の tmp。`mkHome` の
引数ではない）に書く。

```nix
modules = [
  { dotfiles.ntn.keyring = false; }
];
```

### ntn の config.json への反映

`config.json` は ntn が自分で書き換える（`ntn login` が既定の workspace を書く）ので、Nix では置かない（store の読み取り専用の
symlink にすると、ntn が `Failed to write config.json` で落ちる）。`switch` が値を `~/.local/state/dotfiles/ntn.json` に置き
（`home/modules/ntn.nix`）、`~/dotfiles/setup --update` の `bootstrap-ntn.sh` が `config.json` の `keyring` だけを merge する。
**`switch` だけでは `config.json` に届かない。**

- `config.json` があれば `keyring` だけを書き換え（無ければ足し）、ほかのキー（既定の workspace など）は残す。同じ値なら
  書かない。書き換えるときは同じディレクトリの一時ファイルから `mv` で置き換え、元の mode を保つ
- 無ければ、ntn が空の場所に作るのと同じ形 `{"version": "1", "defaultWorkspaceIds": {}, "keyring": <値>}` で作る
  （ディレクトリも。`config.json` の mode は ntn と同じく umask どおり。ディレクトリは `false` なら 700、`true` なら
  umask どおり）。ntn は `version` の無い `config.json` を読めない
  （`{"keyring": false}` だけだと `Failed to parse config.json`）。ntn がまだ入っていなくても作る
- `null` なら何もしない
- 次のときは書き換えずに警告し、setup は止めない（[警告のまとめ](#途中の警告のまとめ)に `[bootstrap-ntn]` で出る）:
  jq が無い、状態ファイルが無い（switch の前の世代）・形が違う、`NOTION_HOME` がディレクトリでない、`config.json` が
  JSON の object として読めない・symlink（`mv` で置き換えると symlink が消えるため）、書けない、`false` で config directory に
  触ると危ない（[後述](#ntn-の-config-directory-と-authjson-の-mode)）
- `version`（文字列）の無い `config.json` は、`keyring` を書いたうえで「ntn はこの形を読めない」と警告する（`version` は足さない）

ntn は打つたびに `config.json` を読むので、動いている herdr・Claude Code・見回り役の service
（[`pjp-dev-tracker-inbox`](#チケットのコメントをハブの会話へ届ける見回り役-pjp-dev-tracker-inbox)）の下の ntn にも、次に打ったときから
効く。ntn では環境変数 `NOTION_KEYRING` が `config.json` より強いが、dotfiles は入れない（switch の前から続く process の下の
shell と、`PATH` しか受け取らない見回り役の service には届かないため）。

### ntn の config directory と auth.json の mode

`false` では token が `auth.json` に平文で入る。ntn はディレクトリもファイルも umask どおりに作る（umask 002 なら
775・664）ので、`bootstrap-ntn.sh` は `false` のときだけ、`config.json` より先にほかのユーザーが読めないようにそろえる。

- config directory は、作るなら 700 で作り、あれば 700 にそろえる。ディレクトリが 700 なら、ntn が login し直して
  `auth.json` を 664 で作り直しても、ほかのユーザーは読めない
- `auth.json` があれば 600 にそろえる（無ければ作らない）。ほかのファイル（`config.json`・`cache.json` など）の mode は
  変えない（秘密は `auth.json` だけで、ディレクトリが 700 なら中身は読まれない。作る `config.json` も umask どおり）
- 違うときだけ chmod し、直したら `そろえました: <パス> の mode を 775 から 700 に` のように 1 行出す。比べるのは
  権限の 3 桁（rwx）だけ（GNU の chmod はディレクトリの setgid を残すので、特殊な桁までは比べない）
- config directory が symlink・持ち主が自分でない・700 にできないときは、mode も `config.json` も変えずに警告する
  （token を置く場所の安全を確かめられないため。`NOTION_HOME` の末尾の `/` は外してから symlink かを見る）。
  ディレクトリでないもの（普通のファイル）なら、`config.json` を作れずに警告する
- `auth.json` が symlink・普通のファイルでない・600 にできないときは、`auth.json` だけ変えずに警告し、`keyring` はそろえる
- `true`・`null` では mode に触らない（`true` の token は OS の keychain にあり、config directory に秘密が無い。`null` は
  ntn の設定に触らない）

### ntn の config directory の場所

`bootstrap-ntn.sh` は ntn と同じ規則で決める（Linux の ntn 0.23.25 で確かめた。公式の文書は 4 つの場所の順だけを書く）。
`ntn doctor` の `Config` の行が、ntn の使っている場所を出す。

1. `NOTION_HOME`（空でなければ）。ディレクトリでなければ ntn も止まるので、作らずに警告する
2. `$XDG_CONFIG_HOME/notion`（`XDG_CONFIG_HOME` が空でなく、ディレクトリのとき）
3. `~/.config/notion`（`~/.config` がディレクトリのとき。`~/.notion/config.json` があっても見ない）
4. `~/.notion`

### ntn の keyring を確かめる

```sh
cat ~/.local/state/dotfiles/ntn.json   # {"keyring":false}
ntn doctor                             # Config の行が config directory
cat ~/.config/notion/config.json       # "keyring": false (場所は ntn doctor の Config の行)
ls -ld ~/.config/notion ~/.config/notion/auth.json   # keyring: false なら drwx------ と -rw-------
```

`keyring` を切り替えると token の置き場所が変わる。切り替えたあと `ntn doctor` で token が見つからなければ、`ntn login` し直す。

## Claude Code

`nix/files/claude/` 配下を `~/.claude/` へ配置する。

| 配置先 | 実体 | 単位 |
| --- | --- | --- |
| `~/.claude/CLAUDE.md` | `nix/files/claude/CLAUDE.md` | ファイル（生成。下の節を末尾に連結） |
| （同上）「タスク管理」の節 | `nix/files/claude/CLAUDE.dev-tracker.md` | `dotfiles.claude.devTracker.enable` のマシンでだけ連結（[後述](#claude-code-の-skill-を-host-ごとに止める)） |
| `~/.local/state/dotfiles/claude-notion.json` | `dotfiles.claude.notion.{profile,routes,override}` から生成 | ファイル（Notion の宛先。[後述](#notion-の宛先を-host-ごとに選ぶ)） |
| `~/.local/state/dotfiles/claude-video-offer.json` | `dotfiles.claude.videoOffer.autoStart.enable` から生成 | ファイル（解説動画を答えを待たずに作り始めるか。[後述](#解説動画を作る場面を知らせるフック)） |
| `~/.local/state/dotfiles/claude-heavy-jobs.json` | `dotfiles.claude.heavyJobs.limitPercent` から生成 | ファイル（重い処理の資源の上限の割合。[後述](#重い処理の資源の上限を-host-ごとに決める)） |
| `~/.local/state/dotfiles/claude-ssh-agent-notice.json` | `dotfiles.claude.sshAgentNotice.extraCommands` から生成 | ファイル（中で ssh を打つ道具の一覧。[後述](#1password-の-ssh-承認を知らせるフック)） |
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

`~/.claude/skills/` には Anthropic 配信・このリポジトリ・`claude-skills`・パッケージ同梱
（herdr）の 4 系統が同じ名前空間で並ぶ。prefix が無いと **一覧を見ても自分のものが判別できず**、
配信物は増減するので一般名詞（`dataviz` `run` `init` など）は将来ぶつかる。
こちら側は `check-claude-frontmatter.sh` が検査する（[次節](#frontmatter-を確かめる)）。
`claude-skills` 側も同じ規約で、あちらは `scripts/lint.sh` が検査する。

パッケージ同梱の skill（nixpkgs の `installAgentSkills` が `share/skills/` に入れるもの）は
自作ではないので、upstream の名前のまま置く。張り方は `nix/files/claude/skills/README.md`
の「パッケージ同梱の skill」。

### frontmatter を確かめる

skill・agent・command の frontmatter は、`nix/scripts/check-claude-frontmatter.sh` が yq で YAML として読んで確かめる
（TKT-289）。CI の `lint` ジョブも流す。足したり frontmatter を直したりしたら、手元でも流す（yq が無ければ `nix/` の
devShell に入り直す）。

```sh
./nix/scripts/check-claude-frontmatter.sh
```

frontmatter が YAML として読めなくても、Claude Code はエラーを出さない。1 行の値を引用符で包んで読み直し、それでも読めない
形（素の複数行の値の途中の「: 」など）では frontmatter を空として扱う（`description` の代わりに本文の最初の行が一覧に出て、
いつ使うものかが Claude に伝わらない）。読めても、値の途中の `---` で frontmatter が閉じる・素の値の「 #」から先がコメント
として消える、といった形では値が黙って変わる。script は読み直しに頼らず YAML として読めない形をどれも落とし、これらと、
`name` とディレクトリ名（agent はファイル名）の食い違い・`pjp-` で始まらない名前でも落ちる（全部は script の先頭）。
skill の `metadata` も見る（map であること・`pjp-pack` が pack の名前のどれかで、`bootstrap-claude-skill-overrides.sh` の
読む形であること・入口の skill `pjp-pack-<pack>` に `pjp-pack` が無いこと。[前述](#skill-の一覧を枠に収める-pack-と同期された-skill)）。
観点は `claude-skills` の `scripts/lint.sh` に揃えてある。

### なぜディレクトリごとではなく中身を 1 つずつ symlink するのか

`~/.claude/` 配下は **Claude Code 自身が書き換える**。`skills/` には `manifest.json`
があり、Anthropic 配信の skill（`pdf` / `docx` / `xlsx` / `pptx` など）がここへ入る。
ディレクトリごと store の symlink にすると、それらの導入・更新が壊れる。

中身を 1 つずつ配置すれば、Claude Code 管理のものと**兄弟として並ぶ**だけで衝突しない。

```
~/.claude/skills/
├── manifest.json      <- Claude Code 管理 (実ファイル)
├── pdf/  docx/  ...   <- Claude Code 管理 (実ディレクトリ)
├── pjp-my-skill -> /nix/store/…   <- Nix 管理
└── herdr -> /nix/store/…-herdr-…/share/skills/herdr/herdr   <- Nix 管理 (パッケージ同梱)
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

#### フックの登録（冪等。更新時も毎回走る）

```sh
./nix/scripts/bootstrap-claude-hook.sh
```

フックの定義は `settings.json` にしか書けないが、そのファイルは Claude Code
自身が書き換える（権限の「常に許可」など）ため Nix 管理下に置けない。
**スクリプト本体だけを Nix が配置し、登録はこのコマンドで行う。**
冪等で、既存の設定は保持する。

#### 解説動画を作る場面を知らせるフック

`PostToolUse` フック（`nix/files/claude/hooks/video-offer-nudge.sh`）。設計を書き出した・
PR を作った瞬間に、「`pjp-video-explainer-offer` skill を読み、条件に合えば解説動画を作るかを聞け」
と Claude の文脈へ 1 文を差し込む。作るかどうか・聞き方は skill の側（private な claude-skills）が持つ。

聞くか、答えを待たずに作り始めるかは、host option **`dotfiles.claude.videoOffer.autoStart.enable`**（既定 false）で
選ぶ。home-manager が値を `~/.local/state/dotfiles/claude-video-offer.json`（`{"autoStart":false}`）に置き、
このフックと skill が読む（[ADR 023](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/023_claude_video_offer_host_option_20261018T121637JST/README.md)）。

| `autoStart` | フックが差し込む文 | skill の動き |
| --- | --- | --- |
| false（既定）・ファイルが無い・壊れている | 「…解説動画を作るかを聞くこと」 | 作る前に聞く（短く作る / 詳しく作る / 今回は作らない / このセッションでは聞かない） |
| true | 「…解説動画の短尺を裏で作り始めること」 | 答えを待たずに短尺を作り始め、作り始めてから「このまま作るか」を確かめる |

- 使うマシンは、dotfiles-private に登録したファイルか `~/dotfiles/flake.nix` に足したホストの `mkHome` に
  `claude.videoOffer.autoStart.enable = true;` を書く。反映は `home-manager switch`（`~/dotfiles/setup --update` でもよい）。
  settings.json は通らない
- `~/.claude/CLAUDE.md` の「解説動画を作るか聞く」の節は、値によらず同じ文（どちらにするかは skill が決める）
- 名指しで頼んだ解説動画（`pjp-video-explainer-pictogram` / `pjp-video-explainer-dialogue`）は、値によらず作れる

| 知らせる場面 | 条件 |
| --- | --- |
| PR の作成 | Bash で `gh pr create` が成功した（stdout に PR の URL がある） |
| 設計のページ | Write でタグ「設計」を含む cc-page の `index.html` を新しく作った |
| 設計の文書 | Write で `docs/superpowers/specs/*.md` か、ADR そのもの（`docs/adr/<名前>.md` か `docs/adr/<名前>/README.md`）を新しく作った |

subagent の中（入力に `agent_id` がある）・skill が無いマシン・ADR の dir の中の textbook や図・
既存の PR を返しただけの `gh pr create`（stdout に `a pull request for branch … already exists`。`2>&1 | tail`
でつなぐと exit code が隠れて成功として届く）では黙る。
user の `settings.json`（`${CLAUDE_CONFIG_DIR:-~/.claude}/settings.json`）の `skillOverrides` で
`pjp-video-explainer-offer` を `off` か `user-invocable-only`（Claude が skill を呼べない値）にしたときも黙る
（dotfiles はこの key を書かない。聞くことも止めたいマシンが手で書く）。
ユーザーが「このセッションでは聞かない」（作り始める側では「このセッションでは作らない」）を選ぶと、skill が `${XDG_STATE_HOME:-~/.local/state}/pjp-video-offer/off-<session_id>`
を置き、そのセッションでは会話の圧縮の後も黙る。登録は上と同じ
`./nix/scripts/bootstrap-claude-hook.sh` が `hooks.PostToolUse` に 2 件（`Bash` + `if: "Bash(gh pr create *)"`・`Write`）足す。

#### 方針を承認したら PR まで走り切らせるフック

`PostToolUse` フック（`nix/files/claude/hooks/run-through-nudge.sh`）。superpowers の 4 つの skill を
読み込んだ直後に、「確認を挟まずに PR まで走り切る」と Claude の文脈へ 1 文を差し込む。
何をするかの正本は `~/.claude/CLAUDE.md` の「方針を承認したら PR まで走り切る」節で、hook は
問いを出させる skill の文面の隣でそれを思い出させるだけ（経緯は
[ADR 019](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/019_claude_run_through_after_approval_20261016T150008JST/README.md)）。

| 読んだ skill | 差し込む文の要旨 |
| --- | --- |
| `superpowers:brainstorming` | 方針の承認を spec の前に 1 回聞き、「承認したら PR まで確認を挟まずに進める」と書き添える。承認のあとは spec の承認を待たない |
| `superpowers:writing-plans` | 書き添えつきの承認を得ていれば、実装計画のレビューと実行方式の選択を聞かず、推奨の方式を告げて実行に入る。得ていなければ、ここで 1 回だけ聞く |
| `superpowers:using-git-worktrees` | worktree を作るかを聞かない。外ならその場で既定の branch から feature branch を切る |
| `superpowers:finishing-a-development-branch` | 書き添えつきの承認を得ていれば、3 択を聞かずに push して PR を作る（merge はしない。載る commit を先に確かめる）。得ていなければ、PR を出してよいかだけ聞く |

writing-plans と finishing を条件つきにしているのは、計画だけ頼まれた会話などで、告げずに push と PR まで
進まないようにするため。上の 4 つ以外の skill・subagent の中（入力に `agent_id` がある）・読み込みに失敗した skill
（`tool_response.success` が `false`）・壊れた入力では黙る。skill の名前は hook の `if` ではなく
script の中で見る（`"if": "Skill(…)"` は Claude Code 2.1.299 で発火しなかった）。登録は上と同じ
`./nix/scripts/bootstrap-claude-hook.sh` が `hooks.PostToolUse` に 1 件（`Skill`）足す。

#### 1Password の SSH 承認を知らせるフック

`nix/files/claude/hooks/ssh-agent-notice.sh`。Claude が SSH agent（1Password）を使うコマンドを Bash で打つ前に、
「どこから・何を・承認の画面はどの接続の端末に出るか」を知らせ、断られたら打ち直さずに選択肢の問いを出させる。
herdr の中の agent は手元の PC から転送された接続のもので（[前述](#forward-された-agent-を固定名で見せる)）、
1Password の承認の画面にはどの pane が頼んだかが出ないため（経緯は
[ADR 029](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/029_claude_ssh_agent_notice_20261022T194758JST/README.md)）。判断は script がするので token を使わない。

| いつ | すること |
| --- | --- |
| 打つ前（PreToolUse） | 一覧に当たれば、会話の画面に「🔑 1Password の承認が出るかも (<種類>): <コマンドの頭> — 承認の画面は 10/22 08:59 に polle@pjp-raiden から入った接続の端末に出る (より新しい接続: …)」を出す（WSL で `SSH_AUTH_SOCK` が空なら「Windows の 1Password が出す」）。herdr の pane なら、herdr の通知（どこから・頭・接続の 3 行、音つき）も出す。同じ pane からの通知は 10 分に 1 回。コマンドは止めない |
| 断られたあと（PostToolUse・PostToolUseFailure） | 出力に agent の断り・agent との通信が切れた・agent に届かない（git の署名で口が無い・口の先が無いときの鍵の認証の失敗）があれば、Claude に「同じコマンドを打ち直さない。何をとどこからを書いてから、① 直し方（承認する・接続し直す・1Password を起動するなど）で打ち直す（推奨）② 飛ばして進める ③ 止める の問いを出す」と足す。herdr の指揮役の子は AskUserQuestion を使わずに問いを書いて終え、subagent は報告に書く。herdr の通知（理由ごとの title）も出す |

| 種類 | 打つ前に当てるもの |
| --- | --- |
| ssh の接続 | `ssh`・`scp`・`sftp`・`ssh-copy-id`・`sshfs`・`mosh`・`autossh`、`rsync` の `<host>:`、`nixos-rebuild` の `--target-host`・`--build-host`、`nix-copy-closure`、`nix` の `ssh://`、git の clone・fetch・pull・push・ls-remote で相手の URL が ssh |
| 署名 | git の commit・merge・rebase・cherry-pick・revert・am・pull・commit-tree・tag・`push --signed` で署名するとき（git に実効の設定を聞く。Claude の会話は[無署名](#commit-を無署名にする)なので、素の `git commit` は当たらない）・`ssh-keygen -Y sign`・`ssh-add -T` |
| 設定の一覧 | host option **`dotfiles.claude.sshAgentNotice.extraCommands`** の項目 |

- コマンドの文字は、引用符・heredoc の本文・コメントを外して単純コマンドに分けて見る（commit のメッセージに ssh と
  書いても当たらない）。包むコマンド（`timeout`・`sudo`・`env`・`nix develop -c` など）は外し、`bash -c` などに文字列で
  渡したものは読み直す。script の中・関数・alias・変数に入れたコマンドは見えない（断られれば、あとの問いで受ける）
- 中で ssh を打つ道具は、使う PC のホストの値（dotfiles-private に登録したファイルか `~/dotfiles/flake.nix` の tmp）の
  `mkHome` に `claude.sshAgentNotice.extraCommands = [ "nix run .#vm" ];` と書く。項目は語を空白で区切った glob で、
  1 語目をコマンドの頭の語に、残りを引数の中に順に当てる（`nix run -L .#vm -- ip` にも当たる）。home-manager が
  `~/.local/state/dotfiles/claude-ssh-agent-notice.json` に置き、hook が読む（反映は `~/dotfiles/setup --update`）
- 断りの文言は、行の終わりが文言のときだけ当てる（OpenSSH の行の終わりの `\r` は外して見る）。成功した Bash
  （`2>&1 | tail` で終了コードが隠れたもの）では、行の頭も ssh・git が出す形に固定する。grep・cat・diff の結果に出た
  文言では当てない
- herdr の指揮役の子かどうかは、pane の workspace の印で見る（`herdr workspace get`）。claude-skills の
  pjp-herdr-other-repo の `ws-mark.sh` が付ける印のどれか（親を示す token `parent`・親子の印の token `kin` の 🌱・
  前の形の名前の先頭の 🌱）があれば子だと言い切り、無ければ条件つきで書く（経緯は
  [ADR 036](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/036_ssh_agent_notice_child_tokens_20261026T184721JST/README.md)）
- 64 KB（gawk・mawk の無いマシンでは 16 KB）を超えるコマンドは読まない。herdr は 2 秒で切って呼び、落ちた・返事を
  しないときは続く 60 秒は呼ばない（どちらも Bash を待たせないため）
- 登録は上と同じ `./nix/scripts/bootstrap-claude-hook.sh` が `hooks` の `PreToolUse`・`PostToolUse`・`PostToolUseFailure`
  に 1 件ずつ（`Bash`）足す。0 以外で終わった Bash には PostToolUse が来ず、PostToolUseFailure だけが来る
  （Claude Code 2.1.306 で確かめた）

#### ほかの repo への参照で push・PR を止めるフック

`PreToolUse` フック（`nix/files/claude/hooks/xref-guard.sh`）。Claude が public な repo に、ほかの repo の issue・PR・commit への
参照（`owner/repo#番号`・`owner/repo@sha`・github.com の issues・pull・discussions・commit の URL）を書こうとしているとき、
`git push` と `gh pr create` などを打つ前に止め（`permissionDecision` の deny）、どの commit・どの行か・どう直すかを返す。
GitHub は参照先の timeline に「mentioned this」「referenced」の跡を残し、付いた跡は本文を直しても force push で commit を外しても
消えないため（経緯は [ADR 033](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/033_claude_xref_guard_20261024T223152JST/README.md)。決まりは claude-skills の
pjp-dev-tracker の「repo に書くもの」）。判断は script がするので token を使わない。

| コマンド | 見るもの | 数える参照 |
| --- | --- | --- |
| `git push`（`git -C … push` も） | 押す commit（どの remote-tracking ref からも辿れないもの。新しい方から 1000 個。同じコマンドの `--amend` で書き換える HEAD は数えない）と、同じコマンドで push より前に作る commit（`git commit -m`・`-F`）の message | backquote の中も |
| `gh pr create`・`edit`、`gh issue create`・`edit` | タイトル | backquote の中も |
| 同上と `gh pr comment`・`review`、`gh issue comment` | 本文・コメント（`--body`・`--body-file`。`"$(cat <<'EOF' … EOF)"` は heredoc の本文を読む） | code block と inline code の外だけ |
| `gh pr merge` | merge の commit の件名・本文 | backquote の中も |

- 止めるのは public な repo と、公開範囲を確かめられない repo（gh が無い・未ログイン・github.com でない host）だけ。公開範囲は
  参照が見つかったときだけ `gh repo view` で引く（10 秒で切る。控えは持たない）。同じ repo の参照と `#番号`、手元の path への
  push は見ない。repo を渡していない gh の「同じ repo」は、`gh repo set-default` の repo（無ければ dir の remote の repo を全部）
- 同じコマンドの前の方で書いたファイル（`cat <<EOF > body.md`・`tee body.md`）は、後ろの `--body-file`・`git commit -F` で
  書いた中身を読む。`bash <<EOF`・`cat … | bash` に渡した script も読む
- 意図して参照するときは、**ユーザーが明示したときだけ**、コマンドの頭に `PJP_ALLOW_XREF=1` を付けて打つ（`env` の引数・
  `bash -c` の中にも効く。止めたときに返す文にも「自分の判断では付けない」と書いてある）
- コマンドの文字の読み方は[前述](#1password-の-ssh-承認を知らせるフック)の hook と同じく近似で、script の中・関数・alias・
  変数に入れたコマンド、`gh api` で書くコメント、`gh pr create --fill` は見えない。64 KB（gawk・mawk の無いマシンでは 16 KB）を
  超えるコマンドは中を読まず、参照か `git … push` があれば止めて、本文をファイルにするかコマンドを分けるよう返す
- ユーザーが手で打つ push・PR は止めない（git の pre-push hook は使わない）
- 登録は上と同じ `./nix/scripts/bootstrap-claude-hook.sh` が `hooks.PreToolUse` に 1 件（`Bash`）足す

#### 設計の文書を public な repo の docs/ に書かせないフック

`PreToolUse` フック（`nix/files/claude/hooks/docs-guard.sh`）。この repo は public なので、設計の文書（spec・実装計画・ADR・
textbook・図）は private な dotfiles-private の `docs/` に置く（決まりは repo の直下の [`CLAUDE.md`](../CLAUDE.md)、経緯は
dotfiles-private の [ADR 035](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/035_dotfiles_docs_private_20261025T150115JST/README.md)）。
Claude が `Write`・`Edit`・`MultiEdit`・`NotebookEdit` でこの repo（worktree も）の直下の `docs/` に書こうとしたら止め
（`permissionDecision` の deny）、書き先（dotfiles-private の `docs/` の同じ相対パス）と、手元・cloud での取り方を返す。

- 止める repo は hook の中の表で決める（今は `pollenjp/dotfiles` → `pollenjp/dotfiles-private` の 1 行）。origin の URL の
  `owner/repo` で当てるので、worktree・cloud の clone でも効く。公開範囲は gh で引かない（表に無い public な repo の `docs/` は
  止めない）。ほかの repo にも効かせるなら、表に足す
- 下の階層の `docs/`（`nix/pkgs/<道具>/docs/` など）は止めない
- Bash で書くもの（`cat > docs/…`）は見ない。抜けたものは CI の `lint` ジョブの「docs/ を置かない」が落とす
- 通す口は無い。public に置く文書が要るようになったら、表と CI の step を直す
- 登録は上と同じ `./nix/scripts/bootstrap-claude-hook.sh` が `hooks.PreToolUse` に 1 件（`Write|Edit|MultiEdit|NotebookEdit`）足す

#### PR に gh の認証ユーザーを assignee で付けさせるフック

Claude が PR を作るたびに、gh で認証しているユーザー（`@me`。アカウントは gh の認証で決まる）を Assignees に付ける（ユーザーの
既定）。決まりと付け方・確かめ方の正本は、同じ dotfiles の skill `pjp-gh-pr-create`（`nix/files/claude/skills/pjp-gh-pr-create/`）
で、`gh pr create` に `--assignee @me` を足し、`gh pr view` で付いたかを確かめさせる（経緯は dotfiles-private の
[ADR 039](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/039_claude_pr_assignee_20261030T172236JST/README.md)）。

skill が読まれなかったときの念押しが `PostToolUse`・`PostToolUseFailure` フック（`nix/files/claude/hooks/pr-assignee-nudge.sh`）。
`gh pr create` の後に Claude の文脈へ 1 文を差し込む。PR はもう出来ているので止めない。

| 知らせる場面 | 条件 | 差し込む文の要旨 |
| --- | --- | --- |
| 指定なし | `gh pr create` が PR を作った（出力に PR の URL がある）のに、assignee の指定（`--assignee`・`-a`。`--assignee=…`・`-a=…`・`-da` のように束ねたものも）が無い | `gh pr edit <URL> --add-assignee @me` で付け、`gh pr view` で確かめる |
| 作ったあとで落ちた | 出力に gh の `pull request update failed` がある（PR は出来ていて、assignee などを付ける段で落ちた） | 作り直さず、`gh pr view` で確かめ、空なら `gh pr edit` で付ける（指定があっても知らせる） |

- 既存の PR を返しただけ（`a pull request for branch … already exists`）・PR の URL が無い（`--web` など）では黙る。subagent の
  中でも知らせる（subagent も PR を出す）
- コマンドは近似で読む。heredoc の本文と引用符の中を外し、`;`・`&`・`|`・改行で分けて、`gh pr create` の後ろの語を見る（本文や
  タイトルに `--assignee` と書いても指定と数えない）。引用符の中にだけ `gh pr create` があるとき（`bash -c '…'`）は、引用符の
  中を読み直す
- 付けたくないマシンでは、user の `settings.json` の `skillOverrides` で `pjp-gh-pr-create` を `off` か `user-invocable-only` に
  する（skill が呼べなくなり、hook も黙る。dotfiles はこの key を書かない）
- cloud（[後述](#claude-code-on-the-web-cloud-で使う)）には張らない。cloud の GitHub proxy は GraphQL を断るので、`gh pr create` が
  PR を作れない。skill はほかの skill と同じく張る
- 登録は上と同じ `./nix/scripts/bootstrap-claude-hook.sh` が `hooks` の `PostToolUse`・`PostToolUseFailure` に 1 件ずつ（`Bash` +
  `if: "Bash(gh pr create *)"`）足す。`gh pr create` の後ろにつないだコマンドが落ちると、Bash は PostToolUseFailure にだけ来る

#### op.exe の直打ちを止め、承認の拒否のあとは問いを出させるフック

`nix/files/claude/hooks/op-reason-guard.sh`。WSL の `op`（[前述](#wsl-の-op-を理由つきで呼ぶ-1password-cli)）を Claude の作業に使わせる。
どのマシンにも置き、`op` の無いマシン（`~/.local/state/dotfiles/claude-op-reason.json` の `enable` が false。
`home/modules/op-reason.nix` が書く）では黙る。

| いつ | すること |
| --- | --- |
| 打つ前（PreToolUse） | `op.exe` を直に起こすコマンドを止め（deny）、`op --reason "<なぜ op を呼ぶか>" …` で打ち直すよう返す。承認は呼び出しごとに出るので、呼ぶ回数を減らす書き方（`vault get` を 11 回打たず `vault list --format json` を 1 回にするなど）と、op を打つ Bash の timeout を長く（600000）することも促す。承認の要らない `whoami`・`signout`・`--version`・`--help` は止めない |
| 拒否・時間切れ・止められたあと（PostToolUse・PostToolUseFailure） | `op` の記録に、この会話（`session_id`）の承認の拒否・時間切れ・承認を待つ間に止められた（end の `interrupted`）・ほかの op の承認待ちが終わらない（refused の `lock-timeout`）・それを待つ間に止められた（refused の `interrupted`）があれば、Claude に「同じ op を打ち直さない。何を・なぜ・どこからを書いてから、① 直し方（許可する・Bash の timeout を長くするなど）で 1 回だけ打ち直す（推奨）② 飛ばして進める ③ 止める の問いを出す」と足す。続けて承認の画面が出ると、慣れで許可しやすくなるため。herdr の指揮役の子は AskUserQuestion を使わずに問いを書いて終え、subagent は報告に書く |

- コマンドの読み方は ssh-agent-notice.sh と同じ（引用符・heredoc の本文・コメントの中の `op.exe` では止めない。包むコマンドを外し、
  `bash -c` などに文字列で渡したものは読み直す）。それに `powershell`・`pwsh` の `-Command`・`-c` と `cmd` の `/c` の中も読み、
  `C:\…\op.exe` のような `\` のパスも見る。script の中・関数・変数に入れた `op.exe` は見えない
- 拒否・時間切れは op の stderr の文言ではなく、`op` の記録（`end` の `result`）で見る（`op` は op の stderr を変えない）
- 登録は上と同じ `./nix/scripts/bootstrap-claude-hook.sh` が `hooks` の `PreToolUse`・`PostToolUse`・`PostToolUseFailure` に
  1 件ずつ（`Bash`）足す

#### gist やペースト共有のサービスへ上げさせないフック

`PreToolUse` フック（`nix/files/claude/hooks/gist-guard.sh`）。Claude が gist やペースト共有のサービス（0x0.st・transfer.sh・
termbin など）へ上げるコマンドと、gist を作る・書き換える MCP の tool を、打つ前に**いつも**止め（`permissionDecision` の deny）、
わけとどうするかを返す。確かめずに外へ上げると private な中身も公開され、secret gist も URL を知る人には読めるため（経緯は
dotfiles-private の [ADR 047](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/047_claude_gist_guard_20261109T222451JST/README.md)）。
判断は script がするので token を使わない。

| 止めるもの | 止めないもの |
| --- | --- |
| `gh gist create`・`new`・`edit`・`rename` と知らない subcommand（`hub gist create`、GitLab の `glab snippet create` も） | `gh gist list`・`view`・`clone`・`delete`、`--help` |
| `gh api`・`curl`・`wget`・HTTPie での gists の API への書き込み（POST・PATCH・PUT。GHES の `/api/v3/gists` も） | GET・HEAD・DELETE |
| push の先（pushurl と insteadOf を解いた URL。同じコマンドの `git remote add`・`set-url` も）が gist の `git push` | gist でない repo への push、gist の clone・fetch、`--dry-run` |
| ペースト共有のサービスへの送信（curl の `-d`・`-F`・`-T`、wget の `--post-file`、nc・socat・telnet の宛先、`> /dev/tcp/…`）と専用のコマンド（`pastebinit`・`wgetpaste`・`fpaste`・`gist`・`haste` など） | そのサービスからのダウンロード、専用のコマンドの `--help` |
| python・node などの `-c`・`-e`・stdin・同じコマンドで書いた script にある、gist の API・ペースト共有のサービスの URL と `create_gist` など | URL の path にサービスの名前があるだけのもの（`https://example.com/0x0.st`） |
| MCP の tool のうち、名前に gist と書き込みの語を含むもの（GitHub の MCP の `create_gist`・`update_gist`） | `get_gist`・`list_gists`・`delete_gist` |

- 通す口は無い（xref-guard の `PJP_ALLOW_XREF=1` のような印は作らない。Claude が自分で付けられてしまうため）。上げたいときは、
  ユーザーが自分で `! gh gist create <file>` のように `!` を付けて打つ。`!` で打つコマンドには PreToolUse の hook が走らない
  （Claude Code 2.1.319 で確かめた）。止めたときに返す文は、回り込まない（別のコマンド・別のサービス・script のファイルに書いて
  流す、をしない）こと・ユーザーに `!` で打ってもらうこと・Notion に載せたい HTML は Notion の HTML ブロック（`.html` を File
  Upload で上げ、`embed.file_upload` に付ける）で直接載せることを Claude に伝える
- ペースト共有のサービスは、host が hook の中の一覧（`paste_hosts`。0x0.st・transfer.sh・temp.sh・catbox.moe・pastebin.com・
  paste.rs・dpaste・sprunge.us・termbin.com・rentry など 26）の domain かその sub-domain なら止める。増やすときは一覧に足す
- コマンドの読み方は xref-guard と同じ lexer（`/dev/tcp/…` への書き込みを拾うよう足した）で、包むコマンド・`bash -c`・`eval`・
  `ssh <host> <コマンド>`・`find -exec` の中と、同じコマンドで書いた script（`bash up.sh`・`source`）も読む。commit の message・
  grep の引数・heredoc の本文に書いただけでは止めない。script のファイルの中（同じコマンドで書いたものを除く）・関数・alias・
  組み立てた URL・短縮 URL・一覧に無いサービスは見えない（手癖を止めるためのもので、回り込みを全部は塞げない）。64 KB（gawk・
  mawk の無いマシンでは 16 KB）を超えるコマンドは中を読まず、上げる形の文字があれば止めてコマンドを分けるよう返す
- 登録は上と同じ `./nix/scripts/bootstrap-claude-hook.sh` が `hooks.PreToolUse` に 2 件（`Bash` と `mcp__.*[Gg]ist.*`）足す。
  MCP の tool の名前は `mcp__<server>__<tool>` なので、gist を名前に含む tool でだけ hook が走る。cloud
  （[後述](#claude-code-on-the-web-cloud-で使う)）にも張る

#### footer から溢れるリンクを cc-pages の会話のトップページに残すフック

`Stop` フック（`nix/files/claude/hooks/footer-links-archive.sh` と、本体の `footer-links-archive.mjs`）。会話に出たリンクを、footer の
バッジと同じ規則で全部拾って cc-pages の会話のトップページに残す。何を拾い、どこに残し、いつ黙るかは
[溢れたリンクを会話のトップページに残す](#溢れたリンクを会話のトップページに残す)。登録は上と同じ
`./nix/scripts/bootstrap-claude-hook.sh` が `hooks.Stop` に 1 件（matcher なし・`async: true`）足す。cloud には張らない（cc-pages が無い）。

### statusLine

Claude Code の下端に出る 1 行（`nix/files/claude/statusline-command.sh`）。

```
📄top · <model> · <dir basename> · <git branch>[*] · <context% left>
```

shell prompt（starship）が既に出しているもの（時刻・`user@host`・フルパス）は
意図的に繰り返さない。数百 ms ごとに呼ばれるので `jq` は 1 回にまとめて起動している。

先頭の `📄top` は、cc-pages の会話のトップページへのリンク（OSC 8）。押すと `http://localhost:<port>/s/<session_id>/` が開き、
cc-pages がその会話のトップページ（`/p/<会話>/`）へ送る。footer から溢れたリンクも、そのページの「リンク」の節に残っている
（[溢れたリンクを会話のトップページに残す](#溢れたリンクを会話のトップページに残す)）。狭い pane でも切れないよう先頭に置く。

- 出すのは、入力の `session_id` が英数字と `-` だけで、`cc-pages` が PATH にあり、`CC_PAGES_DISABLE` が空のときだけ（cc-pages の
  無いマシンには出ない。フックと同じ見方）
- `<port>` は `dotfiles.ccPages.port`（`null` なら 7777）。script には `@ccPagesPort@` と書き、home-manager が footer の cc-page の
  規則と同じ port で埋めて置く（`home/modules/claude.nix`）。port を変えたら switch で変わる
- 押して開けるのは、Claude Code が status line の OSC 8 をそのまま出す端末。herdr の pane では `FORCE_HYPERLINK=1`
  （[herdr の中の Claude Code にリンクを出させる](#herdr-の中の-claude-code-にリンクを出させる)）で OSC 8 のまま出し（2.1.321 で、
  pane の中の claude の生の出力に `ESC]8;id=…;http://localhost:<port>/s/<session_id>/` があることを確かめた）、herdr が Ctrl+クリックで開く
- 問いの上に footer の 2 行を出す mod（claude-skills の `pjp-question-footer`）は status line の 1 行目を写すが、OSC 8 を捨てるので、
  そこの `📄top` は押せない文字になる
- 出し方は `nix/tests/statusline-command.test.sh`、port を埋めることは `nix/tests/claude-statusline.nix` が確かめる

#### 登録（冪等。更新時も毎回走る）

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

### footer に会話のチケットと PR と cc-page のリンクを出す

会話の中で触れた Dev Tracker のチケット（`TKT-n` / `WRK-TKT-n`）と GitHub の PR、cc-page のページを、
プロンプト下の footer にクリックできるバッジとして並べる。

```
⏵⏵ bypass permissions on (shift+tab to cycle) · TKT-12 · 📄0003 · dotfiles#34 · claude-skills#5 · TKT-9
```

Claude Code の `footerLinksRegexes`（2.1.176〜）を使う。turn の終わりに、その turn の
出力（tool の結果と Claude の応答の文章）を正規表現で走査し、当たったものをバッジにする。

- 並ぶのは今の branch の PR バッジ（組み込み）込みで最大 5 個。新しいものが先頭に入り、
  6 個目が来ると一番古いものが落ちる。同じ URL は 1 個にまとまる。落ちたものも、cc-pages の会話のトップページに残る
  （[溢れたリンクを会話のトップページに残す](#溢れたリンクを会話のトップページに残す)）
- ユーザーが打った文は拾わない。Claude が応答で同じリンクに触れれば拾う
- `/clear` で消え、resume すると transcript の末尾から作り直す
- `settings.json` を書き換えると、実行中の session にも次の turn から効く
- 問いの上に footer の 2 行を出す mod も、同じ `footerLinksRegexes` を本体と同じ決まりで読む。
  規則を足せば、問いの上にも同じバッジが出る

| 項目 | 拾うもの | バッジ |
| --- | --- | --- |
| チケット | ID と `https://app.notion.com/p/…` が同じ行に並ぶもの（`ticket.sh` の書き込み系の出力 `TKT-n: …  URL`、応答の `TKT-n: URL` や `[TKT-n](URL)`） | `TKT-12` |
| PR | `https://github.com/<owner>/<repo>/pull/<番号>`。`ticket.sh list` の行（空白 2 つ + `TKT-n` で始まる）に載るものは外す | `dotfiles#34` |
| cc-page | `http://localhost:<port>/p/<セッション>/<番号>-<題>`（`cc-pages new` の出力の JSON の `url`、応答の `→ URL` の行、`[…](URL)`）。`<port>` はこのマシンの cc-pages の port。セッションの top（`/p/<セッション>/`）・ほかの port・`%XX` に符号化された URL は拾わない | `📄0003` |

値は `nix/files/claude/footer-links.json`。この形にしている理由:

- チケットの URL はタイトルの英数字の部分と 32 桁の id でできていて、`TKT-n` を含まない。
  label に ID を出すため、ID と URL が同じ行に並ぶ形を拾う。間に別の ID を挟んだ URL とは組ませない
- url の `{名前}` に差し込む値は `encodeURIComponent` されるので、URL を丸ごと 1 つの
  placeholder で差し込めない。owner・repo・番号や、Notion の page の部分、cc-page のセッションと
  ページを別々に取って組み直す
- 会話の始めに打つ `ticket.sh list` には、他のチケットの PR が載る。素朴に拾うと関係の無い PR が
  毎回 footer に居座るので、否定の後読みで外している
- 本体も mod も、url の型紙の `{…}` を `x` にして読んだ origin（scheme・host・port）と違う url は捨てるので、
  cc-page の port は型紙に書くしかない。port はマシンごとに `dotfiles.ccPages.port`
  （[待ち受けの port を変える](#待ち受けの-port-を変える)）で変わるので、`footer-links.json` には
  `@ccPagesPort@` と書き、home-manager がこのマシンの port（`null` なら cc-pages の既定の 7777）で埋めて
  `~/.local/state/dotfiles/claude-footer-links.json` を作る（`home/modules/claude.nix`）
- cc-page の題には日本語が入る。cc-pages の題の部分は文字と数字と `-` だけ（英字は小文字）なので、
  ASCII では英小文字・数字・`-` のほか（JSON の `"`、Markdown の `)`・`]`、空白、`/`・`#` など）で止め、
  ASCII の外では一般句読点（`…`・`“”` など）と和文・全角の句読点・括弧・空白で止める。Claude Code は
  `u` フラグなしで RegExp を作るので、`\p{L}` は使えない
- `%XX` に符号化された cc-page の URL（ブラウザのアドレス欄の写しなど）は、拾うと `encodeURIComponent` で
  二重に符号化されて開けない。後ろに `%` か題の文字が続くときは、途中で切った一致も作らずに拾わない
- cc-page の url は、末尾に `/` を付けたページの正規の形にする（cc-pages は `/` の無い形を 301 でここへ
  送る）。本文の URL に `/` があっても無くても、同じバッジにまとまる
- `footerLinksRegexes` は user / flag / managed の settings からしか読まれない。repo の
  `.claude/settings.json` に置いても効かない

> ⚠️ tool の出力に出たリンクは何でも拾う。PR の URL を多く含む docs を読むと、5 枠がそれで
> 埋まる。前のチケットを `ticket.sh show` で読むと、そこに載る PR と cc-page も拾う。作業中のチケットは
> `ticket.sh` を打つたびに出力に出るので、すぐ先頭へ戻る。

正規表現の当たり方は `nix/tests/claude-footer-links.test.mjs` が、port を埋めた状態ファイルの中身は
`nix/tests/claude-footer-links.nix` が確かめる（[テスト](#テスト)）。
Dev Tracker の ID の prefix を増やしたら（新しい workspace）、`footer-links.json` とテストの両方に足す。

#### 登録（冪等。更新時も毎回走る）

```sh
./nix/scripts/bootstrap-claude-footer-links.sh
```

statusLine と同じ事情で、値は `settings.json` にしか書けない。skill-overrides と同じく、
home-manager が `~/.local/state/dotfiles/claude-footer-links.json` に値（cc-page の規則の port を埋めたもの）を
置き、このコマンドが `.footerLinksRegexes` を丸ごと置き換える。このキーは dotfiles が持つので、手で足した項目も
次の実行で消える。足したいなら `footer-links.json` に書く。

`dotfiles.ccPages.port` を変えたら、switch で状態ファイルの cc-page の規則が新しい port になり、このコマンドが
`settings.json` へ写す（`~/dotfiles/setup --update` なら続けて走る）。写すまで、footer は前の port のページを拾う。

#### 溢れたリンクを会話のトップページに残す

footer のバッジは 5 個まで（Claude Code の本体が決めていて、設定では増やせない）で、長い会話では前に出たリンクが押し出されて
辿れなくなる。そこで Stop フック（`nix/files/claude/hooks/footer-links-archive.sh`）が turn の終わりごとに、会話に出たリンクを全部
cc-pages の会話のトップページ（`/p/<会話>/`）の「リンク」の節に残す。status line の先頭の `📄top`（[statusLine](#statusline)）から
開ける。footer の 5 枠と規則は変えない（footer には今までどおり出る）。

- 拾うのは footer と同じ文（Claude の応答の文章と tool の結果。ユーザーが打った文・subagent・thinking・tool の入力は拾わない）に、
  footer と同じ規則（`settings.json` の `footerLinksRegexes`）を当てたもの。footer と違い、文を末尾 8192 字に切らず、一致も 1 つの
  文の 1 つの規則で 1000 件まで見る（全部を残すのが役目なので）
- 組（PR・チケット・cc-page・その他）は URL の形で付ける。cc-page は、footer の cc-page の規則と同じ port（このマシンの cc-pages）の
  ページ
- 渡すのは `cc-pages link --session <session_id> --stdin`（1 行 1 件の JSON Lines。URL・label・組・出どころ（応答か tool か）・時刻）。
  同じ URL は cc-pages が 1 つにまとめる
- 本体（隣の `footer-links-archive.mjs`）は node で書いていて（footer の規則は JavaScript の RegExp）、PATH の node（mise が入れる
  言語ランタイム）で動く。home の閉包には node を入れない
- 会話ごとの控え（transcript のどこまで読んだか）は `${XDG_STATE_HOME:-~/.local/state}/pjp-footer-links-archive/sessions/<session_id>.json`。
  次の turn は続きの完全な行だけを読む（書きかけの最後の行は次に回す）。cc-pages が受け取ってから控えを進めるので、失敗した分は
  次の turn に渡し直す。transcript が縮んだ・別のファイルに替わったら初めから読み直す。30 日より古い控えは消す（消した会話を
  resume すると、初めから読み直して同じものを渡す）
- 入れる前から続いている会話も、入れた後の最初の turn で初めから読んで全部渡す
- Esc で止めた turn（Stop が来ない）の分は、次の turn にまとめて渡す。Stop の時点では最後の応答がまだ transcript に書かれていない
  ことがある（2.1.321 で見た）ので、Stop の入力の `last_assistant_message` にも規則を当てて渡す
- hook は裏で走り（`async: true`）、turn の終わりを待たせない。何が起きても何も出さず、終了コード 0 で終わる

| 状況 | hook |
| --- | --- |
| `cc-pages` が PATH に無い（取れないマシン）・`CC_PAGES_DISABLE` が空でない・`node` が PATH に無い | transcript を読まずに何もしない |
| `cc-pages` が `link` を知らない（古い） | 控えを進めず、その binary の間は transcript を読まない。build し直すと（`bootstrap-cc-pages.sh`。`--update` で走る）、溜まった分をまとめて渡す |
| `claude -p` の会話 | 終わりで裏の hook が止められることがある。控えは進まないので、resume して turn を進めると続きから渡る |

1 つの会話を手で流すとき（終わった会話を埋める・試す）は、session id と transcript を渡す。初めから読み、拾った数と cc-pages の答えを
stderr に出す（cc-pages が失敗すれば終了コード 1）。

```sh
~/.claude/hooks/footer-links-archive.sh --session <session_id> --transcript ~/.claude/projects/<dir>/<session_id>.jsonl
```

登録は `bootstrap-claude-hook.sh`（[フックの登録](#フックの登録冪等更新時も毎回走る)。`--update` で走る）。`settings.json` に登録した
hook は、動いている会話にも次の turn から効く。Claude Code の file watcher が settings の hook の変更を拾うため（2.1.321 で、動いている
会話の `.claude/settings.local.json` に足した Stop の hook が次の turn から走ることを確かめた。`--settings` で渡したファイルは見張らないので、
そちらに足した hook は開き直すまで走らない）。振る舞いは `nix/tests/footer-links-archive.test.mjs`（本体）と
`nix/tests/footer-links-archive-gate.test.sh`（入口）が確かめる。

### herdr の中の Claude Code にリンクを出させる

herdr の pane の中では、シェルの init が `FORCE_HYPERLINK=1` を export する（TKT-270）。fish の
`interactiveShellInit`（`home/modules/fish.nix`）と bash の `initExtra`（`home/modules/bash.nix`）にあり、
`HERDR_ENV` が空でなく、`FORCE_HYPERLINK` がまだ無い shell でだけ立てる。

#### なぜ要るのか

herdr（0.9.5）は `ui.mouse_capture = true`（既定。dotfiles も変えていない）の間、pane が出したリンク（OSC 8）を外の端末へ
渡さず、自分で持って Ctrl+クリックを受ける。開けるのは `http://`・`https://` の OSC 8 のリンクと、画面に出ている同じ形の文字で、
Linux 版は `xdg-open` で開く（WSL は [WSL の xdg-open](#wsl-の-xdg-open)）。`false` にすると OSC 8 を外の端末へ通すが、
herdr のマウスの操作（タブのクリック・分割の線のドラッグなど）が使えなくなる。

つまり label だけのリンクは、pane の中のアプリが OSC 8 で出さないと開けない。Claude Code（2.1.318 で本体のコードを読んで
確かめた）は、リンクを出せる端末かを env で決める。

1. `FORCE_HYPERLINK` があれば、その値で決める（`0` なら出さない）
2. 無ければ `TERM_PROGRAM`（ghostty・kitty・iTerm.app・WezTerm・vscode など）・`WT_SESSION`・tmux 3.4 以上・
   `VTE_VERSION`・`TERM` などで見分ける

herdr の pane の env は `TERM_PROGRAM=herdr`・`TERM=xterm-256color`（と `COLORTERM`）で、どれにも当たらないので、出せない
端末と判断される。この判断によらずリンクを出す本体の footer は Ctrl+クリックで開ける。一方、Claude Code の `Link` で描くもの
（問いの上に footer の 2 行を出す mod のバッジなど）は判断に従い、「label の後ろに薄い URL」の形になる。label を押しても開かず、
2 個目からは URL が途中で切れる。`FORCE_HYPERLINK=1` を付けると、本体の footer と同じ label だけのリンクになる。

#### 効き方

- pane のシェルで立てるので、claude の起動の仕方（`c`・`claude`・`claude-<名前>`・`herdr agent start`）によらず効く。
  `herdr agent start` も、pane の対話シェルのプロンプトに打ち込んで claude を起こす
- 効くのは、switch のあとに開いた pane のシェルと、そこで起動した claude。前からある pane では、claude を終えて
  `exec fish` でシェルを読み直してから起動し直す（claude だけ起動し直しても、親のシェルの env は前のまま）
- 確認は herdr の pane で `printenv FORCE_HYPERLINK`（`1` が出る）。herdr の外の shell では何も出ない
- 振る舞いは `nix/tests/herdr-hyperlink.nix` が確かめる（[テスト](#テスト)）

#### 副作用

pane のシェルの env なので、pane で打つほかのコマンドと、Claude の Bash tool で打つコマンド（claude の子）にも
引き継がれる。

- `FORCE_HYPERLINK` を読む CLI（npm の `supports-hyperlinks`・Rust の `supports-hyperlinks` crate を使うものなど）は、
  出力が端末でなくても（パイプ・ファイル・Bash tool）リンクの制御文字を混ぜることがある。Bash tool の結果では ESC だけが
  落ち、`]8;;<URL>\<label>]8;;\` の形の文字が残る
- 1 回だけ止めるなら、そのコマンドに `FORCE_HYPERLINK=0` を付ける（fish も bash も `FORCE_HYPERLINK=0 <コマンド>`）
- すでに `FORCE_HYPERLINK` がある shell では触らない。`FORCE_HYPERLINK=0` を付けて起こした herdr server の pane では立たない

#### 置き場所で採らなかった案

| 案 | 却下理由 |
| --- | --- |
| `settings.json` の `env`（`bootstrap-claude-env.sh`） | herdr の外で動く claude にも効き、herdr の中だけという条件を付けられない |
| claude だけを包む fish の function | Bash tool で打つコマンドは結局引き継ぐので、副作用は減らない。`claude-<名前>` など別の起動経路を包み漏らす |
| herdr の `config.toml` | herdr 0.9.1 に、pane の env を足す設定が無い |
| `home.sessionVariables` | 条件を付けられず、herdr の外にも漏れる |

### Claude のセッションだけ git の設定を変える

Claude のセッション（Bash tool）の git にだけ、次の 2 つを効かせる。自分の手元の
ターミナルの素の git は変わらない（fetch 系の abbr / alias だけは、同じ option で
[git gh](#fetch-系を-gh-の資格情報で通す-git-gh) を使う）。

- **commit を無署名にする**（いつも）
- **GitHub へは gh の資格情報（HTTPS）で通す**（host option `dotfiles.claude.gitViaGh.enable`、既定 true）

同じ option で、Claude Code が plugin の marketplace と plugin を取る前に打つ ssh の確認（1Password の承認が出る）も
止める（[plugin の marketplace と plugin も https で取る](#plugin-の-marketplace-と-plugin-も-https-で取る)）。

#### commit を無署名にする

このマシンの git は 1Password の `op-ssh-sign` で署名する（[前述](#git-について)）。
署名のたびにホスト側 Windows の 1Password が承認ダイアログを出すため、Claude に
commit させるとそこで止まる。**Claude のセッションからの commit だけ**署名を外す。
tag も同じダイアログで止まるので併せて落とす。

> ⚠️ branch protection の "Require signed commits" が有効な repo では、Claude が作った
> commit は push で弾かれる。Claude が rebase / amend した既存 commit の署名も落ちる。

Claude の commit では 1Password の承認の画面は出ないので、[1Password の SSH 承認を知らせるフック](#1password-の-ssh-承認を知らせるフック)
も素の `git commit` には当たらない（`-S` や `git -c commit.gpgsign=true` で署名するときだけ当たる）。

#### GitHub へは gh の資格情報（HTTPS）で通す

ssh の remote への push / fetch は、WSL では `ssh.exe`（1Password の agent）を通る
（[ssh について](#ssh-について)）。そのため interop が外れると `Exec format error` で落ち、
通っても 1Password の承認ダイアログで止まる。gh は HTTPS の API で動くのでどちらにも依らない。
そこで Claude のセッションでは、GitHub の ssh の URL を https に読み替え、資格情報を gh から取る。

| git の設定 | 値 | 効き方 |
| --- | --- | --- |
| `url.https://github.com/.insteadOf` | `git@github.com:` と `ssh://git@github.com/` | fetch と push の両方で URL を読み替える。origin の URL は書き換えない |
| `credential.https://github.com.helper` | `!gh auth git-credential` | gh の token を git に渡す |

Claude は素の `git push` を打つだけでよい。skill が打つ `git push -u origin …` も
HTTPS になり、origin 名のまま通るので `origin/<branch>` も普段どおり進む。

読み替わるのは `git@github.com:` と `ssh://git@github.com/` で始まる URL だけ。ssh の
ホスト別名（`~/.ssh/config` の `Host` で付けた名前）や `gist.github.com` の remote は
今までどおり ssh を通る。別名は別アカウントの鍵を使うためのものなので、gh の token
（1 アカウント分）に寄せないのはむしろ都合がよい。

**前提は `gh auth login` 済みであること。** gh 自体は `home/modules/packages.nix` が入れる
（以前は mise の `github-cli` で入れていた。mise 側が残っていても動き、PATH の先にある方が
使われる）。gh が無い・未ログインなら
bootstrap が警告し、`setup` の最後の[警告のまとめ](#途中の警告のまとめ)にも出す。git の設定ファイルに
別の credential helper があるときも警告する（gh より先に呼ばれ、gh の token がそちらにも
保存されるため）。
gh にログインしないマシンは option を false にすると、今までどおり ssh を通る。

```nix
# dotfiles-private に登録したファイルか、~/dotfiles/flake.nix に足したホストの mkHome
claude.gitViaGh.enable = false;
```

> ⚠️ gh の token に **workflow scope** が無いと、`.github/workflows/` を変える push を
> GitHub が拒否する（`refusing to allow an OAuth App to create or update workflow … without
> 'workflow' scope`）。`gh auth refresh -h github.com -s workflow` で足す。
> scope は自動では足さない（token の権限を広げるかは人が決める）。

#### plugin の marketplace と plugin も https で取る

gitViaGh のマシンでは、`settings.json` の `env` に `CLAUDE_CODE_PLUGIN_PREFER_HTTPS=1` も入れる
（Claude Code の公式の env。[docs の Environment variables](https://code.claude.com/docs/en/env-vars)）。

Claude Code は、source が GitHub（`owner/repo` の形）の marketplace と plugin を git で取る前に、
`ssh -T -o BatchMode=yes -o ConnectTimeout=2 -o StrictHostKeyChecking=yes git@github.com` で鍵が通るかを確かめ、
通れば ssh の URL で、通らなければ https の URL で取る。plugin の自動更新は会話ごとに 1 回、最初の発言から
最大 10 分のどこかで走り、自動更新が on の GitHub の marketplace を取り直すたびにこの確認を打つ。WSL ではその ssh が
`~/.local/bin/ssh` から `ssh.exe` を通るので、1Password の承認が出る（確認は 3 秒で打ち切られる）。

clone と fetch そのものは、上の git の設定ですでに https と gh の token を通っている（`settings.json` の `env` は
Claude Code 自身が打つ git にも届く）。git を通らない確認だけが ssh を直に打つので、`insteadOf` が効かない。
この env があると確認を飛ばし、最初から https の URL で取る。marketplace の追加・更新と、plugin の install・update の
どれにも効く。

- 消えるのは確認（と 1Password の承認）だけで、取れる repo は変わらない。private な repo も、gh の credential helper が
  token を渡すので https で取れる
- https で取れなくても ssh には切り替えない。前提（gh があり、ログイン済み）は上の git の設定と同じで、欠けていれば
  bootstrap が警告する
- helper が gh なのは gitViaGh のマシンだけなので、同じ option に結ぶ。false のマシンでは `env` から消え、
  今までどおり ssh で確かめ、鍵が通れば ssh で取る

Claude Code 2.1.310 で、偽の ssh と偽の gh を PATH の先頭に置き、一時の `CLAUDE_CONFIG_DIR` で `claude plugin marketplace`
を流して確かめた。env なしの add と update は確認を 1 回ずつ打ち、この env があると（シェルの env でも `settings.json` の
`env` でも）1 回も打たなかった。private な repo の add では、`settings.json` の `env` に置いた gh の helper が呼ばれて
clone まで進み、helper を外すと `fatal: unable to get password from user` で clone できなかった（どちらも ssh は呼ばれない）。

起動し直した Claude Code から効く（実行中の会話は、自動更新がまだなら 1 回出ることがある）。

#### 登録（冪等。更新時も毎回走る）

```sh
~/dotfiles/setup --update                 # switch + bootstrap をまとめて
./nix/scripts/bootstrap-claude-env.sh     # env の部分だけ
```

`switch` が望む値を `~/.local/state/dotfiles/claude-env.json` に置き
（`home/modules/claude.nix`）、bootstrap がそれを `~/.claude/settings.json` の `env` へ
git の config を環境変数の形で写す。settings.json は Claude Code 自身が書き換えるので
Nix では置けない（[skill の host option](#claude-code-の-skill-を-host-ごとに止める) と同じ 2 段）。

```json
{
  "managed": [
    "commit.gpgsign",
    "tag.gpgsign",
    "url.https://github.com/.insteadOf",
    "credential.https://github.com.helper"
  ],
  "gitConfig": [
    { "k": "commit.gpgsign", "v": "false" },
    { "k": "tag.gpgsign", "v": "false" },
    { "k": "url.https://github.com/.insteadOf", "v": "git@github.com:" },
    { "k": "url.https://github.com/.insteadOf", "v": "ssh://git@github.com/" },
    { "k": "credential.https://github.com.helper", "v": "!gh auth git-credential" }
  ],
  "managedVars": ["CLAUDE_CODE_SHELL", "CLAUDE_CODE_PLUGIN_PREFER_HTTPS"],
  "vars": {
    "CLAUDE_CODE_SHELL": "/home/pollenjp/.nix-profile/bin/bash",
    "CLAUDE_CODE_PLUGIN_PREFER_HTTPS": "1"
  }
}
```

gitViaGh が false なら `gitConfig` は無署名の 2 組だけになり、`vars` から `CLAUDE_CODE_PLUGIN_PREFER_HTTPS` が消える。
`managed` と `managedVars` は option の値によらず同じ。`CLAUDE_CODE_SHELL` は [Bash tool の shell](#claude-code-の-bash-tool-を-bash-で動かす)
の分で、option によらない。settings.json にはこう入る（true のとき）。

```json
"env": {
  "GIT_CONFIG_COUNT": "5",
  "GIT_CONFIG_KEY_0": "commit.gpgsign",
  "GIT_CONFIG_VALUE_0": "false",
  "GIT_CONFIG_KEY_1": "tag.gpgsign",
  "GIT_CONFIG_VALUE_1": "false",
  "GIT_CONFIG_KEY_2": "url.https://github.com/.insteadOf",
  "GIT_CONFIG_VALUE_2": "git@github.com:",
  "GIT_CONFIG_KEY_3": "url.https://github.com/.insteadOf",
  "GIT_CONFIG_VALUE_3": "ssh://git@github.com/",
  "GIT_CONFIG_KEY_4": "credential.https://github.com.helper",
  "GIT_CONFIG_VALUE_4": "!gh auth git-credential",
  "CLAUDE_CODE_SHELL": "/home/pollenjp/.nix-profile/bin/bash",
  "CLAUDE_CODE_PLUGIN_PREFER_HTTPS": "1"
}
```

git は `GIT_CONFIG_COUNT` / `GIT_CONFIG_KEY_<n>` / `GIT_CONFIG_VALUE_<n>` で渡された
config を **config ファイルより優先する**。そのため効き方がこうなる。

- **Claude のセッション（Bash tool）にだけ効く。** 自分の手元のターミナルからの commit は
  今どおり 1Password で署名され、push も今どおり ssh を通る
- `git commit` 直打ちでも `--amend` でも `rebase --continue` でも `git tag` でも効く。
  「`--no-gpg-sign` を付ける」という指示と違い、忘れる余地が無い

Claude Code 自身も条件によって同じ仕組みで `credential.interactive=false` を注入するが、
**既存の `GIT_CONFIG_COUNT` を読んでその先に足す**実装なので競合しない
（このマシンの Bash tool の env には出ていない。本体に処理があることは確認済み）。

冪等で、`env` の他のキーは保持する。`managed`（と `gitConfig`）のキーを持つ組は
いったん全部外してから `gitConfig` を足し直すので、option を false にすると HTTPS の
3 組が消える。無関係な `GIT_CONFIG_*` の組は順序を保って残し、番号だけ 0 から振り直す
（番号に穴があると git はその手前までしか読まない）。`managedVars`（と `vars`）の名前も
いったん外してから `vars` を足すので、`vars` から外した名前は消える（option を false にすると
`CLAUDE_CODE_PLUGIN_PREFER_HTTPS` が消える）。生成ファイルが無ければ
（この形を置く世代へまだ switch していなければ）警告して飛ばす。`managedVars` と `vars` が
無ければ（`CLAUDE_CODE_SHELL` を足す前の世代）、`GIT_CONFIG_*` だけを書き、switch を促す警告を出す。

**実行中のセッションにも入る**（このマシンでは再起動なしで反映された）。確認は
`env | grep GIT_CONFIG`、または Claude に `git config --get commit.gpgsign`（`false`）と
`git remote get-url --push origin`（gitViaGh なら https）を実行させる。自分のターミナルで
実行すると `true` と ssh の URL のまま。入らなければ再起動する。

この振る舞い（option どおりの書き直し・警告）と状態ファイルの中身は、`nix/tests/` のテストが
flake の `checks` で確かめている（[テスト](#テスト)）。

#### 採らなかった案

無署名:

| 案 | 却下理由 |
| --- | --- |
| `CLAUDE.md` に「`--no-gpg-sign` を付ける」と書く | soft な指示なので忘れうる。全セッションでトークンも食う |
| repo local に `commit.gpgsign false` | 自分の commit も無署名になる。repo ごとに要る |
| `includeIf "gitdir:~/.herdr/worktrees/"` | worktree の外で Claude が commit すると効かず、逆に worktree で自分が commit すると無署名になる |
| `PreToolUse` で `git commit` を deny | 効くが bash 文字列の解析（複合コマンド・クォート）が要る。env で足りる |

GitHub へは HTTPS:

| 案 | 却下理由 |
| --- | --- |
| `CLAUDE.md` に「push は `https://` の URL で」と書く | soft な指示なので忘れうる。skill は素の `git push` を打つ。URL を直に指定する push は `origin/<branch>` を進めない |
| global の git config（home-manager）に `insteadOf` | 自分の push も 1Password の ssh を通らなくなる |
| `pushInsteadOf`（push だけ読み替える） | fetch / pull は ssh.exe を通るまま |
| 空の `credential.helper=` で file 側の helper を消してから gh を足す | Claude Code が空文字の env を渡さないと `GIT_CONFIG_VALUE_<n>` が欠け、git が `unable to parse command-line config` で全部落ちる。今は file 側に helper が無いので要らない（あれば bootstrap が警告する） |
| gh 未ログインなら HTTPS の組を書かない | 結果が option ではなくその時のログイン状態で決まる。警告だけにする |

### Claude Code の Bash tool を bash で動かす

Claude Code の Bash tool は、`settings.json` の `env` の `CLAUDE_CODE_SHELL` が指す shell で動く
（TKT-192）。値は home-manager の profile の bash（`home.profileDirectory` の `bin/bash`。
このマシンなら `/home/pollenjp/.nix-profile/bin/bash`）で、どのマシンでも入れる（host option は無い）。
登録は[上の git の env](#claude-のセッションだけ-git-の設定を変える) と同じ `bootstrap-claude-env.sh` が行い、
`~/dotfiles/setup --update` で入る。

#### なぜ要るのか

Claude Code（2.1.300 で本体のコードを読んで確かめた）は shell をこう選ぶ。

1. `CLAUDE_CODE_SHELL` が bash か zsh を含み、実行できれば（できなければ `<値> --version` が 0 で返れば）それ
2. `$SHELL` が bash か zsh を含めばそれ
3. それ以外（ログインシェルの fish など）は zsh を先に探し（`which zsh`、次に `/bin`・`/usr/bin`・
   `/usr/local/bin`・`/opt/homebrew/bin`）、無ければ bash

ログインシェルが fish で `/usr/bin/zsh` もあるマシンでは、3. で Bash tool が zsh で動く。Claude が書く
script やテストは bash なので、Bash tool で試した結果と本番が食い違う（glob が何にも合わないと zsh は
`no matches found` で止まる、など）。そこで bash にそろえる。

#### 効き方

- `claude`・`claude-<名前>`（`settings.json` を symlink で共有する）・`c` の alias・herdr の `agent start` の
  どれで起動しても、起動した shell によらず効く。`settings.json` の `env` は起動の早い段階で読まれ、shell を
  選ぶより前に入る（`claude -p --settings` に同じ `env` を渡し、Bash tool の中で `BASH_VERSION` が出ることを確かめた）
- Bash tool は最初に snapshot を作る。bash なら `bash -c -l` で `~/.bashrc` を source する（zsh なら `~/.zshrc`）。
  home-manager の `.bashrc` は先頭で非対話なら return するので、alias（`cat=bat`・`grep=rg` など）と
  `initExtra` の関数は Bash tool に入らない
- shell は Claude Code の起動時に決まる。実行中のセッションは、起動し直すまで前の shell のままのことがある
  （plugin の入れ替えで snapshot を作り直すときは選び直す）
- 端末で `CLAUDE_CODE_SHELL=… claude` と渡しても、settings の `env` が後から上書きする（起動時の env に zsh、
  `--settings` の `env` に bash を渡すと bash で動いた）。1 回だけ別の shell で動かすなら
  `claude --settings '{"env":{"CLAUDE_CODE_SHELL":"/usr/bin/zsh"}}'`（`--settings` の `env` は `settings.json` より後に入る）

確認は、起動し直した Claude に `echo "$BASH_VERSION"` を実行させる（bash なら版が出る。zsh なら空）。
起動するときに `--debug` を付けると、ログに `Using shell override: <値>` と `Creating shell snapshot for bash` が出る。

#### 値を profile の bash にする理由

profile のパスは世代を切り替えても変わらず、置き場所とユーザー名は home-manager が決めるので、
マシンが変わっても合う。bash は `programs.bash`（`home/modules/bash.nix`）が profile に入れる
（`programs.bash.package` の既定は `bashInteractive`）。`programs.bash.enable` を false にするか
`programs.bash.package` を null にすると指す先が無くなるので、評価で止める（assertion）。

パスが実行できないとき（switch より前など）、Claude Code はログに出すだけで zsh を探し直すので、
bootstrap が警告し、`setup` の最後の[警告のまとめ](#途中の警告のまとめ)にも出す（env には書く）。

| 値の案 | 却下理由 |
| --- | --- |
| `bash`（PATH で引く） | 起動したときの PATH 次第で `/usr/bin/bash`（5.2）や macOS の `/bin/bash`（3.2）になる。起動のたびに `bash --version` を 1 回起こす |
| Nix store の bash（`${pkgs.bashInteractive}/bin/bash`） | flake.lock を上げるたびにパスが変わり、bootstrap より先に古い世代を GC すると消えて、黙って zsh に戻る |
| `/bin/bash`・`/usr/bin/bash` | NixOS には無く、macOS は bash 3.2 |

#### 置き場所で採らなかった案

| 案 | 却下理由 |
| --- | --- |
| fish の設定や `home.sessionVariables` で export する | fish や login shell を通らない起動（IDE の拡張・デスクトップアプリ・hook や cron からの `claude -p`）に効かない。Claude 以外のプロセスにも漏れる |
| `claude-<名前>` の wrapper で export する | 素の `claude`・`c` の alias・herdr の `agent start` に効かない |
| 新しい状態ファイルと bootstrap を足す | `settings.json` の `env` を 2 つの script が書くことになり、setup の手順も 1 つ増える |

### Claude Code の skill を host ごとに止める

使う skill はマシンごとに違う。例えば会社のマシンでは Notion Dev Tracker の
`pjp-dev-tracker` を発火させたくない。その宣言は host option
**`dotfiles.claude.devTracker.enable`**（既定 false。使うマシンだけ true）に置き、1 つの値から 2 つが決まる。

| 層 | enable = true | enable = false | 決める場所 |
| --- | --- | --- | --- |
| `~/.claude/CLAUDE.md` の「タスク管理」の節 | 末尾に連結（分割前のファイルとバイト単位で同一） | 無し | `home/modules/claude.nix`（`files/claude/CLAUDE.dev-tracker.md` を連結） |
| `~/.claude/settings.json` の `skillOverrides.pjp-dev-tracker` | `"on"` | `"off"`（Claude の一覧からも `/` メニューからも消える） | `bootstrap-claude-skill-overrides.sh` |

2 層とも切るのは、片方だけだと壊れ方が悪いため。節だけ残ると Claude が無い skill を
探しに行き（off の skill を呼ぶと「override を外せ」というエラー文が返る）、skill だけ
残ると節が無くても description で発火する。

#### 値の置き場

- 本体の既定は false（使わない）。**Dev Tracker を使うマシンだけ** `mkHome` に `claude.devTracker.enable = true;` を書く:
  dotfiles-private に登録したファイル、`~/dotfiles/flake.nix` に足したホスト（[前述](#足したホストに書く値)。雛形の `tmp` の例は
  true を書く）。公開の登録簿では検証用の `sandbox` だけが true
- 型のホスト（`--host <型>`）で当てたマシンでは使わない（前は既定が true で、ローカル flake の雛形の `local` が false を書いて
  いた。[ADR 027](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/027_stop_guessing_host_20261021T143517JST/README.md)）

#### 反映（冪等。更新時も毎回走る）

```sh
~/dotfiles/setup --update                            # switch + bootstrap をまとめて
./nix/scripts/bootstrap-claude-skill-overrides.sh    # skillOverrides の部分だけ
```

`switch` が置くのは 2 つ。連結済みの `~/.claude/CLAUDE.md` と、skillOverrides に流す値を
書いた `~/.local/state/dotfiles/claude-skill-overrides.json`（`{"pjp-dev-tracker":"off"}`）。
settings.json は Claude Code 自身が書き換えるので Nix では置けず（フック / statusLine /
env と同じ事情）、この JSON を `bootstrap-claude-skill-overrides.sh` が jq で
`.skillOverrides` へ merge する。

- **`switch` だけでは settings.json に届かない。** CLAUDE.md だけ変わった状態が一時的に
  あり得る。`setup --update` なら bootstrap まで走るので揃う
- 生成 JSON に載っている key（今は `pjp-dev-tracker`）だけ上書きし、他は残す。user の settings.json の
  この key は option が正で、手で書き換えても次の update で戻る。同じ script が書くほかの key（pack の skill・
  claude.ai から同期された skill）は[次節](#skill-の一覧を枠に収める-pack-と同期された-skill)
- `/skills` での切り替えは、その project の `.claude/settings.local.json` に保存され、user の
  settings.json より優先される（公式 docs `skills` の「Override skill visibility from settings」）。
  update では戻らない
- 生成 JSON が無い（option を持つ世代へまだ switch していない）ときは警告して、この key の分だけ飛ばす
- 実行中の Claude Code には効かない。新しい session で `/skills` を見ると状態が判る

#### 確認

```sh
jq .skillOverrides ~/.claude/settings.json      # {"pjp-dev-tracker":"off"} なら止まっている
grep -c 'タスク管理' ~/.claude/CLAUDE.md          # 0 なら節が無い
```

#### 採らなかった案

| 案 | 却下理由 |
| --- | --- |
| SKILL.md の `disable-model-invocation: true` | skill は git で全マシンに配られるので、使うマシンでも止まる |
| `permissions.deny` に `Skill(pjp-dev-tracker)` | 呼ぼうとした時点で止める仕組みなので description は context に残り、毎回発火してから拒否される。rule も settings.json にしか書けず、host ごとの宣言の置き場は解決しない。CLAUDE.md の節も残る |
| `PreToolUse` フックで `Skill` の `pjp-dev-tracker` を deny | 上と同じく反応型。加えて hook script と登録の改修が要る |
| skill 側で印（env）を見て何もしない | 毎回 SKILL.md を読み込む token を払い、降りるかどうかを Claude の判断に委ねる |
| `bootstrap-claude-skills.sh` に除外リストを足して symlink を張らない | skill のファイルまで消えるが、skillOverrides で見えなくなる以上、ファイルの有無まで気にする理由が無い |
| `home.activation` で settings.json を書く | Claude Code 所有のファイルを switch が書くことになり、「Nix 管理か否か」の線が崩れる |
| CLAUDE.md を 1 ファイルのまま Nix でマーカー間を切り抜く | Nix の `builtins.match` は複数行の切り抜きが書きづらく、節を編集したとき黙って壊れうる |

経緯は [ADR 007](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/007_claude_skill_host_option_20260926T130250JST/README.md)。

### skill の一覧を枠に収める (pack と同期された skill)

Claude Code は、使える skill の名前と説明の一覧を毎ターン context に入れる。一覧は context の 1% の枠に収められ、
あふれると呼ばれた回数の少ない skill から説明が落ちる（名前は残る）。説明が落ちた skill は、Claude が呼ぶきっかけを失う。
そこで、どの会話でも要る skill（常駐）と話題ごとの入口の skill（`pjp-pack-<pack>`）だけを説明つきで見せ、話題ごとの
skill の組（pack）は名前だけにする。`bootstrap-claude-skill-overrides.sh` が `~/.claude/settings.json` の
`skillOverrides` に書く（[前節](#claude-code-の-skill-を-host-ごとに止める)の host option の key と同じ script）。

| 書く key | 値 | 何を読んで決めるか |
| --- | --- | --- |
| pack の skill | `"name-only"`（一覧に名前だけ。Skill tool で名前を指せば呼べる） | `~/.claude/skills/*/SKILL.md` の frontmatter の `metadata` の `pjp-pack` と、その pack の入口 `~/.claude/skills/pjp-pack-<pack>/SKILL.md` |
| claude.ai から同期された skill（`anthropic-skills:<名前>`） | `"user-invocable-only"`（Claude の一覧から消え、ユーザーは `/` から呼べる） | `~/.claude/skills/synced/*/` と、`claude-<名前>` のアカウントの `~/.claude-<名前>/skills/synced/*/` の skill のディレクトリ |

- pack の割り当ては、各 skill の `SKILL.md` に書く（`metadata:` の下の `pjp-pack: <pack>`。書き方は
  `nix/files/claude/skills/README.md`）。割り当ての表は持たない。入口の skill（pack の目録）は `claude-skills` にある
- 入口の無い pack の skill は名前だけにしない（呼ぶきっかけが消えるため）。入口が 1 つも無い（`claude-skills` を取れない
  マシン・入口がまだ無い版）なら 1 行出すだけ、ほかの pack の入口はあるのにその pack の入口だけ無いなら警告する
- frontmatter に `disable-model-invocation: true` がある skill も名前だけにしない（入口の目録には載るが、Claude が自分では
  呼ばない作りのまま残す）。前に書いた `name-only` は戻す
- claude.ai から同期された skill は plugin ではなく、Claude Code が `~/.claude/skills/synced/<bucket>/` に同期する skill。
  `enabledPlugins` の `"anthropic-skills@synced": false` では切れない（Claude Code 2.1.316 で確かめた）。名前は同期された
  ディレクトリから読むので、新しいマシンでは Claude Code を一度起こして同期させた後の `setup --update` から効く
- plugin の skill（superpowers など）には `skillOverrides` が効かない（`/skills` で locked by plugin）ので書かない。
  mod を兼ねる skill（`.claude-plugin/plugin.json` がある）も同じ
- 起動中の session には届かない（一覧は session の始めに送られる）。新しい session か `/compact` の後から効く

#### 書いた key の控えと戻し

書いた key と値は `~/.local/state/dotfiles/claude-skill-overrides.applied.json` に控え、流すたびに今の値と比べて決める。

| `settings.json` の今の値 | 書きたい値がある | 書きたい値が無くなった（入口が消えた・pack から外れた・同期された skill が消えた） |
| --- | --- | --- |
| 無い | 書く | — |
| 書きたい値と同じ | 控える（前から手で書いてあった同じ値も控え、あとで戻すことがある） | — |
| 控えた値と同じ | 書きたい値に書き換える | 消す（既定の見え方に戻る） |
| それ以外（手で書いた値） | 触らない（stdout に知らせる） | 触らない |

- 見え方を手で変えるなら、key を消すのではなく別の値（`"on"` など）を書く。消すと次の update で書き直す
- project ごとに変えるなら、その project の `.claude/settings.json`（`/skills` の切り替えは `.claude/settings.local.json`）に
  書く。user の `settings.json` より強い
- 起動のときだけ変えるなら `claude --settings '{"skillOverrides":{"pjp-plantuml":"on"}}'`（skill ごとに user の値より勝つ）

#### 確認

```sh
jq .skillOverrides ~/.claude/settings.json                       # 書いた値
jq .keys ~/.local/state/dotfiles/claude-skill-overrides.applied.json   # この script が書いた key
~/dotfiles/setup --steps bootstrap-claude-skill-overrides        # この手順だけ流し直す
```

経緯と、Claude Code で確かめた振る舞いは dotfiles-private の `docs/superpowers/specs/2026-11-03-skill-listing-packs-design.md`。

### Notion の宛先を host ごとに選ぶ

Notion へ書く skill（`claude-skills` の `pjp-dev-tracker`・`pjp-notion-authoring`・
`pjp-docs-to-notion`・`pjp-scan-to-notion`）の宛先は、**作業中の repo** で決まる（仕事の org の repo は
仕事の workspace、pollenjp の repo は個人の workspace）。規則は private の `claude-skills` の
`skills/pjp-notion-profile/profiles.toml` の `[routes]` にあり、このマシンだけの規則と、
規則に当たらないときの既定を host option で選ぶ。

| 置くもの | 場所 | 例 |
| --- | --- | --- |
| 共通の規則（repo → プロファイル） | `claude-skills` の `profiles.toml` の `[routes]` | `"<仕事の org>/*" = "work"` |
| このマシンだけの規則（共通の規則より先に見る。例: 会社の PC で pollenjp の repo も work に書く） | そのホストの `mkHome` の `claude.notion.routes`（dotfiles-private に登録したファイルか、`~/dotfiles/flake.nix` に足したホスト） | `{ "pollenjp/*" = "work"; }` |
| 規則に当たらない repo と repo の外で使う既定 | 同じく `claude.notion.profile` | `"personal"` / `"work"` |
| このマシンだけの差し替え | 同じく `claude.notion.override` | `{ personal = { scanData = "https://app.notion.com/p/…"; }; }` |
| プロファイルの値（workspace・ページ・DB の id） | `claude-skills` の `profiles.toml` | `[personal.devTracker]` の `hub = "…"` |
| repo にチケットの ID と URL を書くか | `claude-skills` の `profiles.toml`（マシンだけ変えるなら override） | `[work.devTracker]` の `linkFromRepo = false` |
| API キー（そのマシンでそのプロファイルを API キーで使うとき） | `~/.config/pjp/env`（[マシンローカルの環境変数](#マシンローカルの環境変数-configpjpenv)） | `PJP_NOTION_TOKEN_PERSONAL=ntn_…` |

見る順番は、このマシンの `routes` → 共通の `[routes]` → このマシンの `profile`（既定）→ 止まる。
各層の中では `owner/repo` の行が `owner/*` の行に勝つが、層の順番が先なので、
このマシンの `pollenjp/*` は共通の `pollenjp/<repo>` にも勝つ。

値を public なこのリポジトリに書かないのは、ページ名入りの URL が出るため。

`devTracker.linkFromRepo` は、`pjp-dev-tracker` が branch 名・PR・commit にチケットの ID と
Notion の URL を書くかを決める真偽値（書かなければ `true`）。work のプロファイルは `false` にしている。
Dev Tracker が個人の private ページの下にあり、チームの repo に書いても他のメンバーは開けないため。
このマシンだけ変えるなら `claude.notion.override = { work = { devTracker.linkFromRepo = true; }; };`（`mkHome` の引数）。

認証は host option に持たせない。そのマシンに `PJP_NOTION_TOKEN_<名前>`（環境変数か `~/.config/pjp/env`）が
あればその API キー、無ければ workspace ごとの `ntn login` を使う。変数名はプロファイル名を大文字にし
`-` を `_` にする（personal → `PJP_NOTION_TOKEN_PERSONAL`）。

**`NOTION_API_TOKEN` は `~/.config/pjp/env` に書かない。** 環境に `NOTION_API_TOKEN` があれば
（repo の devShell が `.env` を読んだときなど）、repo の規則で決まる認証（`PJP_NOTION_TOKEN_<名前>` か
`ntn login`）を通らず、それが何より先に使われる。シェルは `~/.config/pjp/env` を環境へ読み込むので、
書くとどの repo でもそれが勝つ。

#### 値の置き場

dotfiles-private に登録したファイルか、`~/dotfiles/flake.nix` に足したホストの `mkHome` に書く。

```nix
claude = {
  notion.profile = "personal";  # 規則に当たらない repo と repo の外
  # このマシンだけの規則 (例: 会社の PC で pollenjp の repo も work に書く):
  #   notion.routes = { "pollenjp/*" = "work"; };
  # このマシンだけプロファイルの値を差し替える (外側はプロファイルの名前。null はキーを消す):
  #   notion.override = { personal = { scanData = "https://app.notion.com/p/…"; }; };
};
```

#### 反映

`switch` が `~/.local/state/dotfiles/claude-notion.json` を置き、`claude-skills` の resolver が
それを `profiles.toml` と重ねる。settings.json は触らないので
`switch` だけで揃う（`~/dotfiles/setup --update` でもよい）。

JSON の中身は、上の例（`profile` だけ）なら `{"override":{},"profile":"personal","routes":{}}`。
`routes` のコメントを外すと `"routes":{"pollenjp/*":"work"}` になる。

- profile が `null`（本体の既定）のマシンでは、規則に当たらない repo と repo の外で skill が「宛先が決まらない」と止まる。
  黙って別の workspace へ書かないため
- `routes`（キーと値）と `override`（キー）の綴りは Nix では検査しない。skill が使うときに resolver が止める
- `devTracker.enable = true` なのに profile が無いマシンでは、switch のときに警告が出る
  （`home/modules/claude.nix` の `warnings`）。ticket.sh が止まるのに気付けるように
- 古い形の override（`override = { devTracker.linkFromRepo = …; };` のように、外側がキーの名前）が
  残るマシンでも、switch のときに警告は出ない。skill を使った最初に resolver が
  書き直し方（`{ <プロファイル名> = { … }; }`）を出して止まるので、更新するときに書き直しておく

#### 確認

宛先は cwd の repo で決まるので、`show` と `check` は確かめたい repo の中で打つ
（別の場所からは `--cwd <repo のディレクトリ>` を付ける。repo の外ではこのマシンの既定で決まる）。

```sh
cat ~/.local/state/dotfiles/claude-notion.json
~/.claude/skills/pjp-notion-profile/scripts/notion-profile.sh show    # 解決後の値と、どの規則で決まったか
~/.claude/skills/pjp-notion-profile/scripts/notion-profile.sh check   # ntn の workspace と合うか
```

経緯は [ADR 011](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/011_claude_notion_profile_20260929T155545JST/README.md)（プロファイル）と [ADR 014](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/014_claude_notion_routes_20261010T014639JST/README.md)（repo ごとに決める）。

### 重い処理の資源の上限を host ごとに決める

重い処理（数分以上 CPU を使い切るか、GB 単位でメモリを取る処理。動画の書き出し・エンコード、コマや画像をまとめて読む処理、
whisper などの推論、重い処理を並べて流すとき）は、`claude-skills` の skill `pjp-heavy-jobs` の `scripts/limit.sh` で包んで流す。
limit.sh は包んだコマンドを systemd の user slice `pjp-heavy.slice` に入れ、slice に CPU とメモリの上限を付ける。上限は slice の
中の合計に効くので、別々の会話（herdr の pane ごとの会話とその subagent）が同時に重い処理を流しても、合わせて上限の内に収まる。
どれを包むかはその skill の `SKILL.md` が決める（動画の雛形の `render-all.sh` などは自分で包む）。縛るのは包んだ処理だけ。

上限の割合は host option **`dotfiles.claude.heavyJobs.limitPercent`**（整数 1〜100、既定 70）で決める。home-manager が値を
`~/.local/state/dotfiles/claude-heavy-jobs.json`（`{"limitPercent":70}`）に置き、limit.sh が包むたびに読む
（[ADR 043](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/043_claude_heavy_jobs_limit_host_option_20261107T222147JST/README.md)）。

| 縛るもの | 上限 |
| --- | --- |
| CPU | `CPUQuota` = 割合 × `nproc`（systemd は CPU 1 つを 100% と数える）。WSL の `nproc` は、既定では Windows の論理 CPU の全部 |
| メモリ | `MemoryMax=<割合>%`（kernel から見えるメモリに対して）。WSL では VM のメモリに対してで、VM のメモリは既定で Windows の半分ほど（40 なら PC 全体の約 20%） |
| swap | 使わせない（`MemorySwapMax=0`） |

#### 値の置き場

dotfiles-private に登録したファイルか、`~/dotfiles/flake.nix` に足したホストの `mkHome` に書く。書かなければ 70。

```nix
claude = {
  heavyJobs.limitPercent = 40;  # 重い処理に使わせるのを、マシン全体の 40% までにする
};
```

#### 反映と確認

反映は `home-manager switch`（`~/dotfiles/setup --update` でもよい）。上限は、次に包むときに limit.sh が付け直す
（`systemctl --user set-property --runtime`。再起動で消えるが、包むたびに付ける）。skill の link
（`~/.claude/skills/pjp-heavy-jobs`）は、`setup --update` の手順 `bootstrap-claude-skills` が張る。

- ファイルが無い・読めないマシン（この option より前の dotfiles など）では、limit.sh は 70 で縛る
- `claude-skills` を取れないマシンには limit.sh が無いので、上限は付かない
- cgroup v2 の `cpu`・`memory` が systemd の user manager に委譲されていないマシンでは、その分の上限は付かない
  （limit.sh が警告を 1 行出し、CPU は `nice` で流す）。systemd 251 以前（Ubuntu 22.04 の 249 など）の user manager は
  `memory` だけを委譲する

```sh
cat ~/.local/state/dotfiles/claude-heavy-jobs.json   # {"limitPercent":70}
stat -fc %T /sys/fs/cgroup                            # cgroup2fs なら cgroup v2
cat /sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/cgroup.controllers   # cpu と memory があれば両方に効く
systemctl --user show pjp-heavy.slice -p CPUQuotaPerSecUSec -p MemoryMax   # 包んで流した後に、付いた上限
```

### Claude Code のアカウントを分ける (claude-personal / claude-work)

ログインするアカウントを明示したいときだけ、素の `claude` の代わりに次を使う。
**分かれるのはログインだけ**で、CLAUDE.md・skill・フック・設定・履歴と memory は
素の `claude` と同じものが効く。素の `claude` と `~/.claude` は今まで通り。

| コマンド | 使う config dir | ログイン |
| --- | --- | --- |
| `claude` | `~/.claude`（今まで通り） | 今まで通り |
| `claude-personal` | `~/.claude-personal` | 個人のアカウント（初回に `/login`） |
| `claude-work` | `~/.claude-work` | 会社のアカウント（初回に `/login`） |

どちらも `ANTHROPIC_API_KEY`・`CLAUDE_CODE_OAUTH_TOKEN`・`ANTHROPIC_AUTH_TOKEN`（`/login` の
資格情報より優先される env）を外し、`CLAUDE_CONFIG_DIR` をその dir にして `claude` を exec する。
`home/modules/claude.nix` が `writeShellApplication` で作るので PATH にあり、bash / fish の
どちらからも、シェルを通さない起動元からも呼べる（`claude` が PATH に無ければ
`mise which claude` で探す）。どのマシンにも両方ある。

#### `~/.claude-<名前>/` の中身

`bootstrap-claude-accounts.sh` が用意する（冪等。更新時も毎回走る）。

| もの | 扱い |
| --- | --- |
| `CLAUDE.md`・`settings.json`・`projects` | `~/.claude` への 1 段の symlink（共有） |
| `skills/` | 実体の dir。`~/.claude/skills/` の中の **symlink と、実体でも `pjp-*` のもの**を同名のリンクで写す |
| `agents/`・`commands/` | 実体の dir。`~/.claude/<種類>/` の中身を同名のリンクで写す（`synced` を除く） |
| `plugins/` | 実体。`settings.json` の `enabledPlugins` のうち未導入のものを入れる（版は上げない） |
| `.credentials.json`・`.claude.json` など | 実体。`/login` と起動のときに Claude Code が作る |

- `hooks/` と `statusline-command.sh` は置かない。`settings.json` が `~/.claude/…` の
  絶対パスで登録しているので、それだけで効く
- `skills/` を丸ごと共有しないのは、`synced/` にアカウントごとの配信 skill が入るため
  （古い版の Claude Code は `pdf/` などを直下に実体で置く）。Nix と claude-skills が置くものは
  symlink、自作の試作は命名規約どおり `pjp-*` なので、その 2 つだけを写す
- `plugins/` を共有しないのは、別の config dir から symlink 越しに使うと cache に
  `unknown` 版のコピーができるため。plugin は `~/.claude` 自身にも揃える（薄い dir で
  入れた plugin も共有の `enabledPlugins` に載るため）。外した plugin は消さない
- marketplace を足すと、Claude Code がリンク越しに共有の `settings.json` の
  `extraKnownMarketplaces` へ 1 項目書く
- リンクを `home.file` で張らないのは、store を経由する 2 段のリンクになり、Claude Code が
  `settings.json` に書けなくなるため（readlink を 1 回しか辿らない）
- 薄い dir か `skills/` などが `~/.claude` へのリンクになっている（または `~/.claude` が
  薄い dir へのリンクになっている）と、張ったリンクが自分自身を指して `~/.claude` を壊すので、
  そのアカウント・その種類は飛ばして警告する
- アカウントの一覧は `claude.nix` の `accounts` にだけある。`switch` がそこから
  `~/.local/state/dotfiles/claude-accounts.json`（`["personal","work"]`）を置き、
  script はそれを読む

#### 使い始める

```sh
~/dotfiles/setup --update                   # switch + bootstrap
ls -l ~/.claude-personal ~/.claude-work     # CLAUDE.md / settings.json / projects がリンク

claude-personal                             # 初回は /login で個人のアカウント
claude-work                                 # 初回は /login で会社のアカウント
```

どのアカウントで動いているかは各セッションの `/status` で確かめる。
`~/.claude` には触らないので、動いているセッションはそのままでよい。

#### 既に `~/.claude-<名前>` があるとき

`CLAUDE_CONFIG_DIR=~/.claude-work claude` のように先に起動していると、Claude Code が
`settings.json` や `projects/` を実体で作っている。bootstrap は実体を上書きしないので
（`!!` で知らせる）、コマンドも「実ファイルです」と言って起動しない。片付けてから流し直す。

```sh
jq -S . ~/.claude-work/settings.json       # 残したい設定は ~/.claude/settings.json へ移す
rm ~/.claude-work/settings.json

# projects/ は ~/.claude/projects へ寄せる (同じ名前のファイルは上書きしない)
cp -Rpn ~/.claude-work/projects/. ~/.claude/projects/ && rm -rf ~/.claude-work/projects

~/dotfiles/setup --steps bootstrap-claude-accounts
```

`~/.claude-personal` なら dir を読み替える（bash でも fish でもそのまま打てる形にしてある）。
ログイン（`.credentials.json`・`.claude.json`）と `plugins/` はそのまま残してよいので、
`/login` し直す必要は無い。

#### 注意

- **bootstrap より先に起動しない。** コマンドは `settings.json` がリンクになっていなければ
  止まって手順を案内する。Claude Code に空の dir を作らせないため
- アカウントごとに分かれるもの: `.claude.json`（リポジトリごとの「信頼する」の確認・
  MCP サーバーの設定）、↑ キーの入力履歴（`history.jsonl`）、巻き戻し（`file-history/`）、
  `plugins/`（容量は dir の数だけ要る）、`skills/synced/`
- 薄い dir の中で作ったもの（`/agents` で作った agent、`~/.claude-<名前>/skills/` に置いた
  試作）はその dir にしか無い。どれでも使いたいものは `~/.claude` 側に置く（skill は `pjp-*`）
- 共有の `settings.json` にある設定（`apiKeyHelper` や `model` など）はどのアカウントにも効く
- `~/.claude` に skill を足した・消したあと、薄い dir が追従するのは次の `setup --update`
  （または `--steps bootstrap-claude-accounts`）から
- marketplace の clone は SSH なので、初回は dir ごとに 1Password の承認が出ることがある
- `claude-work` のセッションの中（Bash ツールなど）で素の `claude` を打つと
  `CLAUDE_CONFIG_DIR` が引き継がれて work で起動する（`bootstrap-claude-plugins.sh` は
  これを外してから `~/.claude` へ入れる）

経緯と、採らなかった案（`~/.claude` をリンクにする、3 つの dir に一式を配る、など）は
[ADR 009](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/009_claude_account_config_dirs_20260927T161411JST/README.md)。

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
├── herdr              -> /nix/store/…-herdr-…/share/skills/… (パッケージ同梱。claude.nix)
└── <private>          -> ~/ghq/…/claude-skills/skills/…     (bootstrap-claude-skills.sh)
```

`nix/files/claude/` と同じく **中身を 1 つずつ**置く方式なので、4 系統が兄弟として
並ぶだけで衝突しない。同名のものが既にある場合は上書きせず警告して飛ばす。

#### 取得できないマシンでも止まらない

dotfiles は public なので、claude-skills を取れないマシン（鍵がまだ無い、メンバー
ではない、オフライン）でも setup を通したい。そのため**取得の失敗はエラーにせず、
警告を出して exit 0 する**。`setup.sh` は手順が 1 つでも失敗すると残りを走らせないので、
ここで落ちると後続の `bootstrap-*` まで巻き添えになる。

| 状況 | 挙動 |
| --- | --- |
| clone できない（鍵が無い / オフライン / `git` が無い） | `~/.claude/` には触らず、警告して終了 |
| clone はあるが取得できない（鍵が無い / オフライン） | 手元のクローンの内容でリンクを張り直し、警告を添える |
| 取得できたが fast-forward できない（履歴の分岐） | 同じ（ssh で取り直さない） |

取得できなかったときにリンクを**消しにいかない**のは重要で、掃除は「リンク先が
クローンの中を指しているか」で判定するため、クローンが無い状態で prune すると
別マシンで張ったリンクを全部消してしまう。

鍵が無いマシンで対話プロンプト（`known_hosts` の確認など）に固まらないよう、
`GIT_TERMINAL_PROMPT=0` と `ssh -o BatchMode=yes` で即座に失敗させている。
`dotfiles.claude.gitViaGh.enable` のマシンでは、clone も取得も gh の資格情報で先に試す
（[setup の取得も gh で先に試す](#setup-の取得も-gh-で先に試す)）。

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

### herdr の集約ハブ (`~/h`)

`~/h` は、herdr で子の Claude を回す集約（指揮役）の会話の受け口（ハブ）。コードを持たない git repo（remote なし）で、
決まりのファイル（`CLAUDE.md`・`.claude/settings.json`・`.gitignore`）の雛形と、それを写す `hub-init.sh` は
claude-skills（private）の skill `pjp-herdr-hub` にある。ハブでの会話の決まりも、その skill の側に書いてある。

**`~/h` を作るのは `setup` の `bootstrap-herdr-hub.sh`。** claude-skills の skill を張る `bootstrap-claude-skills.sh` の後
（`order: 60`。[前述](#bootstrap-の実行順)）に、`~/.claude/skills/pjp-herdr-hub/scripts/hub-init.sh` を引数なしで
（既定の `~/h` に）打つ。

```sh
~/dotfiles/setup --steps bootstrap-herdr-hub                 # この手順だけ流す
~/.claude/skills/pjp-herdr-hub/scripts/hub-init.sh --check   # 書かずに雛形との差を見る (差があれば終了コード 1)
```

- 「新しいマシン適用」と「既存マシン更新」の両方に入る。`hub-init.sh` は打ち直しても雛形との差だけを直す（差が無ければ
  何もしない）ので、claude-skills の雛形が新しくなったときも `--update` で `~/h` に入る（同じ実行の中で、先に
  `bootstrap-claude-skills.sh` が claude-skills を進める）
- `~/h` の `CLAUDE.md` などを手で直しても、次の `--update` で雛形に戻る。直すなら claude-skills の雛形を直す
- 作り済みの worktree（`~/.herdr/worktrees/h/…`）の `CLAUDE.md` などは直さない（`hub-init.sh` の決まり。雛形の変更は、
  これから切る worktree から効く）
- `hub-init.sh` も雛形も private な claude-skills の作業クローンにあるので、Nix（`home.activation`）では作らない
  （[なぜ flake input にしないのか](#なぜ-flake-input-にしないのか)と同じ理由）

#### 作れなくても止まらない

`setup.sh` は手順が 1 つ失敗すると残りを走らせないので、ここでは止めない（止めると後ろの `bootstrap-windows-*` などまで
巻き添えになる）。

| 状況 | 挙動 |
| --- | --- |
| `pjp-herdr-hub` が無く、claude-skills も使っていない（claude-skills を取れないマシン） | 1 行出して通す。警告はしない（取れないことは `bootstrap-claude-skills` が警告する） |
| claude-skills の clone はあるのに `pjp-herdr-hub` が無い・リンクが切れている | 警告して通す（clone が古いか、claude-skills の側で skill の名前が変わった・消えた。黙ると `~/h` が作られなくなったことに気付けない） |
| `pjp-herdr-hub` はあるのに `hub-init.sh` が無い | 警告して通す（skill の中で名前か場所が変わったら、`bootstrap-herdr-hub.sh` を合わせる） |
| `hub-init.sh` が 0 以外で終わった | `hub-init.sh` の出力ごと警告し（最後の[警告のまとめ](#途中の警告のまとめ)にも載る）、`setup` は続ける。直してから上の `--steps` で流し直す |

clone があるかは、`bootstrap-claude-skills.sh` が控えた場所（`~/.local/state/dotfiles/claude-skills-dir`。
[掃除の判定](#掃除の判定)）が git の clone かで見る。`hub-init.sh` が止まる条件（`~/h` が別の repo の中、まだハブでないのに
雛形の外のものがある、など。止まるときは何も書かない）は `hub-init.sh` の先頭のコメントにある。git の commit に失敗した
（名前とメールが無いなど）ときも 0 以外で終わる（ファイルは写したまま。直して流し直せば commit する）。

### チケットのコメントをハブの会話へ届ける見回り役 (`pjp-dev-tracker-inbox`)

Dev Tracker のハブのチケットのページにコメントを書くと、そのチケットの会話（herdr の pane で動く `~/h` の worktree の
Claude）の入力欄へ、端末で打った発言として届く。外出先のスマホから回答待ちのチケットに答える、並行に動く会話を Notion で
見て指示を出す、といった使い方のためのもの（TKT-302）。見回り役の本体は claude-skills（private）の `pjp-dev-tracker` の
`ticket.sh inbox` で、30 秒ごとにコメントを読んで `herdr agent prompt` で打つ。どのコメントを拾うか・会話の側でどう扱うかは、
その skill の側に書いてある。

ここで受け持つのは常駐だけで、systemd の user service `pjp-dev-tracker-inbox` にする（Linux だけ）。

| 段 | すること | 決める場所 |
| --- | --- | --- |
| `switch` | `~/.config/systemd/user/pjp-dev-tracker-inbox.service`（`~/.claude/skills/pjp-dev-tracker/scripts/ticket.sh inbox` を cwd `~/h` で常駐させる）を置き、起こす | `home/modules/dev-tracker-inbox.nix` |
| bootstrap | claude-skills を進めた後に `reset-failed` して `restart` する（止まっていれば起こし、動いていれば新しいコードで上げ直す）。3 秒のうちに止まったら journal の末尾を、起動の条件が揃わなければ無いものを添えて警告する | `scripts/bootstrap-dev-tracker-inbox.sh` |

claude-skills を進めても unit ファイルは変わらないので、`switch` だけでは見回り役は再起動しない（動いていれば古いコードの
まま）。`--update` では `switch` が claude-skills の更新より先に走るので、起こし直しは bootstrap（`order: 70`）が受け持つ。

#### 使うホストだけ有効にする

既定では置かない。herdr でハブの会話を回すホストの `mkHome`（dotfiles-private に登録したファイルか、`~/dotfiles/flake.nix` に
足した tmp）で有効にし、`~/dotfiles/setup --update` で効かせる。`devTracker.enable` が false のホストで true にすると評価で止まる。

```nix
claude = {
  devTracker = {
    enable = true;
    inbox.enable = true;
  };
  notion.profile = "personal";
};
```

見回り役は自分のマシンに worktree の無いチケットを読まないので、同じ Dev Tracker を複数のホストで見回っても、互いの会話の
チケットには書かない。それでも `devTracker.enable` とは別の option にしてあるのは、プロファイルにユーザーの Notion の id
（claude-skills の `profiles.toml` の `user.id`。今は personal にだけある）が無いホストでは終了コード 2 で止まったままになり、
ハブの会話を回さないホストでは 30 秒ごとに Notion を引くだけになるため。

#### 状態を確かめる

```sh
systemctl --user status pjp-dev-tracker-inbox             # active (running) か
journalctl --user -u pjp-dev-tracker-inbox -f             # 見回りのログ (何もしなかった見回りは出さない)
systemctl --user show pjp-dev-tracker-inbox -p ActiveEnterTimestamp -p NRestarts   # いつから動いているか・落ちて起こし直した回数
~/dotfiles/setup --steps bootstrap-dev-tracker-inbox      # 起こし直す (claude-skills を手で pull した後・設定を直した後)
```

| 状況 | 挙動 |
| --- | --- |
| `ticket.sh`（claude-skills）か `~/h` が無い | 条件不成立としてスキップする（failed で残らない）。使うと決めたホストなので、`bootstrap-dev-tracker-inbox` がどちらが無いかと直し方を警告する |
| 終了コード 2（ユーザーの Notion の id が無いなど設定の誤り、`inbox` の無い古い `ticket.sh`） | failed のまま再起動しない。`bootstrap-dev-tracker-inbox` は今回の起動の journal の末尾を添えて警告する。直してから上の `--steps` で起こし直す。failed の間は user の systemd が degraded になり、`switch` のたびに「The user systemd session is degraded」とこの unit が出る |
| 2 以外で落ちた | 30 秒おいて起こし直す。10 分に 5 回起こしたら諦めて failed になる（上の `--steps` で数え直して起こす） |
| 1 回の見回りの失敗（ntn・herdr の一時的な失敗） | 本体が journal に出して次の見回りへ進む（終わらない） |

claude-skills の `inbox` が入る前に dotfiles を switch しても、`ticket.sh` が知らないサブコマンドを終了コード 2 で断るので、
再起動を繰り返さずに止まって待つ。claude-skills が進んだ後の `--update` で bootstrap が起こす。

Notion の API キーは `ticket.sh` が自分で `~/.config/pjp/env` から読む（[Notion の宛先を host ごとに選ぶ](#notion-の宛先を-host-ごとに選ぶ)）。
unit の環境変数では渡さないので、キーを足した・替えたときに unit は直さなくてよい（動いている見回り役に読み直させるなら
`systemctl --user restart pjp-dev-tracker-inbox`）。

#### SSH を全部切っても止まらない（linger は要らない）

このユーザーは linger しない（`loginctl show-user` の `Linger=no`）が、herdr の server が動いている間は見回り役も止まらない。
logind は `KillUserProcesses=no` なので、SSH を切っても server の残る login session は closing のまま残り、その session が
user manager（`user@<uid>.service`）とその上の user service を生かす。2026-10-21 に GCP の VM で、SSH が 1 本も無い
10 時間あまり（12:51〜23:35 UTC）の間、同じ形の常駐の `cc-pages.service` が止まらなかったのを journal で確かめた（TKT-306）。

```sh
loginctl list-sessions                         # herdr の server の session が closing で残っている
systemctl --user show pjp-dev-tracker-inbox -p ActiveEnterTimestamp -p NRestarts
                                               # SSH で入り直したとき、切る前と同じ時刻なら、切っている間も動いていた
```

止まるのは herdr の server が落ちて SSH も 1 本も無いときだけで、その間は届ける先の会話も無い。次に SSH で入ると user manager と
ともに上がり、止まっていた間のコメントも拾う。マシンの再起動の後、ログインする前から返事（「会話が止まっています」）まで
させたいときだけ `sudo loginctl enable-linger "$USER"` を打つ（今は要らない）。

### 長い応答を読む web ビューア (cc-pages)

[`pollenjp/cc-pages`](https://github.com/pollenjp/cc-pages)（private）は、Claude Code の長い応答を HTML のページとして
手元に残し、ブラウザで読むためのツール。skill の `pjp-cc-page`（claude-skills 側）が `cc-pages new` でページを書き、
常駐する daemon（`cc-pages serve`）が `http://localhost:7777` で見せる。

claude-skills と同じく private なので、**バイナリは Nix ではなく `bootstrap-cc-pages.sh` が置く**。
Nix が置くのは daemon の unit だけ。

| 段 | すること | 決める場所 |
| --- | --- | --- |
| `switch` | `~/.config/systemd/user/cc-pages.service`（`~/bin/cc-pages serve` を常駐させる）を置く。`dotfiles.ccPages.port` を選んだマシンには `~/.config/cc-pages/config.toml` も置く | `home/modules/cc-pages.nix` |
| bootstrap | `$(ghq root)/github.com/pollenjp/cc-pages` へ clone（あれば取得して fast-forward）→ `go build` して `~/bin/cc-pages` へ symlink → unit を enable して再起動 | `scripts/bootstrap-cc-pages.sh` |

```sh
./nix/scripts/bootstrap-cc-pages.sh            # 取得 / 更新してビルドし、daemon を再起動する
./nix/scripts/bootstrap-cc-pages.sh --no-pull  # pull せず、手元のクローンでビルドし直す
./nix/scripts/bootstrap-cc-pages.sh --status   # いまの状態 (クローン・バイナリ・daemon・ビューアの URL) を見る
systemctl --user status cc-pages               # daemon の状態
```

- 冪等なので `--update` のたびに走り、cc-pages の更新もこれで入る
- 待ち受けとデータの置き場は、既定で `127.0.0.1:7777` と `~/.local/share/cc-pages`。port はローカル flake で
  変える（[待ち受けの port を変える](#待ち受けの-port-を変える)）
- clone 先は `--dir` → `$CC_PAGES_DIR` → `$(ghq root)/github.com/pollenjp/cc-pages` の順に決まる
- ビルドに使う `go` は `bootstrap-mise.sh`（order 10）が入れる
- daemon を起こすのは Linux の user の systemd だけ。darwin には launchd の agent を置いていないので、
  バイナリは作るが常駐はしない
- `cc-pages` が PATH（`~/bin`）に無いマシンでは、skill はページを作らずにターミナルで答える
- 会話のトップページの「リンク」の節には、Stop フックが会話に出たリンクを全部残す（footer の 5 枠から溢れたものも）。status line の
  先頭の `📄top` から開ける（[溢れたリンクを会話のトップページに残す](#溢れたリンクを会話のトップページに残す)）

#### 待ち受けの port を変える

7777 がほかと衝突するマシンでは、そのホストの `mkHome` の `modules`（dotfiles-private に登録したファイルか、
`~/dotfiles/flake.nix` に足したホスト）で port を選ぶ。

```nix
modules = [
  {
    dotfiles.ccPages.port = 7778;
  }
];
```

`~/dotfiles/setup --update`（switch だけでもよい）で効く。home-manager が `~/.config/cc-pages/config.toml` に
`addr = "127.0.0.1:7778"` を書き、port が変わった switch で `cc-pages.service` を再起動する。
bind 先の `127.0.0.1` は変えない（LAN には出さない）。

- daemon（`cc-pages serve`）も、skill がページを作る `cc-pages new`（返すリンク）も、この config.toml を読む。
  unit の環境変数（`CC_PAGES_ADDR`）で渡さないのは、`cc-pages new` に届かずリンクが 7777 のまま残るため
- 書かなければ（既定の `null`）config.toml は置かず、cc-pages の既定の 7777 で待ち受ける
- port を書いたマシンでは config.toml を home-manager が持つ。手で書いた config.toml があると switch が
  「既にファイルがある」で止まるので、退けてから switch する
- port を変える前に作ったページのリンク（`http://localhost:7777/…`）は開けなくなる。ページそのものは
  `~/.local/share/cc-pages` に残っている
- いまの URL は `bootstrap-cc-pages.sh --status` の「ビューア」に出る（config.toml の `addr` から組む）
- Claude Code の footer の cc-page のバッジも、この port のページだけを拾う
  （[footer に会話のチケットと PR と cc-page のリンクを出す](#footer-に会話のチケットと-pr-と-cc-page-のリンクを出す)）。
  `--update` なら規則も続けて新しい port になる。switch だけのときは `bootstrap-claude-footer-links.sh` を打つ
- status line の先頭の `📄top` も、この port の `/s/<session_id>/` を指す（switch で変わる。[statusLine](#statusline)）

#### 取得できないマシンでも止まらない

claude-skills と同じく、**取得やビルドの失敗はエラーにせず、警告を出して exit 0 する**。

| 状況 | 挙動 |
| --- | --- |
| clone できない（鍵が無い / オフライン） | `~/bin` にも systemd にも触らず、ビューア無しで続ける |
| clone はあるが取得できない（鍵が無い / オフライン） | 手元のクローンの内容でビルドする |
| 取得できたが fast-forward できない（履歴の分岐） | 同じ（ssh で取り直さない） |
| `go` が無い / ビルドに失敗する | daemon は起こさない |
| user の systemd が無い / unit がまだ無い | バイナリだけ置き、daemon は起こさない（手で動かすなら `~/bin/cc-pages serve`） |

unit は `ConditionFileIsExecutable=%h/bin/cc-pages` でバイナリの有無を見る。バイナリが無いマシンでも
`cc-pages.service` が failed で残らず、条件不成立として静かに飛ばされる。

flake input にしない理由も claude-skills と同じ（[前述](#なぜ-flake-input-にしないのか)）。
gitViaGh のマシンで gh の資格情報を先に試すのも同じ（[setup の取得も gh で先に試す](#setup-の取得も-gh-で先に試す)）。

### Claude Code on the web (cloud) で使う

cloud の session は毎回新しい VM で動き、ここまでの `~/.claude/`（home-manager が配るもの・bootstrap が `settings.json` に
書くもの）は届かない（[ADR 034](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/034_claude_cloud_bootstrap_20261025T134343JST/README.md)）。専用の cloud 環境の
setup script から `nix/scripts/claude-cloud/bootstrap-claude-cloud.sh` を呼び、VM の `~/.claude/` に組み立てる。
`nix/scripts/claude-cloud/` には cloud でしか読まないものだけを置く（`setup` は `nix/scripts/` の直下の `bootstrap-*.sh` だけを
手順にするので、手元では走らない）。

| 組み立てるもの | 中身 |
| --- | --- |
| `~/.claude/skills/` など | dotfiles の `nix/files/claude/` と claude-skills の中身への symlink（手元と同じ単位）。mod を兼ねる skill・`claude-cloud/skip-skills.txt` の skill・（`--dev-tracker` でなければ）`pjp-dev-tracker` は張らない |
| `~/.claude/CLAUDE.md` | 共通の `CLAUDE.md` の最初の `## ` の行より前を `claude-cloud/CLAUDE.cloud.md` に差し替えたもの（`--dev-tracker` なら「タスク管理」の節も足す） |
| `~/.claude/hooks/` と `settings.json` | xref-guard・run-through-nudge・video-offer-nudge・docs-guard・gist-guard を `bash <パス>` で登録する。SessionStart に自分を `--quiet` で登録し、session ごとに張り直す |
| `settings.json` の `skillOverrides` | pack の skill を `name-only`、claude.ai から同期された skill を `user-invocable-only` にする（手元と同じ `nix/scripts/bootstrap-claude-skill-overrides.sh` を `--no-host-option` で流す。[前述](#skill-の一覧を枠に収める-pack-と同期された-skill)） |
| `~/.local/state/dotfiles/claude-notion.json` | `profile` は `--notion-profile` の値 |

git の設定と `settings.json` の `env` には触らない（cloud の git の proxy と commit の署名を壊すため）。plugin は claude.ai で
有効にすると同期される。

#### 環境を作る

claude.ai/code の環境の設定（[手順](https://code.claude.com/docs/en/cloud-environments#configure-your-environment)）で:

1. 専用の環境を作る（Default の環境には Repositories の欄が無い）
2. **Repositories** に `pollenjp/dotfiles` と `pollenjp/claude-skills` を足す（setup script が private な repo を読むのに要る）。
   dotfiles の設計の文書も書くなら `pollenjp/dotfiles-private` も足す（置き場は dotfiles-private の `docs/`。直下の `CLAUDE.md`）
3. **Network access** の Allowed domains に `ntn.dev`（ntn の install script）・`api.notion.com`・`developers.notion.com`（ntn が
   Notion-Version を決めるのに OpenAPI を取る）を足す。既定の一覧を含めるチェックは付けたまま
4. Notion の token を渡す（下の表）
5. **Setup script** に次を書く

```bash
#!/bin/bash
curl -fsSL https://ntn.dev | bash || true
bash dotfiles/nix/scripts/claude-cloud/bootstrap-claude-cloud.sh --notion-profile personal || true
```

手元では ntn を Nix で版を固定して入れる（[後述](#ntn-notion-cli-を-nix-で入れる)）が、cloud の VM は home-manager を通らないので、
ntn は 1 行目の install script で入れる（版はその時の最新）。

| token の渡し方 | 設定 |
| --- | --- |
| Network secret（勧める） | host `api.notion.com`・Bearer・値に token。加えて環境変数に `PJP_NOTION_TOKEN_PERSONAL=proxy-injected`（resolver に API キーで認証させるための中身の無い値。本物は proxy が VM の外で付ける） |
| 環境変数 | `PJP_NOTION_TOKEN_PERSONAL=ntn_…`（その環境を使う人と、VM で動く全コマンドから読める） |

`--dev-tracker` は token を渡してから setup script に足す（token の無い環境で、作業のたびにチケットを切りに行って失敗しないように）。

#### 確かめる

新しい session で:

- `/context` の Memory files に `/root/.claude/CLAUDE.md` が出る
- skill の一覧に `pjp-` で始まるものが出る
- token を渡したなら `~/.claude/skills/pjp-notion-profile/scripts/notion-profile.sh check` が通る
- hook が効く（public な repo に、ほかの repo の参照を書いた commit を push しようとすると xref-guard が止める）。VM の
  `settings.json` に書いた hook が効くかはまだ確かめていないので、効かなければ ADR 034 に書き足す

#### 制約

- setup script は環境の snapshot を作るときにしか走らない（setup script か Allowed domains を変えたとき・約 7 日ごと）。その
  あとに claude-skills に足した skill は、SessionStart の hook が張る
- claude.ai から同期された skill は、Claude Code が session を起こすときに同期するので、setup script の時点では名前が読めず
  `skillOverrides` に書けない。SessionStart の hook が流し直したときに書くが、その session の一覧に間に合うかは確かめていない
  （間に合わなければ、cloud では同期された skill が説明つきのまま一覧に載る）
- 環境変数を変えても、動いている session には VM が戻る（起動し直す）まで届かない
- 1 つの環境で `api.notion.com` に付けられる Network secret は 1 つ（proxy は host で付ける）。personal と work は環境を分ける
- cloud の GitHub proxy は GraphQL を断る。pjp-dev-tracker の `gh pr view`・`gh pr list`・`gh pr edit` を使う機能は落ちる
- xref-guard（[前述](#ほかの-repo-への参照で-pushpr-を止めるフック)）は公開範囲を `gh repo view`（GraphQL）で引くので、cloud では
  引けない。引けないときは止める側に倒れるので、ほかの repo の参照を書いた commit の push は private な repo でも止まる（参照の
  無い push は gh を呼ばないので止まらない）。通すなら、ユーザーが明示して頭に `PJP_ALLOW_XREF=1` を付ける
- dotfiles の devShell に入るには、`home-manager` の入力を git で取るよう差し替える（proxy は session に付いていない repo の
  archive を、public でも断る。nixpkgs だけを入力に持つ flake はそのまま入れる）

```sh
nix develop ./nix --no-write-lock-file --override-input home-manager \
  "git+https://github.com/nix-community/home-manager?rev=$(jq -r '.nodes["home-manager"].locked.rev' nix/flake.lock)&shallow=1"
```

### 管理しないもの

`settings.json`（権限の「常に許可」などで書き換わる）、`skills/manifest.json` と
Anthropic 配信 skill、`plugins/`、実行時の状態（`projects/` `sessions/` など）、
`claude-skills` の中身（上記のとおり作業クローンへの symlink で繋ぐ）。
`settings.json` のうち `bootstrap-claude-*.sh` が書くキー（フック / statusLine / `env` の
`GIT_CONFIG_*` と `CLAUDE_CODE_SHELL`・`CLAUDE_CODE_PLUGIN_PREFER_HTTPS` / `skillOverrides.pjp-dev-tracker` / `footerLinksRegexes`）だけは、script が冪等に上書きする。
`skillOverrides` の pack の skill と claude.ai から同期された skill の key は、控えと比べて書き・戻す（手で書いた値は残す。[前述](#書いた-key-の控えと戻し)）。

## mise との役割分担

| 対象 | 管理者 |
| --- | --- |
| グローバルな CLI ツール | Nix (`home/modules/packages.nix`) |
| 言語ランタイム (go / node) | mise |
| プロジェクト毎のツール固定 | mise (`mise.toml`) |
| `claude` | mise（この表の例外。[理由](#claude-だけ-mise-に置いている理由)） |
| `cursor-agent`（Cursor の CLI） | mise（この表の例外。`dotfiles.cursorAgent.enable` のホストだけ。[理由と入れ方](#cursor-agent-も-mise-に置いている理由)） |
| `python3` | Nix（`home/modules/python.nix`。言語ランタイムだが、プロジェクトで切り替えず道具の前提として使う。[後述](#python3-と-uv)） |

### `claude` だけ mise に置いている理由

`claude` はグローバルな CLI なので、上の表どおりなら `packages.nix` 側が筋。
nixpkgs にも `claude-code` は在り、wrapper が `DISABLE_AUTOUPDATER` を立てるので
Nix 管理でも動作自体に問題はない。

それでも mise に置いているのは **リリース頻度が `flake.lock` の更新周期に合わない**ため。
nixpkgs pin にすると、版は `flake.lock` を上げるまで動かない。

遅延も `claude` だけ settings の `minimum_release_age`（既定の 9d）ではなく **1d** に縮めて
`latest` を入れている（`bootstrap-mise.sh` の
`MISE_MINIMUM_RELEASE_AGE=1d mise use -g claude@latest`。下の `mise1` と同じ）。
`claude` は新しい版をこまめに使いたいことが多いが、ほぼ毎日出るので 9d を課すと手元の版が
常に 9 日ぶん遅れるため。1d でも公開から 1 日経っていない版は取らないので、
[「先端は取らない」方針](#依存-flakelock-の更新)の線は残る。遅延を期間付きで緩めている間、上書きの上限の方が
新しい版を取るなら `claude` も上限で入れる（[後述](#遅延-minimum_release_age-を期間付きで緩める)）。

遅延をその 1 回だけ変える alias / abbr を bash・fish の両方に置いている。
`config.toml` は書き換えないので、以後の素の `mise` は settings の遅延（既定の 9d か、上書きの上限）のまま。

| 名前 | 短縮形 | 中身 | 使いどころ |
| --- | --- | --- | --- |
| `mise_with_no_release_age` | `mise0` | `MISE_MINIMUM_RELEASE_AGE=0d mise` | 1 日も待てないとき（出たばかりの版にしか無い修正が要るなど）。`mise0 use -g claude@latest` |
| `mise_with_one_release_age` | `mise1` | `MISE_MINIMUM_RELEASE_AGE=1d mise` | `setup.sh --update` を待たずに `claude` を上げるとき（`mise1 use -g claude@latest`）や、9d の他のツールを 1d で取るとき |

この選択には副作用があり、`bootstrap-claude-plugins.sh` が `claude` を要求するので
実行順の制御が必要になっている（次節）。

### `~/.config/mise/config.toml` は Nix 管理下に置かない

mise が実行時に書き換えるファイルなので store には置けない。設定の投入も
mise 自身のコマンドで行う（config.toml は mise のスキーマであり、Nix 側に
スナップショットを持たせると形式変更への追随が必要になるため）。

**新規マシンで実行する（冪等なので更新時も毎回走る）:**

```sh
./nix/scripts/bootstrap-mise.sh
```

`[settings]`（`minimum_release_age` / `lockfile` / `fetch_remote_versions_timeout`）と、`[tools]` に
言語ランタイム（`go` / `node`）・mise の補完に要る `usage`（`aqua:jdx/usage`）・`claude`（[前述](#claude-だけ-mise-に置いている理由)）を
入れる。`mise settings set` は該当キーだけを触るので冪等で、既存の `[tools]` も壊さない。`minimum_release_age` は
option の値（既定の 9d か、期間付きの上書きの上限。[後述](#遅延-minimum_release_age-を期間付きで緩める)）を書く。

> ネットワークアクセスとインストールを伴うため `home.activation` には入れていない。
> `home-manager switch` は hermetic に保つ方針。

> ⚠️ **既存マシンでは、旧経路（`main.bash` のシェル設定）が書き込んだ 16 エントリが自動では消えない。**
> マシン毎に一度だけ `~/.config/mise/config.toml` を手で編集し、`[tools]` には `bootstrap-mise.sh` が書く名前
> （今は `aqua:jdx/usage` / `go` / `node` / `claude`）だけを残すこと。消さないと mise の shim が PATH 先頭にいるため
> Nix 側のツールが使われない。旧経路と前の `setup` が書いた短縮名の `usage` も消す（今は `aqua:jdx/usage` を書く。
> 同じ道具で、短縮名だと backend を mise が選ぶ）。
> `setup.sh` は、`[tools]` に残っている名前のうち `bootstrap-mise.sh` が書かないものを、実行後の「残りの手作業」に
> 手順 5 として並べる（片付いていれば何も出さない）。書く名前は `bootstrap-mise.sh` のヘッダの `# mise-tools:` から読む
> （[実行順の `# order:`](#bootstrap-の実行順) と同じく、`setup.sh` 側に一覧を持たない）。`bootstrap-mise.sh` の
> `mise use -g` を足す・変えるときはヘッダも直す（`nix/tests/bootstrap-mise.test.sh` が突き合わせる）。

### 遅延 (minimum_release_age) を期間付きで緩める

`bootstrap-mise.sh` は `setup --update` のたびに、`config.toml` の `minimum_release_age` に遅延を書く。値は option で決める
（[ADR 030](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/030_mise_release_age_overrides_20261023T010148JST/README.md)・[設計](https://github.com/pollenjp/dotfiles-private/blob/main/docs/superpowers/specs/2026-10-22-mise-release-age-overrides-design.md)）。`flake.lock` の猶予
（[前述](#新しすぎる-revision-を-pin-しない-minimumreleaseage-相当)）とは別の口で、こちらは mise が入れるツールだけに効く。
mise 本体は nixpkgs から入るので、その版を急いで上げるのはこちらではなく [nixpkgs の猶予の例外](#猶予の日数と例外-release-agenix)
（2026-10 の mise 2026.10.17 は一部 (upstream から) の例外で入れている）。

| option | 既定 | 中身 |
| --- | --- | --- |
| `dotfiles.mise.minimumReleaseAge` | `"9d"` | 遅延。日の単位（`<数>d`）だけ |
| `dotfiles.mise.releaseAgeOverrides` | `[ ]` | 期間を区切って遅延を緩める上書きの list。項目は `from`（必須。`YYYY-MM-DD`）・`zeroDays`（既定 1）・`reason`（既定 `""`） |

脆弱性の修正版を出た日に入れたいときのように、しばらく遅延を緩めたいときに上書きを足す。手で
`mise settings set minimum_release_age 0d` としても次の `--update` で既定に戻るが、上書きは option なので戻らない。
上書きのあいだは別の repo の `mise install`・`mise up` も新しい版を取る。1 回だけ外すなら、今までどおり
`mise0` / `mise1`（[前述](#claude-だけ-mise-に置いている理由)の表）でよい。入れた版は、上書きが終わって遅延が戻っても
古い版へは戻らない（mise 2026.8.6 で実測）。

項目は「from の日から zeroDays 日（from の日を含む）のうちに出た版まで取る」と読む。取る版の上限（from + zeroDays − 1 の
日の終わり）を書くので、その日までは遅延 0d と同じに新しい版を取り、その後は上限を据え置いたまま遅延が 1 日ずつ伸びる。
上限 + 既定の遅延を過ぎると、上書きが無いときと同じに戻る（その後の `--update` で既定を書き直す）。日付は Asia/Tokyo で読む
（時刻帯が UTC のマシンでも同じ日に切り替わる）。

| 日（既定 9d） | `zeroDays = 1` | `zeroDays = 3` |
| --- | --- | --- |
| 10/22（from） | 0d | 0d |
| 10/24 | 約 2d | 0d |
| 10/27 | 約 5d | 約 3d |
| 10/31 の終わり | 上書きが終わる | 約 7d |
| 11/2 の終わり | | 上書きが終わる |

登録した全 PC に効かせるなら、dotfiles-private の `nix/shared/` に module を置く（[dotfiles-private に登録したホスト](#dotfiles-private-に登録したホスト)）。
1 台だけなら、そのホストの `modules`（dotfiles-private の `nix/hosts/<ホスト>.nix` か、ローカル flake の `tmp`。`mkHome` の
引数ではない）に同じ形で書く。list は書いた所どうしでつながる。

```nix
# dotfiles-private の nix/shared/mise-release-age.nix (例)
{
  dotfiles.mise.releaseAgeOverrides = [
    {
      from = "2026-10-22";
      zeroDays = 3;
      reason = "脆弱性の修正版を入れる";
    }
  ];
}
```

option の値は home-manager が `~/.local/state/dotfiles/mise-release-age.json` に置き（`home/modules/mise-release-age.nix`）、
`bootstrap-mise.sh` が今日の日付と比べて書く値を決める（home-manager の評価は今日の日付を読めないため）。反映は
`~/dotfiles/setup --update`（switch だけでは `config.toml` に届かない）。

- from が今日より先の項目は写さない（`まだ始まっていない上書き: …` の行が出る）
- 上書き中の項目のうち、上限がいちばん新しいものの上限（`2026-10-24T23:59:59+09:00` の形）を書き、1 行で知らせる。
  入っている tool は上げないので、新しい版は `mise up`（tool を絞るなら `mise up uv`）で入れる

  ```
  ==> mise の遅延を上書き中 (理由: …): 2026-10-24 の終わりまでに出た版を取る。2026-11-02 の終わりで上書きが終わり、その後の setup --update で既定の 9d に戻す。…
  ```

- `claude` も、上限の方が 1d より新しい版を取るあいだ（上限の日の翌日まで）は上限で入れる（on のホストの `cursor-agent` の版も、
  同じ遅延で引く）
- 終わった項目は写さず、[警告のまとめ](#途中の警告のまとめ)に `[bootstrap-mise]` で出す。書いた所から PR で消す
  （消し忘れても害は無い）
- 毎日流す timer は無い。`--update` を打たない日が続いても mise には上限が残るだけで、ずれるのは新しい版を取らない側
  （守りは緩まない）。次の `--update` で既定に戻る
- 状態ファイルが無い（switch の前の世代）・壊れているときは、警告して 9d を書く

### `cursor-agent` も mise に置いている理由

Cursor の CLI（mise の registry の名前は `cursor-agent`、別名 `cursor-cli`）も、`claude` と同じ理由（リリースの頻度が
`flake.lock` の更新の周期に合わない）で mise に置く。ただし**既定では入れず**、ホストで `dotfiles.cursorAgent.enable = true` に
したマシンにだけ入れる（[ADR 051](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/051_cursor_agent_opt_in_pinned_20261110T180826JST/README.md)・[設計](https://github.com/pollenjp/dotfiles-private/blob/main/docs/superpowers/specs/2026-11-10-cursor-agent-opt-in-design.md)）。
中身は Cursor が `downloads.cursor.com` で配る配布物（公式のインストーラが入れるものと同じ）で、registry の http backend が取る。

#### ホストで on にする

使うマシンのホストの `modules`（dotfiles-private の `nix/hosts/<ホスト>.nix` か、`~/dotfiles/flake.nix` の tmp。`mkHome` の
引数ではない）に書く。

```nix
modules = [
  { dotfiles.cursorAgent.enable = true; }
];
```

- **行を足すのは、この option を持つ本体が merge された後。** 先に足すと、まだ option の無い本体でそのホストの評価が止まる
  （option `dotfiles.cursorAgent` が無い）。その PC では `~/dotfiles/setup --self-update --update` で、本体を新しくしてから当てる
- 反映は `~/dotfiles/setup --update`。`switch` だけでは宣言も版も変わらない

#### 宣言を入れた版に固定する

| どこで | 何を |
| --- | --- |
| `home/modules/cursor-agent.nix` | on / off を `~/.local/state/dotfiles/cursor-agent.json`（`{"enable": <bool>}`）に置く。off のホストにも置く（switch の前の世代と見分けるため） |
| `files/mise/conf.d/cursor-agent.toml` | 宣言の雛形。registry から変えるのは `bin_path` と `postinstall` だけ（何をなぜ変えるかはファイルの先頭）。版の所は `@version@` |
| `scripts/bootstrap-mise.sh` | on なら版を決め、雛形の `@version@` を替えて `~/.config/mise/conf.d/dotfiles-cursor-agent.toml` に書き、`mise install cursor-agent` を打つ。off なら setup が前に書いた宣言を消す |

宣言の `version` には `latest` でなく版そのもの（`2026.11.05-86047df` の形）を書く。mise が知る版は最新の 1 つだけ（Cursor は版の
一覧を出さず、mise は公式のインストーラから今の版を読む）なので、`latest` を宣言すると、最新の版が遅延（`minimum_release_age`。
既定 9d）の中にある間は候補が 0 になり、どのディレクトリの素の `mise install` も終了コード 1 で落ちる（Cursor はおおむね 1〜3 日
おきに出すので、9d を過ぎた最新の版がある日はほとんど来ない）。版を指した宣言なら、mise は遅延を見ない。

版は `setup --update` のたびに、次の順で決める。

1. `claude` と同じ遅延（1d。上書き中は上限）で `mise latest cursor-agent` が出す版（遅延を過ぎた一番新しい版）
2. 無ければ今の宣言の版（版の形のときだけ）。それも無ければ、入っている一番新しい版（`mise latest --installed cursor-agent`。前の作りで
   入れた版もここで拾う）
3. どれも無ければ宣言を書かず、[警告のまとめ](#途中の警告のまとめ)に出す（版を指していない宣言が残っていれば消す。次の `--update` で入る）

版として書くのは、数字で始まる形（`^[0-9][0-9A-Za-z._+-]*$`）だけ。`latest` のような語は使わない（`latest` の宣言に戻すと、上の
失敗に戻る）。

決めた版を宣言に書いてから `mise install cursor-agent` を打つ（版を指すので遅延の env は付けない。`postinstall` も宣言から効く）。
install が落ちたら宣言を前の中身に戻し（無かったなら消し）、警告する。`mise upgrade cursor-agent` は使わない（上げるのは宣言の版を
書き換えること）。

- **新しい版は、出てから 1d を過ぎた後の `--update` で入る。** 版の日付は日までなので、遅延はその日の終わりから数える（1d なら
  10/22 の版は 10/23 の終わりから）。急ぐときは[期間付きの上書き](#遅延-minimum_release_age-を期間付きで緩める)を足す（ほかの mise の
  道具にも効く）
- **宣言は手で直さない。** 1 行目に印（`# dotfiles-managed: nix/scripts/bootstrap-mise.sh`）があり、次の `--update` で書き直す
  （版を `latest` のような語に書き換えても使わず、入っている版で書き直す）。印の無いファイルや symlink を同じ場所に置くと、setup は
  それを手で置いたものとして書き換えず、cursor-agent も入れない（警告が出る）
- 上げた後の古い版は、`dotfiles.cleanup.enable`（既定 true）のマシンなら週 1 回の掃除（[前述](#使わなくなったデータの定期削除)）の
  `mise prune` が消す（宣言の版は残る）
- 宣言の名前（`dotfiles-cursor-agent.toml`）が前の home-manager の宣言（`cursor-agent.toml`）と違うのは、home-manager の古い世代へ
  戻したとき、その世代の symlink がこの普通のファイルにぶつかって activate が止まらないようにするため。mise は global の conf.d を
  名前の順に読み、同じツールの宣言は後ろのファイルが勝つので、古い世代の `latest` の宣言が並んでも版の宣言が勝つ
- **`mise use -g cursor-agent` は打たない。** `config.toml` の宣言は conf.d より強く、まるごと置き換わる。`bin_path` が
  registry の `dist-package` に戻り、配布物に同梱の `rg` と `node` が PATH の先頭に並ぶ（`rg` は Nix の ripgrep より先に
  来る）。打ってしまったら `config.toml` の `[tools]` から消す（setup の「残りの手作業」にも出る）
- hash の固定は無い（Cursor は checksum を出しておらず、global の tool は `mise lock --global` を打たないと lockfile にも
  残らない）。信頼の置き場所は `downloads.cursor.com` の TLS
- コマンドは `cursor-agent` だけ（公式のインストーラが張る `agent` は無い）。公式のインストーラで入れたことがある PC は
  `~/.local/bin/{agent,cursor-agent}` と `~/.local/share/cursor-agent` を消す（PATH では mise の方が先に来るが、紛らわしい）

#### off のホスト（既定）

- mise の宣言を置かない（setup が前に書いた宣言は消す）。mise は cursor-agent を知らず、素の `mise install` も触らない
- 前の作り（全ホストに `latest` の宣言を置いていた）から移ったマシンでは、`switch` が `~/.config/mise/conf.d/cursor-agent.toml`
  （home-manager の symlink）を外す
- 入っている版は消さない。`dotfiles.cleanup.enable`（既定 true）のマシンなら、週 1 回の掃除の `mise prune` が消す（宣言の無い道具の版は
  消す対象に入る。掃除を切ったマシンでは残る）。残っている間は setup の出力に 1 行出る。今すぐ消すなら:

  ```sh
  mise uninstall --all cursor-agent
  ```

### python3 と uv

nixpkgs の `python3` を `home.packages` に入れ（`home/modules/python.nix`）、uv には自分で入れた python だけを使わせる
（`~/.config/uv/uv.toml` の `python-preference = "only-managed"`。home-manager の `programs.uv` で置き、uv 本体は入れない）
（[設計](https://github.com/pollenjp/dotfiles-private/blob/main/docs/superpowers/specs/2026-10-28-claude-security-plugin-design.md)）。

**なぜ Nix で入れるのか。** Claude Security のプラグイン（[前述](#21-claude-code-の公式プラグイン-手順-41)）が PATH の
`python3`（3.9 以上）を要る。OS の `python3` は版がマシンごとに違い、無い OS もある。
[ADR 001](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/001_home_manager_migration_20260808T163454JST/README.md)
の決定 6 の「言語ランタイムは mise」は、プロジェクトごとに版を切り替えるもの（go / node）の話。`python3` はプロジェクトで
切り替えず道具の前提として使うので、グローバルな CLI と同じく Nix に置く。プロジェクトで版を決めて使う python は、
今までどおり uv か mise で入れる。

**替わるもの。** `~/.nix-profile/bin` は PATH で `/usr/bin` より前に来るので、すべてのシェルと Claude の Bash tool の
`python3`・`python`・`pydoc` が nixpkgs のもの（今の lock では 3.14）になる。

- OS のコマンドは `/usr/bin/python3` を直に指すので替わらない
- apt の `python3-*`（yaml・requests など）は、nixpkgs の python からは見えない。要る script は `/usr/bin/python3` を
  直に指すか、uv で env を作る
- `#!/usr/bin/env python3` の script は手元では 3.14 で動く。版の古い環境でも動かす script は、その版でも確かめる
- claude-skills の script（`ticket.sh` など）が、python3 が 3.11 未満のときに `nix develop` へ入り直すのも要らなくなる

**uv を only-managed にする理由。** uv は、自分で入れた python が無いと PATH の `python3` で venv を作る。`python3` が
Nix のものになると、venv が `/nix/store` の python に結び付き、nixpkgs を上げて古い python が GC されると動かなくなる。
環境変数（`UV_PYTHON_PREFERENCE`）でなく `uv.toml` に書くのは、switch の後の次の uv から効く（hm-session-vars は
switch の前から続く process の下のシェルに届かない）ことと、プロジェクトの `[tool.uv]` が別の値を選べる（環境変数は
プロジェクトの設定より強く、user の `uv.toml` は弱い）ため。

uv の振る舞いはこう変わる（uv 0.13.0・0.11.3 で確かめた）。

| 操作 | only-managed での振る舞い |
| --- | --- |
| `uv sync`・`uv run`（プロジェクト） | system / Nix の python で作った既存の `.venv` を消し、uv の python で作り直す（`--verbose` に `does not meet the Python preference` と出る）。lock の依存は入れ直すが、手で `uv pip install` したものは消える |
| `uv pip`・activate した env | 既存の env をそのまま使う |
| `uv venv`・新しいプロジェクト | uv の python で作る。版を決めていない（`requires-python` が下限だけで、`.python-version` が無い）と、その uv が知る最新の python（uv 0.13.0 なら 3.15、0.11.3 なら 3.14）を落とす |
| `uv python find` | system / Nix の python で作った `.venv` は選ばない（ほかに無ければエラー） |

- 版を決めるなら、プロジェクトに `.python-version` を置く（`uv python pin 3.13`）。プロジェクトの外の既定は
  `uv python pin --global 3.13`（`~/.config/uv/.python-version` に書く。`uv.toml` は 1 ファイルの symlink なので、隣に書ける）
- uv が落とす python は、汎用の Linux 向けの動的リンクのバイナリ。NixOS では nix-ld が要る（lavie は nixos-config で
  有効にしてある。mise の prebuilt のため）

**反映。** `~/dotfiles/setup --update` の switch の直後から、今のシェルでも `python3` が替わる（`~/.nix-profile/bin` は
もう PATH にある。bash で前に `python3` を打っていれば `hash -r`）。`uv.toml` は次の uv から効く。

## ntn (Notion CLI) を Nix で入れる

Notion の CLI `ntn` は nixpkgs に無いので、公式の配布物（`https://ntn.dev/releases/v<版>/ntn-<target>.tar.gz`。Linux は
musl の静的な binary、macOS は署名済みの binary）を、版と system ごとの sha256（隣の `.sha256` の値）で固定して入れる
（`pkgs/ntn/`。形は `pkgs/upstream/mise.nix` と同じ）。`home/modules/packages.nix` が全ホストに入れ、bash・fish・zsh の
補完も入る。pjp-dev-tracker など Notion へ書く skill と、見回り役（[前述](#チケットのコメントをハブの会話へ届ける見回り役-pjp-dev-tracker-inbox)）が使う。
token の置き場（keychain かファイルか）は[前述](#ntn-notion-cli-の-token-をファイルに置く-keyring)。switch せずに試すなら:

```sh
nix run ./nix#ntn -- --version
```

### `ntn update` では上がらない

store の binary は書き換えられないので、端末で `ntn update` を打つと `error: Cannot write to /nix/store/…/bin/ntn` で
失敗する。続けて出る `curl … | NTN_INSTALL_DIR="$HOME/.local/bin" bash` の案内には従わない（版を固定しない ntn が
`~/.local/bin` に入り、PATH で Nix の ntn より先に来る。[下](#前に手で入れた-ntn-と-setup-の警告)の警告が出る）。上流が新しい版を
出すと、端末で打った ntn が `notice: A new version of ntn is available` と `ntn update` を勧めてくるが、Nix の ntn は dotfiles で
上げる。

依存の更新は、derivation の印（`pkgs/ntn/default.nix` の `version` のすぐ上の `# release-source:` の行）を読んで ntn も確かめ、
公開から 7 日（`release-age.nix` の `minimumReleaseAgeDays`）たった版を、いつもの更新の PR で上げる（`version` と 3 つの
`sha256` を、それぞれの `.sha256` と照らしてから書く）。印の行は、依存の更新が読む形なので文字列を変えない。

| 印の欄 | 意味 |
| --- | --- |
| `latest=` | 最新の版を出す URL（`v0.23.25` の形） |
| `url=` | tar の URL の形。`{version}`・`{target}` は derivation の `version` と、system ごとの塊の `target` |
| `sha256=` | sha256 の在りか（`{url}.sha256`） |
| `series=major` | 0.x でも minor 上げ（0.23 → 0.24）を取る |

印が使えないとき・急ぐときは、手で上げる:

1. 最新の版と、その公開日時を見る。公開から 7 日（`release-age.nix` の `minimumReleaseAgeDays`）たった版にする

   ```sh
   curl -fsSL https://ntn.dev/latest.txt          # v0.23.25 の形
   curl -fsSI https://ntn.dev/releases/v<版>/ntn-x86_64-unknown-linux-musl.tar.gz | grep -i '^last-modified'
   ```

2. 3 つの target の tar を落として各 `.sha256` と照らし（CI は aarch64-linux を build しないので、ここで 3 つとも確かめる）、
   `pkgs/ntn/default.nix` の `version` と 3 つの `sha256`（`.sha256` の値）を替える

   ```sh
   cd "$(mktemp -d)"
   for t in x86_64-unknown-linux-musl aarch64-unknown-linux-musl aarch64-apple-darwin; do
     curl -fsSLO "https://ntn.dev/releases/v<版>/ntn-${t}.tar.gz"
     curl -fsSLO "https://ntn.dev/releases/v<版>/ntn-${t}.tar.gz.sha256"
     sha256sum -c "ntn-${t}.tar.gz.sha256" && cat "ntn-${t}.tar.gz.sha256"   # macOS は shasum -a 256 -c
   done
   ```

3. build して、install の後の `ntn --version` が版と合うことを見る（check の `ntn-test`。CI は x86_64-linux と
   aarch64-darwin で build する）

   ```sh
   nix build --no-link -L ./nix#checks.x86_64-linux.ntn-test
   ```

4. PR を出し、merge の後に各マシンで `~/dotfiles/setup --update`

### 前に手で入れた ntn と setup の警告

`curl -fsSL https://ntn.dev | bash` で入れた ntn は、PATH にある `~/.local/bin` か `~/bin` に残る。どちらも PATH で
`~/.nix-profile/bin` より前に来る（`home.sessionPath`）ので、そのままでは Nix の ntn が隠れる。setup の手順
`bootstrap-path-shadow` が、PATH で Nix の ntn より先に Nix のものでない ntn があれば警告し、消すコマンドを出す
（ユーザーのファイルなので消さない。警告のまとめにも載る）。

```text
!! PATH で、Nix の ntn より先に Nix のものでない ntn があります (今のシェルではそちらが使われ、dotfiles が Nix で入れた版は使われません)。
   先に来るもの: /home/<user>/bin/ntn
   Nix の ntn:   /home/<user>/.nix-profile/bin/ntn
   setup は消しません。要らなければ消す (新しいシェルから Nix の ntn が使われる):
     rm /home/<user>/bin/ntn
   npm や mise などの道具で入れたものなら、その道具で外す。
```

消すと、新しいシェルから Nix の ntn が使われる（今の bash で前に `ntn` を打っていれば `hash -r`）。Nix の ntn がまだ PATH に
無いシェル（switch の前から開いているものなど）で流したときは、別の見出しで、Nix の ntn が PATH にあることを `type -a ntn` で
確かめてから消すよう出す。見回り役は `~/bin`・`~/.local/bin` を PATH に入れないので、消す前から Nix の ntn を使う。Nix で
入れるようにした CLI を前にほかの方法で入れていたことがあれば、`scripts/bootstrap-path-shadow.sh` の `commands` に足すと
同じ警告が出る。

### claude.ai/code の環境

cloud の VM は home-manager を通らないので、ntn は環境の setup script の install script で入れる（[前述](#環境を作る)。
版は固定されず、その時の最新）。

## herdr-core (hc) を Nix で入れる

herdr-app (herdr の desktop app) は、SSH でつないだ machine (server) の terminal を、その machine の herdr-core に持たせる。手元の core は
SSH で remote の `herdr-core connect` を起動し、remote は非対話の sh で `p=$(command -v herdr-core) || p=$HOME/.local/bin/herdr-core` を探す
(herdr-core の `crates/herdr-core/src/machines.rs`)。server になりうる Linux のホストに herdr-core を入れるため、`home/modules/herdr-core.nix` が
既定で Linux の全ホストに入れる (`dotfiles.herdrCore.enable`。入れないホストは、そのホストの modules で false にする。macOS には入れない)。
Windows は `win/herdr-app/Install-HerdrApp.ps1` が入れる ([`win/README.md`](../win/README.md#herdr-app))。

- 公式の Linux 版 (`https://releases.herdr.dev/core/<版>/herdr-core-linux-<arch>.tar.gz`。static-pie の単体の binary) を、
  `pkgs/herdr-core/releases.json` の版と sha256 で落とす (`pkgs/herdr-core/`)。nixpkgs の herdr-core は、dotfiles の nixpkgs の固定にまだ無く、
  版も Windows とずれるので使わない
- 版は Windows の herdr-core と同じ (同じ `releases.json`。Windows へは manifest の `base = "nix"` で `herdr-releases.json` として配る)。
  同じ版なら、Windows の herdr-app・hc が machine としてつなぐときに、写し直しを聞かれない
- `herdr-core` と `hc` を home.packages に入れ、`~/.local/bin/herdr-core`・`~/.local/bin/hc` も同じ binary へのリンクにする
  ([下](#非対話の-ssh-から見つかるか))。前に `hc machine add --install` などで写したものは、リンクに置き換わる (force。home-manager は
  中身が同じふつうのファイルを置き換えないので、リンクを張る前に activation が消す)。古い写しが残ると、PATH で `~/.local/bin` が nix の
  profile より先に来て (`home.sessionPath`)、対話の `hc` が古い版になる。同じ版の写しでも、store の外の書けるファイルのままだと、そこから
  打つ `hc update` が nix のものとして断られず、公式の最新へ上がる (Linux には取得元のフィードが無い)
- switch せずに試すなら:

  ```sh
  nix run ./nix#herdr-core -- --version   # hc <固定した版>
  ```

### 非対話の SSH から見つかるか

remote の探し先の 1 つ目 (`command -v herdr-core`) は、非対話の SSH の PATH に nix の profile が入るかで決まる。

- multi-user の Nix の Ubuntu (今の WSL の PC など): installer が `/etc/bash.bashrc` の先頭に `nix-daemon.sh` を読む行を足し、Ubuntu の bash は
  SSH から起こされると (`SSH_CLIENT` がある) それを読むので、`~/.nix-profile/bin` が PATH に入る (2026-11-10 に、sshd が渡す環境を真似た
  `bash -c` で確かめた)
- single-user の Nix は `~/.profile` にしか足さず、home-manager の `~/.bashrc` は先頭で非対話を返すので、入らない

どちらでも見つかるよう、2 つ目の `~/.local/bin/herdr-core` もリンクにしている (実体は store の binary)。

### hc update と hc machine update を打たない

- store の core は、`hc update` が「nix のもの」として断る (`… belongs to nix`・`update it in your Nix configuration`)。実行ファイルの実体
  (`~/.local/bin` のリンクもたどる) が `/nix/store/` の下にあるため (herdr-core の `crates/herdr-core/src/client.rs` の `manager_of`)
- dotfiles が入れたホストへ、ほかの machine から `hc machine update` (と herdr-app の machine の更新) を打たない。`~/.local/bin/herdr-core` を
  落とした binary に置き換える (次の switch が、同じ版でもリンクに戻す)
- 版は `pkgs/herdr-core/releases.json` を上げる PR で、Windows と一緒に上げる ([`win/README.md`](../win/README.md#固定した版を上げる))。merge の後に
  各マシンで `~/dotfiles/setup --update` (Linux は home-manager の switch で、Windows は bootstrap が揃える)。上げた版と古い版の machine が
  混ざると、つなぐときに写し直しを聞かれる (too old to talk to) ので、続けて上げる

### dotfiles を当てないホスト

dotfiles の home-manager を当てない Linux のホストへは、Windows の herdr-app・hc が machine を足すときに入れる (`~/.local/bin/herdr-core`)。
Windows のフィード (`HERDR_RELEASES_URL`) の core の manifest には Linux (x86_64・aarch64) の target も載せているので、同じ版のその target の
build を公式から落とし、固定した sha256 で確かめる (Linux の hc が同じフィードを読んで、sha256 が合わなければ断ることを確かめた)。
Linux の hc から別の CPU の Linux (x86_64 と aarch64) へ入れるときは、Linux に取得元のフィードが無いので、公式の版つきの manifest の sha256 を
使う (版は同じでも、dotfiles が固定した値は通らない)。macOS へは入れない (フィードに macOS の target を載せていない)。

### 成果物を落とせないとき

Linux の switch は、herdr-core の成果物を releases.herdr.dev から落とす (cache.nixos.org には無い)。その store path を持っていないホストでは、
落とせない・sha256 が合わない (公開の後で差し替えられた) と switch が丸ごと落ちる。急いで setup を通すなら、そのホストで
`dotfiles.herdrCore.enable = false` にする (表は[前述](#足したホストに書く値)。差し替えの扱いは
[`win/README.md`「固定した版の成果物が変わったとき」](../win/README.md#固定した版の成果物が変わったとき))。

## CI

`.github/workflows/nix.yml` が、main への push と PR で走る（`nix/**`・`win/**`・workflow 自身が変わったときだけ）。
毎朝 6:00 (JST) の定期実行では `closure-scan` だけが回る。Actions の画面から手で流すこともできる
（`workflow_dispatch`。lock-age の下限日数を下げる `min_release_age_days` は[前述](#依存-flakelock-の更新)）。

| ジョブ | 表示名 | ランナー | いつ | 内容 |
| --- | --- | --- | --- | --- |
| `check` | flake check (x86_64-linux) | ubuntu-latest | push / PR | 全 system の評価 → x86_64-linux のビルド（home と、`checks` に載せたテスト。[後述](#テスト)）→ sandbox への activate と冪等性 → `warnings` が空か（nixpkgs の例外の消し時の警告は落とさず annotation。[前述](#猶予の日数と例外-release-agenix)） |
| `check` | flake check (aarch64-darwin) | macos-latest | push / PR | aarch64-darwin のビルド |
| `lock-age` | flake.lock の遅延ポリシー | ubuntu-latest | push / PR | 本体と skill（`pjp-d3js` / `pjp-drawio` / `pjp-plantuml`）の `flake.lock` の pin が下限日数を満たすか（`flake-lock-age.sh check`。日数と例外は `release-age.nix`。[前述](#依存-flakelock-の更新)） |
| `lint` | lint | ubuntu-latest | push / PR | `nixfmt --check` / `shfmt -d` / `shellcheck` → テストの先頭に「## 確かめること」があるか（`check-test-headers.sh`。[後述](#テスト)）→ テストの判定で `grep -q` をパイプの先に置いていないか（`check-test-grep-q.sh`。[後述](#テスト)）→ Claude Code の skill・agent・command の frontmatter（`check-claude-frontmatter.sh`。[前述](#frontmatter-を確かめる)）→ `win/manifest.toml` の検証 → `win/google-japanese-input/` のテキストの検証 (`config.txtpb` と `keymap.tsv`。辞書は private repo にあり、ランナーに無い) → `win/windows-terminal/managed.json` と `win/international/managed.json` の検証 → `win/powertoys/fancyzones/` の検証 (`managed.json`、`custom-layouts.json` の中身と形、`layout-rules.json`) → win/ の PowerShell のテスト (`win/*/*.Tests.ps1`。nixpkgs の pwsh と openssh で流す。[`win/README.md`](../win/README.md#powershell-のテスト)) → herdr のキーバインドと `[ui]` が WSL と Windows で同じか |
| `closure-scan` | 閉包の脆弱性スキャン | ubuntu-latest | push / PR / 毎朝 | 閉包を SBOM にして OSV / GHSA / NVD と照合し、whitelist に無い findings があれば落ちる（`closure-scan.sh scan`。findings の表（`report.txt`）を summary に出す。sbomnix を前の pin から組めるよう履歴を全部取り、どの pin から取ったかも summary に出す。[前述](#閉包のスキャンと-pin先端の差分-遅延の補完)） |
| `head-diff` | pin と先端の閉包差分 | ubuntu-latest | PR | `nix/flake.lock` が動いた PR だけ、pin と先端で閉包を組んで版の差を summary に出す（`closure-head-diff.sh`）。差があっても落とさない |

`aarch64-linux` はランナーが無いので**評価のみ**（`--all-systems --no-build`）。
オプション名の誤りやプラットフォーム分岐の壊れはこれで捕まる。

`check` と同じことを手元でするには `./nix/scripts/verify.sh` を使う。`lock-age`・`closure-scan`・`head-diff` は、
表の script を手元で打てば同じ判定になる。

Windows の winget で固定した版 (OpenSSH・herdr・Google 日本語入力) が winget の最新に追いついているかは、別の
workflow `.github/workflows/winget-versions.yml` が週 1 回と PR で確かめる (`check-winget-version.sh`。
[`win/README.md`](../win/README.md#winget-の新しい版を確かめる))。winget に無い herdr-app を入れる `Install-HerdrApp.ps1` が写した
公式の install.ps1 が変わっていないかと、固定した版の成果物 (app の Windows、core の Windows と Linux の 2 つ) が変わっていないか・7 日たった
新しい版があるかは、別の workflow `.github/workflows/herdr-app-installers.yml` が週 1 回と PR で確かめる (`check-herdr-app-installers.sh`・
`check-herdr-app-version.sh`。[`win/README.md`](../win/README.md#固定した版を上げる))。Linux の herdr-core の package の build
(固定した sha256 で落とし、`hc --version` を版と照らす) は、`check` の `herdr-core-test` が見る ([前述](#herdr-core-hc-を-nix-で入れる))。

## 検証

```sh
./nix/scripts/verify.sh
```

`nix flake check` → sandbox ビルド → 配置ファイル一覧 → 使い捨て `$HOME` への activate →
冪等性確認 → `~/dotfiles` 参照の残留チェック、までを一括で行う。実際の `$HOME` にも、手元の user systemd にも
触れない (activate へ渡す `XDG_RUNTIME_DIR` を使い捨ての `$HOME` の下へ向ける。CI の `check` と同じ)。

個別に実行する場合:

```sh
cd ~/ghq/github.com/pollenjp/dotfiles/nix
git add .                                  # git 解決なので untracked は見えない (後述)

nix flake check                            # 現在の system 向けに評価 + ビルド
nix flake check --all-systems --no-build   # 全 system を評価のみ (CI 向け)

# 配置されるファイルを事前に確認する
nix build '.#homeConfigurations."pollenjp@x86_64-linux".activationPackage' -o /tmp/hm
find -L /tmp/hm/home-files -mindepth 1     # ★ home-files は symlink なので -L が必須
```

### テスト

置き場所は次の 4 つで、どれも flake の `checks` に載せる。CI の `check` ジョブの `nix flake check` が毎回通す。

- `nix/tests/<名前>.test.sh`・`<名前>.test.mjs`: bash・node で流すテスト。bootstrap や hook などの script の
  振る舞いや、設定ファイルの中身を確かめる（Linux だけ）
- `nix/tests/<名前>.nix`: home の設定が作るもの（状態ファイル・`home.file` など）を確かめる。評価時の assert は
  全 system で流れ、`--all-systems --no-build` でも落ちる（外れた項目の名前がエラーに出る）。ビルドして
  確かめる項目は、そのランナーの system だけ
- `nix/pkgs/<道具>/test_*.py`: `nix/pkgs/` の道具の unittest（ADR 012。Linux だけ）
- `nix/pkgs/pjp-ghq-pull/tests/*.rs`: Rust の pjp-ghq-pull のテスト。package の build の中の `cargo test` が流す
  （`pjp-ghq-pull-test`。全 system）。先頭の `//!` に「## 確かめること」を書くが、`check-test-headers.sh` は `*.rs` を
  読まない

何を確かめるかはここに写さず、各テストの先頭のコメント（unittest は module の docstring）の
「## 確かめること」にだけ書く。全部のテストの「## 確かめること」は、これで並べて読める:

```sh
./nix/scripts/check-test-headers.sh --show | less
```

流し方:

```sh
nix flake check ./nix                                                          # 全部 (home のビルドも)
nix build --no-link -L './nix#checks.x86_64-linux.bootstrap-claude-env-test'   # 1 本だけ
bash nix/tests/bootstrap-claude-env.test.sh                                    # サンドボックスの外で
node nix/tests/claude-footer-links.test.mjs                                    # mjs のテスト (node が要る)
```

1 本だけ流すときの check の名前は、各テストの先頭に書いてある。bash のテストは、
bash・jq・git・coreutils だけの Nix のサンドボックスで、確かめる script を引数で渡して流す。引数を省けば
repo の script を使うので、サンドボックスの外でも流せる（ほかに要るものは各テストの先頭にある）。

#### テストを足すとき

- 先頭のコメントに、check の名前と「## 確かめること」を書く（`*.test.sh` と `*.test.mjs` は流し方の 1 行も）。
  同じ種類の既存のテストの先頭を写すとよい。件数は書かない
- 「## 確かめること」の見出しと、その下の中身が無いテストは、CI の `lint` ジョブ（`check-test-headers.sh`）で
  落ちる。先頭のコメントは、1 行目（shebang の次）から空行を挟まずに続く `#`（`*.test.mjs` は `//`）の行で、
  unittest は module の docstring。手元では `./nix/scripts/check-test-headers.sh` で確かめる
- 判定の `grep -q` はパイプの先に置かない。`outerr "${d}" | grep -q …` は、grep が合って先に抜けると前の `cat` が
  SIGPIPE で終わり、pipefail で「合わない」に見える（前のコマンドが 2 回以上書くときだけ当たり、混んだ CI でたまに
  落ちる。TKT-155）。読むファイルを `grep` に直に渡すか（既存のテストの `seen` / `called`）、`grep -q … <<<"$(…)"`
  で渡す。パイプの先に置いたテストは、CI の `lint` ジョブ（`check-test-grep-q.sh`）で落ちる。手元では
  `./nix/scripts/check-test-grep-q.sh` で確かめる（shfmt と jq が無ければ `nix/` の devShell に入り直す）
- `nix/tests/` の直下にはテストだけを置く。読み方を知らない種類のファイルも `lint` で落ちる
  （テストが使うデータはディレクトリに入れる）
- `nix/flake.nix` の `checks` に載せる（`nix/tests/<名前>.test.sh` は、ほかの道具が要らなければ `scriptTest` で足りる）
- 偽のコマンドの shebang は `$BASH` から作る。サンドボックスには `/usr/bin/env` が無い
- 「gh が無い」場合は、要るコマンドだけを symlink で並べた PATH で作る。GitHub の runner の
  `/usr/bin` や Nix の profile では、gh が bash・jq・git と同じディレクトリにあり、PATH から
  抜けないため
