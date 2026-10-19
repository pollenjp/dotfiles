# setup の取得を gh 優先にする — 設計 (TKT-221)

- チケット: [TKT-221](https://app.notion.com/p/setup-update-pull-gitViaGh-enable-true-gh-ssh-agent-3fe79149a66f81d4b6e8f2c2898d171a)
- 方針は 2026-10-19 にユーザーが承認した (残っていた問い 2 つは推奨どおり)。この文書はその書き写しと、実装に要る細部
- 関連: TKT-24 (forward された agent を固定名 `~/.ssh/agent.sock` で見せる。ADR 008)、TKT-42 (Claude の git を gh で通す)、
  TKT-207 (fetch 系の abbr / alias を `git gh` で通す)

## 背景と意図

remote の herdr の中で `~/dotfiles/setup --update` を流すと、ssh を張り直したあとなどに `SSH_AUTH_SOCK` が消えた socket を
指していて、bootstrap の取得 (ssh の URL への clone / pull) が落ちる。setup は止まらないが、最後のまとめに警告が並ぶ。

```text
⚠️  [bootstrap-cc-pages] pull できませんでした。手元のクローンのまま続けます。
⚠️  [bootstrap-cc-pages] cc-pages を更新できていません (上の !! を参照)。手元のクローンのままです。
⚠️  [bootstrap-claude-skills] pull に失敗しました。手元のクローンのまま続けます: /home/pollenjp/ghq/github.com/pollenjp/claude-skills
       鍵もネットワークも問題ないなら、履歴が分岐しています。手で解決してください。
⚠️  [bootstrap-claude-skills] claude-skills を更新できていません (上の !! を参照)。手元のクローンのままです。
⚠️  [bootstrap-dotfiles-private] pull に失敗しました。手元の clone のまま続けます: /home/pollenjp/ghq/github.com/pollenjp/dotfiles-private
```

lavie の herdr のペインで再現した。`SSH_AUTH_SOCK` (`~/.ssh/agent/s.…agent.…`) も固定名 `~/.ssh/agent.sock` の先
(`s.…sshd.…`) も無く、素の `git ls-remote git@github.com:pollenjp/claude-skills.git` は rc=128 で落ち、
`git gh ls-remote …` は通った。herdr は接続より長生きし、起動したときの `SSH_AUTH_SOCK` を抱えたままになる。
TKT-24 の固定名は ssh 先で herdr を開くときにだけ張り替わるので、herdr の remote のようにログイン shell を通らない
経路では張り替わらない。

`dotfiles.claude.gitViaGh.enable` が true のマシンは「GitHub へは gh の資格情報 (HTTPS) で通す」と決めたマシンで、
Claude の git (TKT-42) と fetch 系の abbr / alias (TKT-207) はもう gh で通る。setup の取得も同じにすれば、
gh が使える限り ssh-agent に頼らずに済む。gh がだめなら、今までどおり ssh-agent で取る。

## ゴール

1. gitViaGh.enable が true のマシンでは、setup が GitHub から取る 4 か所で、gh が使えれば `git gh` で取り、ssh に触れない
   - `bootstrap-claude-skills.sh` の clone と取得
   - `bootstrap-cc-pages.sh` の clone と取得
   - `bootstrap-dotfiles-private.sh` の clone と取得
   - `setup.sh` の本体の更新 (`--self-update`) の fetch
2. gh が使えない (gh・git-gh が PATH に無い、github.com にログインしていない) ときは、ssh で取る (今と同じ経路)
3. `git gh` で取れなかったときは、ssh で取り直す。ssh で取れたら警告を出す (最後のまとめにも出る)
4. gitViaGh.enable が false のマシン、状態ファイルが無い・読めないマシンは、今とまったく同じ経路 (ssh だけ)
5. bootstrap の 3 か所は、pull を「取得 (fetch)」と「merge --ff-only」に分け、「取れない」と「fast-forward できない」を
   別の警告にする。ssh で取り直すのは取得に失敗したときだけ

## 非ゴール

- herdr の中の `SSH_AUTH_SOCK` そのものを直すこと (TKT-24 の案 B、`~/.ssh/rc` で固定名を張り替える。別チケット)
- push の経路 (setup は push しない)
- fish / bash の fetch 系 (TKT-207 で済み)
- ssh の経路で固まるのを防ぐこと。古い接続の socket に繋がると ssh が応答待ちのまま戻らないことがある (TKT-24 で実測)。
  gh を通れればこの経路に入らないが、ssh へ回したときは今と同じ

## アンチゴール (技術的に動いても失敗とみなすもの)

- gitViaGh.enable が false のマシンで gh を使い出す
- gh が使えないマシンで setup や bootstrap が止まる・exit 1 になる (bootstrap は今どおり、取れなくても exit 0)
- origin の URL や git の設定ファイルを書き換える
- 履歴の分岐で落ちたのに ssh で取り直し、同じ失敗を 2 回出す
- `setup.sh` が jq など Nix より前に無いコマンドを要るようになる

## 制約

- `setup.sh` は Nix が入る前にも走る。依存できるのは bash / coreutils / curl だけで、jq は使えない。macOS の
  `/bin/bash` 3.2 で動く書き方にする (連想配列・mapfile・`${var,,}`・nameref を使わない)
- 各 bootstrap は単体でも流せる。共通のファイルを source しない (`warn()` / `summary_warn()` と同じ方針。
  `nix/tests/warn-helpers.test.sh` の先頭)
- `set -e` は if の条件に置いた関数の中で効かない。関数の中で失敗しうるものは戻り値で受ける
- `GIT_TERMINAL_PROMPT=0` と `GIT_SSH_COMMAND` の `-o BatchMode=yes` は今どおり残す
- shfmt (2 空白・`binary_next_line`・`case_indent`)・shellcheck・nixfmt を通す
- テストは `nix/tests/` に置き、先頭に check の名前と「## 確かめること」を書く (`check-test-headers.sh`)。判定の
  `grep -q` をパイプの先に置かない (`check-test-grep-q.sh`)。偽のコマンドの shebang は `$BASH` から作る。
  「gh が無い」は要るコマンドだけを symlink で並べた PATH で作る
- テストは流す人の env の git の設定 (Claude のセッションの `GIT_CONFIG_*`) を消して流す。消さないと、ssh の URL が
  https に読み替わって経路の判定が狂う
- commit は日本語の `<種類>(<範囲>): … (TKT-221)`

## 決まったこと

### 1. option の値を状態ファイルで渡す

- home-manager が `~/.local/state/dotfiles/git-via-gh.json` を書く。中身は
  `builtins.toJSON { enable = cfg.gitViaGh.enable; } + "\n"` で、`{"enable":true}` か `{"enable":false}`。値によらず必ず書く
- 書くのは `nix/home/modules/claude.nix` (option が `dotfiles.claude.gitViaGh` で、`claude-env.json` もここで書いている)
- 読む側は jq を使わない。中身が bash の正規表現 `"enable"[[:space:]]*:[[:space:]]*true` に合うときだけ true。
  無い・読めない・ほかの値はどれも false (今までどおり ssh)
- `claude-env.json` (gh の組が載っている) は読まない。Claude のセッションの env の形で、意味が違うため
- 本体の更新は switch より前に走るので、前の世代のファイルを読む。option を変えた直後の 1 回だけ前の値で動くが、害は無い

### 2. 4 つの script に同じ関数 `git_github` を置く

GitHub と通信する git (clone / fetch) を流す関数。引数は git の引数そのまま (`git_github -C "${dir}" fetch`、
`git_github clone "${url}" "${dir}"`)。4 つの script (`setup.sh` と bootstrap の 3 つ) に同じ定義を置く。

流れ:

```text
git_github_hint を空にする
状態ファイルの enable が true でない
  → git "$@" (ssh)。失敗したら hint = ssh の案内、その終了コードを返す
gh か git-gh が PATH に無い
  → 「gh (git gh) が見つからないので、ssh で取ります」の 1 行 → git "$@"。失敗したら hint = gh auth login の案内
gh auth token --hostname github.com が通らない
  → 「gh が github.com にログインしていないので、ssh で取ります」の 1 行 → git "$@"。失敗したら hint = gh auth login の案内
git gh "$@" が通る
  → 「gh の資格情報 (HTTPS) で取りました」の 1 行 → 0 を返す
git gh "$@" が落ちる
  → 「gh の資格情報では取れませんでした。ssh で取り直します」の 1 行 → git "$@"
     通る   → warn (下の文) → 0 を返す
     落ちる → hint = gh と ssh の両方の案内、その終了コードを返す
```

- 経路の 1 行は stdout に 2 空白の字下げで出す (`printf '  %s\n'`)。`note()` は dotfiles-private に無く、`setup.sh` の
  ものは色を付けるので使わない
- gh で取れず ssh で取れたときの警告は `warn` で出す (stderr と、setup から走るときは最後のまとめ)。文の中身は
  「gh の資格情報では取れず、ssh (ssh-agent) で取りました。」と、続きの行に「gh の token が切れていると Claude の git
  (gitViaGh) も通りません。gh auth status で確かめてください。」
- gh が使えずに ssh へ回したことは警告にしない (未ログインは `bootstrap-claude-env.sh` が既に警告し、まとめにも出る)
- 取れなかったときの案内 `git_github_hint` (グローバル変数。関数の頭で空にする) は、呼び元の警告の続きの行に添える。
  呼び元の今の「SSH 鍵が要ります…」の行はこれに置き換える。中身は次の 3 通り (文言は実装で整えてよい)
  - ssh だけで試した (option が false・状態ファイルが無い): SSH 鍵 (ssh-agent) で取れなかった。`ssh -T git@github.com`
    で疎通を確かめられる
  - gh が使えず ssh で落ちた: gh が使えず、SSH 鍵 (ssh-agent) でも取れなかった。`gh auth login` すれば ssh-agent
    なしで取れる
  - gh でも ssh でも落ちた: gh の資格情報でも SSH 鍵でも取れなかった。`gh auth status` と `ssh -T git@github.com`
    で確かめる
- gh か git-gh の有無は `command -v` で見る。`git gh` は git が PATH から `git-gh` を探して起動する
- `--dry-run` の扱いは呼び元の `run` に任せる (`run git_github …`。dry-run では関数は動かず、`+ git_github …` と出る)

### 3. 取得と merge を分ける (bootstrap の 3 つ)

今の `git -C "${dir}" pull --ff-only` を、次の 2 つに分ける (`setup.sh` の本体の更新は既に fetch と merge が分かれている)。

```sh
git_github -C "${dir}" fetch            # 失敗 → 「取得 (fetch) に失敗しました。手元の clone のまま続けます」+ git_github_hint
git -C "${dir}" merge --ff-only '@{u}'  # 失敗 → 「fast-forward できません。手元の clone のまま続けます」+ 「履歴が分岐していないか確かめてください: git -C <dir> status」
```

- どちらで落ちても、今と同じく手元の clone のまま続ける (claude-skills と cc-pages は `stale=1`)
- `fetch` は引数なしで branch の upstream の remote を取る (pull と同じ)。dotfiles-private は今どおり `--quiet` を付ける
- 前の「鍵もネットワークも問題ないなら、履歴が分岐しています」の行は、2 つの警告に分かれるので消す
- clone は分けずに `git_github clone …` を 1 回 (失敗したら git が作りかけの dir を消すので、ssh で取り直せる)。
  `git gh clone` で取っても origin の URL は ssh の形のまま残る (実機で確かめた)

### 4. setup.sh の本体の更新

- `pull_repo` の `run git -C "${repo_dir}" fetch "${remote}" "${branch}"` を `run git_github …` にする
- fetch の失敗の警告 (「fetch に失敗しました。オフラインなら無視して続けます。」) に `git_github_hint` を続きの行で添える
- 警告は今どおり `[本体の更新]` としてまとめに載る (`warn_context self-update`)
- 本体が進んで exec し直すときも載せる。今の `self_update_and_reexec` は exec の前に警告の一時ディレクトリを消し
  (「更新できたときは、まだ何も溜まっていない」前提)、exec した先は作り直すので、fetch で出た警告 (gh で取れず
  ssh で取った) がまとめから落ちる。そこで exec の前に `[本体の更新]` のファイルの中身を env
  (`DOTFILES_SETUP_SELF_UPDATE_WARNINGS`) に入れて渡し、新しい setup.sh は警告の置き場を作った直後に自分の
  `[本体の更新]` のファイルへ書き戻す。受け取るのは `DOTFILES_SETUP_SELF_UPDATED=1` で exec されたときだけで、
  読んだらすぐ unset する (子の手順へ渡さない)。一時ファイルを残さない約束 (README・setup-post-notes の 14 番) は保つ
- README「途中の警告のまとめ」の `[本体の更新]` の説明 (今は「本体を更新しなかった理由」) を、fetch を gh で取れず
  ssh で取ったことも載り、exec し直しても引き継ぐ形に広げる

## テスト

1. 関数のテスト `nix/tests/git-github-helpers.test.sh` (check `git-github-helpers-test`。`scriptTest` に `./scripts` を丸ごと
   渡す。`warn-helpers-test` と同じ形)
   - `git_github` を定義する script を全部見る。`setup.sh` と bootstrap の 3 つが定義していなければ落ちる
     (1 つも見つからないときも落ちる)
   - script から `git_github`・`warn`・`summary_warn` の定義だけを切り出して流す
   - 偽の `git` (引数を書き留め、`gh …` なら `FAKE_GH_RC`、ほかは `FAKE_SSH_RC` で終わる)・偽の `gh` (`auth token` の
     終了コードを変えられる)・中身の無い `git-gh` を、要るコマンドだけの PATH に置く。jq は PATH に入れない
   - 場合: 状態ファイル無し / enable false / gh 無し / 未ログイン / git gh で取れた / git gh 失敗・ssh 成功 /
     両方失敗。それぞれ、呼んだ経路 (書き留めた引数)・stdout の 1 行・警告 (stderr とまとめのファイル)・終了コード・
     `git_github_hint` を見る。引数がそのまま渡ること (`-C <dir> fetch --quiet`、`clone <url> <dir>`) も見る
2. 各 script のテスト (本物の git と手元の bare repo。偽の `git-gh` は引数を書き留めてから本物の git を呼ぶか、落ちる)
   - `bootstrap-dotfiles-private.test.sh` に足す: gh で clone・取得できる、gh で落ちて ssh で取れたら警告がまとめにも出る、
     履歴が分岐していたら「fast-forward できません」で ssh で取り直さない
   - `bootstrap-cc-pages.test.sh` に足す: `--dir` に置いた clone を gh で取得して進める、履歴の分岐。go を PATH に入れず、
     ビルドの手前の「go が見つかりません」で止まる形で流す (clone の URL は固定なので、取得の側だけを見る)
   - `bootstrap-claude-skills.test.sh` を新しく作る (今はテストが無い。check `bootstrap-claude-skills-test`)。取得の側だけ:
     gh で取得して進める、gh で落ちて ssh で取れたら警告、履歴の分岐。`--dir` の clone と使い捨ての HOME で流す
   - `setup-post-notes.test.sh` に足す: 本体の更新で、gh で落ちて ssh で取れたときの警告が、本体が進んで exec し直した
     あとも `[本体の更新]` でまとめに載り、一時ファイルを残さない。gh で取れたときは警告が出ず、本体が進む
     (どちらも今の 14 番と同じ組み立て)
3. 状態ファイル: `nix/tests/claude-env.nix` に、既定 (true) と false それぞれの `git-via-gh.json` の中身と末尾の改行を足す

## 文書

- `nix/README.md`
  - 「fetch 系を gh の資格情報で通す (git gh)」に、setup の取得も gh を先に通すこと (4 か所・流れ・警告) を足す
  - 「本体を最新にする (`--self-update`)」に、gitViaGh のマシンでは fetch を gh で先に試すことを 1 行足す
  - claude-skills と cc-pages の「取得できないマシンでも止まらない」の表を、取得と fast-forward の 2 行に分け、gh を先に
    試すことへのリンクを足す
- `nix/home/options.nix` の gitViaGh.enable の description と冒頭の一覧の行に、setup の取得を足す
- gitViaGh の意味を書いているコメント (`nix/hosts/default.nix`・`nix/lib/mk-home.nix`・`nix/scripts/setup-local-flake.sh`・
  `nix/home/modules/packages.nix`・`nix/pkgs/git-gh/default.nix`) に、setup の取得を足す
- 3 つの bootstrap と `setup.sh` の先頭のコメントと `--help` に、gh を先に試すことを足す
- ADR は起こさない (gitViaGh のほかの部分 (TKT-42・TKT-207) と同じく、README と各ファイルの先頭に書く)

## こちらの判断 (ユーザーに確かめずに決めたもの)

- 状態ファイルの名前と置き場 (`git-via-gh.json`。`lib/git-via-gh.nix` と名前をそろえ、書くのは `claude.nix`)
- 事前の確かめは `gh auth token` (通信しない)。`gh auth status` は通信するので毎回の setup では使わない
- 関数の名前 `git_github` と、案内を返すグローバル変数 `git_github_hint`
- 経路の 1 行を stdout に出す (gh で取れたときも)
- clone は取得と merge に分けない
- ADR は起こさない
- builder check の指摘 (本体が進んで exec すると `[本体の更新]` の警告がまとめから落ちる) は、env で exec の先へ
  引き継ぐ形で直す (4 節)。ユーザーが選んだ「まとめにも出す」を、本体が進む普通の場面でも守るため。引き継がずに
  「既に最新のときだけ載る」と割り切る案は、bootstrap を含まない `--steps` と流したときに気付けなくなるので採らない
- cc-pages は取得の前に未コミットの変更・upstream を確かめていないので、merge の失敗の警告は「履歴が分岐しています」と
  言い切らず、「履歴が分岐していないか確かめてください: git -C <dir> status」とする (3 つの bootstrap でそろえる)

## 実装に任せること

- 警告と経路の 1 行の細かい文言 (上に書いた意味を保つ)
- テストの組み立ての細部 (ケースの番号・helper の名前など)
- README の節の中での置き場所と見出し
