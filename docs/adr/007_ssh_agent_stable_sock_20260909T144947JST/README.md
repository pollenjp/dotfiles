# ADR: forward された ssh-agent を固定名の symlink 越しに見せる

| 項目 | 内容 |
| --- | --- |
| ステータス | 提案 (Proposed) — レビュー中 |
| 日付 | 2026-09-09 (JST) |
| 決定者 | pollenjp |
| 前提 ADR | [001_home_manager_migration](../001_home_manager_migration_20260808T163454JST/README.md)（決定 3「既存ツリーは一切変更しない」に従い、変更は `nix/` 側だけに閉じる）/ [004_nix_wsl_ssh_wrapper](../004_nix_wsl_ssh_wrapper_20260811T124616JST/README.md)（WSL では `ssh-add` が Windows 側の実体になる。本 ADR の判定はその前提の上に乗る） |
| 運用手順 | [`nix/README.md`](../../../nix/README.md#forward-された-agent-を固定名で見せる)（日常運用はこちら） |

---

## 1. 背景 (Context)

ssh 先で [herdr](https://github.com/herdr/herdr) のような多重化ソフトを起動し、
detach → logout したあと再び ssh すると、**herdr の中から ssh-agent が使えなくなる。**
`git push` も `ssh` も鍵が引けない。

原因は 3 つの事実の噛み合わせで、どれも単体では直せない。

1. **sshd は agent forwarding のある接続ごとに socket を作り、接続が閉じると消す。**
   パスは `/tmp/ssh-XXXXXX/agent.<pid>` で、接続ごとに変わる
2. **herdr は client-server 型で、`herdr server` が detach と logout を跨いで常駐する。**
   session / pane はその server の環境変数を継ぐので、`SSH_AUTH_SOCK` は
   **server を起動した時点の接続の値**で固定される
3. **実行中プロセスの環境変数は外から書き換えられない。** 常駐している server と、
   その中で走り続けている shell や agent の `SSH_AUTH_SOCK` を後から直す方法は無い

| 時点 | `/tmp` の実体 | herdr server が抱える env |
| --- | --- | --- |
| ssh #1（`ForwardAgent yes`） | `/tmp/ssh-A/agent.1` 誕生 | — |
| herdr 起動 | 〃 | `SSH_AUTH_SOCK=/tmp/ssh-A/agent.1` を捕獲 |
| detach → logout | sshd が `/tmp/ssh-A` を削除 | 捕獲したまま（指す先が消滅） |
| ssh #2 | `/tmp/ssh-B/agent.2` 誕生 | **変わらない ← ここが問題** |

### 現行コードは、この状況を分かりにくい形で悪化させる

`nix/home/modules/bash.nix` / `fish.nix` の `299_ssh_agent` 複製ブロックは、
`ssh-add -l` が失敗すると次の順に倒れる。

1. 保存済みの `~/.ssh-agent` を読む（そこに書かれた agent も死んでいることが多い）
2. **ローカルに `ssh-agent` を起こし、`~/.ssh/id_ed25519` を `ssh-add` する**

2 に落ちると、forward されてきた 1Password の鍵とは**別の鍵を持つ agent**へ
静かにすり替わる。`ssh-add -l` は応答するので一見復旧したように見え、
「agent は生きているのに鍵が違う」という一番切り分けにくい壊れ方をする。

## 2. 決定 (Decision)

**固定名 `~/.ssh/agent.sock` を 1 枚挟み、ssh のログインごとに実 socket へ張り替える。**
herdr とその中の全プロセスには固定名しか見せない。

変えられないもの（実行中プロセスの env）はそのままにして、変えられるもの
（パスが指す実体）を動かす。tmux + agent forwarding で古くから使われている定石で、
**「すでに走っているプロセス」まで直せる方法はこの形しかない。**

| 時点 | `~/.ssh/agent.sock` の指す先 | herdr 内の env |
| --- | --- | --- |
| ssh #1 ログイン | → `/tmp/ssh-A/agent.1` | `SSH_AUTH_SOCK=~/.ssh/agent.sock`<br>（永久に有効な固定名） |
| logout 中 | dangling（鍵は使えない。後述のとおりこれは正しい） | 〃 |
| ssh #2 ログイン | → `/tmp/ssh-B/agent.2` に張り替え | 〃 |

処理は 2 つに分かれ、**どちらも shell の init に置く**。

| # | 役割 | 発動条件 |
| --- | --- | --- |
| (1) | forward された生きた socket を固定名へ張り替える | `SSH_CONNECTION` がある（= sshd 越しのログイン shell）かつ `SSH_AUTH_SOCK` が生きた socket |
| (2) | 固定名が生きていれば `SSH_AUTH_SOCK` をそこへ向ける | `ssh-add -l` が失敗する（= env が古い / 空）かつ固定名が生きている |

### 張り替えの前に「固定名と違うこと」を確かめる

`SSH_AUTH_SOCK` が既に固定名だったときに `ln -sfn` を走らせると、
**自分自身を指す symlink (ELOOP) ができて生きたリンクを壊す。**
踏むのは稀な経路（`AcceptEnv SSH_AUTH_SOCK` のような設定）だけだが、
壊れ方が派手なのでガードを置いてある。

### 判定順序が要点

**(2) は、保存済み `~/.ssh-agent` の読み込みとローカル agent の新規起動より前に置く。**
背景に書いた「別の鍵を持つローカル agent へ静かにすり替わる」経路を、
forward された agent がある限り踏まないようにするため。

### `SSH_CONNECTION` でスコープを絞る理由

symlink を張り替えるのは「ssh 先のログイン shell」だけの仕事にする。
`SSH_CONNECTION` は sshd が置く変数なので、次が自動的に成り立つ。

- WSL やデスクトップの**ローカル** shell では (1) は発火しない。
  WSL では `ssh-add` が Windows 側の実体（[ADR 004](../004_nix_wsl_ssh_wrapper_20260811T124616JST/README.md)）で
  `SSH_AUTH_SOCK` を見ないため `ssh-add -l` が成功し、**(2) も発火しない**。
  つまり WSL の挙動は一切変わらない
- herdr の pane（`SSH_CONNECTION` を持たない）は固定名を**読むだけ**で、
  張り替えには関与しない

### なぜこれで安全性が下がらないか

| 論点 | 評価 |
| --- | --- |
| 到達権限 | 広がらない。アクセス制御は実 socket 側（`/tmp/ssh-XXXXXX` は 0700・本人所有、sshd が作る）で効いており、symlink を辿るときも target の権限チェックはそのまま働く。同一 UID のプロセスと root は元々 `/tmp` を走査すれば実 socket に到達できるので、symlink は「覚えやすい別名」を足すだけ |
| 固定名の置き場 | `~/.ssh`（0700）に置く。world-writable な `/tmp` に固定名を置く亜種（先取り・すり替えの温床）は採らない。`$XDG_RUNTIME_DIR` も採らない（最後の logout で消えるので、まさに herdr だけが生き残る今回の窓と最悪の相性。非 systemd 環境には存在しない） |
| 切断中の鍵 | **使えないままに保たれる。** logout 中はリンクが dangle するだけで、herdr 内の ssh は失敗する。不在中に鍵が使える方が危険なので、これは forwarding の良い性質を壊していない（棄却した案 C はこの性質を失う） |
| 残余リスク | 従来と同一。接続中は remote の root / 同一 UID プロセスが agent に署名を頼める。これは forwarding 自体の性質で symlink の有無と無関係。実質の緩和は 1Password 側の承認ダイアログ。OpenSSH agent の `ssh-add -c` や destination constraint (`ssh-add -h`) は 1Password agent に無いのでここでは使えない |

## 3. 変更点の詳細

| ファイル | 変更 |
| --- | --- |
| `nix/home/modules/bash.nix` | `299_ssh_agent` ブロックに (1) と (2) を追加。既存のフォールバックを `if ! ssh-add -l` の中へ入れ子にした |
| `nix/home/modules/fish.nix` | 同じ内容を fish 構文で。挙動は bash と一致（「6. 検証」） |
| `nix/README.md` | 「ssh について」に節を追加 |

### 既存フォールバックを入れ子にした理由

判定順序（(2) を先に置く）を素直に表現できるのが第一の理由だが、
**`ssh-add` の呼び出し回数も減る。**

```text
変更前: agent が生きているとき ssh-add -l を 2 回呼ぶ
        (フォールバックの if が 2 つ並んでいて、それぞれが呼ぶ)
変更後: 1 回。以降は入れ子の中なので評価されない
```

WSL では `ssh-add` が interop 越しの `ssh-add.exe` になり 1 回あたりの
コストが無視できないので、対話 shell の起動が速くなる側の変更になる。

### レガシー経路 (`shell/299_ssh_agent.sh` / `.fish/299_ssh_agent.fish`) を触らない

[ADR 001 の決定 3](../001_home_manager_migration_20260808T163454JST/README.md)
（既存ツリーは一切変更せず、`main.bash setup` で戻せる状態を保つ）に従う。

レガシー経路が現役なのは Windows (MINGW) と復旧用途で、いずれも
「ssh 先の Linux で herdr を常駐させる」今回の対象ではない。
**ただし ssh 先のマシンがまだ `main.bash setup` 運用なら、この修正はそこには届かない。**
その場合は当該マシンを Nix 経路へ移すのが筋（レガシー側への複製は行わない）。

## 4. 検討した代替案

### 案 B: `~/.ssh/rc` で張り替える

sshd がセッション開始直前に `sh(1)` で実行するユーザーフック
（`PermitUserRC` の既定は `yes`）。ログイン shell を経ない **exec 型接続**
（`ssh host <cmd>`、`herdr --remote` の helper、git-over-ssh）でも走るので、
(1) の発動範囲は本案より広い。

**採らなかった理由: いま必要な範囲を超え、副作用が増えるから。**

- 現状の使い方（自分で ssh してから remote で herdr を起動 / attach）は
  必ず対話ログインを経るので、(1) は shell init で十分
- rc は**別プロセス**なので `export` はできない。(2) はどうせ shell init に残る。
  つまり B は A の置き換えではなく (1) の強化パーツで、後から足せる
- 落とし穴が増える: **stdout に 1 byte でも書くと git-over-ssh などのデータ
  ストリームを壊す**、rc を置くと sshd が xauth を自動で呼ばなくなるので
  X11 forwarding を使うなら自前で `xauth` を叩く必要がある

`herdr --remote` のような非対話経路を常用し始めたら足す。そのときも本 ADR の
コードは変更不要。

### 案 C: remote に常駐 agent を置き、鍵も remote に持つ

systemd user unit + linger で固定 socket を持たせる方式。**採らない。**
「鍵は 1Password に集中させ、remote には秘密鍵を置かない」という現方針に反する。
さらに detach 中も鍵が生きたままになるので、安全性は下がる方向に動く。

### 案 D: herdr 側で attach 時に env を更新する（tmux の `update-environment` 相当）

仮に同等機能があっても**新しい pane にしか効かない**。すでに走っている
Claude Code や shell の env は誰にも変えられないので、今回の症状の中心
（detach したまま生き続けている session）は救えない。加えて herdr は
mise 管理の外部ツールで、こちらから手を入れる対象でもない。

## 5. 影響 (Consequences)

### 良くなること

- ssh を張り直しても、**detach 済みの herdr session がそのまま鍵を使える**
- forward された agent がある限り、「別の鍵を持つローカル agent」へ
  静かに倒れる経路を踏まなくなる
- `ssh-add` の呼び出しが対話 shell あたり 1 回減る（WSL で体感差が出る）

### 注意が必要なこと

- **複数の ssh を同時に張ると、最後のログインが勝つ。** 新しい接続を切って
  古い接続だけ残すとリンクが dangle するが、次のログインで自然に直る。
  常用で困るようになったら「生きている自分の `/tmp/ssh-*/agent.*` を探して
  張り替える関数」を足せる（init から `/tmp` を走査するのは遅く行儀も悪いので既定にはしない）
- **logout 中は herdr の中から鍵が使えない。** これは意図した性質（「2. 決定」の
  安全性の表）。その間 `ssh-add -l` は失敗し、既存フォールバックが働いて
  ローカル agent が起きることがある（従来と同じ挙動。今回は変えていない）
- **すでに走っている herdr server には効かない。** 古い env を抱えたままなので、
  適用後に一度 `herdr server stop` するか、session の中で手で 1 回だけ
  `export SSH_AUTH_SOCK=~/.ssh/agent.sock` する（「7. 移行・運用手順」）
- `ln -sfn` は unlink → symlink の 2 手なので厳密には atomic ではない。
  競合し得るのは同一 UID の自分のログインだけなので許容する
- `~/.ssh` が存在しないマシンでは `ln` が stderr にエラーを出す。
  `programs.ssh.enable = true` が全ホストで `~/.ssh/config` を書く
  （`ssh.nix`）ので実際には到達しない経路だが、`-d` ガードを足していないのは
  この保証に依存しているため（「6. 検証」case 5）

## 6. 検証 (Verification)

### レンダリング結果の構文検査

`.nix` の文字列として書いているので、**評価後のテキスト**を検査した。

```console
$ nix eval --raw './nix#homeConfigurations."pollenjp@wsl".config.programs.bash.initExtra' > bash_init.sh
$ bash -n bash_init.sh && echo ok
ok
$ nix eval --raw './nix#homeConfigurations."pollenjp@wsl".config.programs.fish.interactiveShellInit' > fish_init.fish
$ fish -n fish_init.fish && echo ok
ok
```

### fish の複数行 `and` が条件として解釈されるか

条件を継続行に分けて書いているので、`and` が body の 1 文目に落ちていないことを
実測した（落ちていると 3 番目の条件が効かない）。

```console
$ fish -c 'if true; and true
    and false
    echo BODY-RAN
  end'
                      # 出力なし = 条件として解釈されている
$ fish -c 'if true; and true
    and true
    echo BODY-RAN
  end'
BODY-RAN
```

fish 4.8.1 で確認。

### 挙動（bash / fish の両方で同一）

レンダリング済みの `299_ssh_agent` ブロックだけを切り出し、偽の `HOME`、
`python3` で作った実 unix socket、stub の `ssh-add` / `ssh-agent` で回した。
stub の `ssh-add` は本物に寄せて **`SSH_AUTH_SOCK` が生きた socket のときだけ成功**
させ、WSL の `ssh-add.exe`（`SSH_AUTH_SOCK` を見ない）は「常に成功」モードで表した。

| # | 状況 | 期待 | 実測 |
| --- | --- | --- | --- |
| 1 | ssh 先のログイン shell / forward socket が生きている | 張り替え + `SSH_AUTH_SOCK` が固定名になる | `SSH_AUTH_SOCK=~/.ssh/agent.sock`、リンクは実 socket を指す ✓ |
| 2 | herdr の pane / env が古く固定名は生きている | 固定名を拾う（ローカル agent へ倒れない） | `SSH_AUTH_SOCK=~/.ssh/agent.sock` ✓ |
| 3 | logout 中 / 固定名が dangling | 拾わず既存フォールバックへ | ローカル agent（従来どおり）✓ |
| 4 | WSL のローカル shell / 1Password が応答 | 何も起きない | `SSH_AUTH_SOCK` 未設定のまま、リンクも作られない ✓ |
| 5 | ssh 先だが `~/.ssh` が無い | `ln` がエラーを出す（想定内・到達しない） | `ln: failed to create symbolic link ...: No such file or directory` |
| 6 | 2 回目のログイン / 固定名が古い socket を指している | 新しい socket へ張り替え | リンクが新しい socket を指す ✓ |

fish 側も 1〜4 と 6 を同じ条件で回し、**bash と同一の結果**を確認した。

### 静的検査

```console
$ nix develop ./nix --command bash -c 'find nix -name "*.nix" -print0 | xargs -0 nixfmt --check'
$ nix flake check --all-systems --no-build ./nix
```

### 検証していないこと

- **実機での再現と復旧**（ssh → herdr 起動 → detach → logout → 再 ssh → 鍵が引けるか）。
  適用後に実機で確認する（「7. 移行・運用手順」）
- 複数 ssh を同時に張ったときの「最後のログインが勝つ」挙動は、コード上明らかなので
  実測していない
- `herdr --remote` が内部で agent forwarding を有効にするかどうか（案 B を足すかの判断材料）

## 7. 移行・運用手順

```sh
~/dotfiles/setup --update            # home-manager switch
```

適用しても、**すでに走っている herdr server は古い env を抱えたままである。**
どちらかで移行する。

```sh
# A. 作り直してよいとき
herdr server stop
# ssh し直す (固定名が export された shell になる) → herdr を起動

# B. 走っている session を止めたくないとき
#    session の中で 1 回打てば、以降そのプロセスではずっと有効
export SSH_AUTH_SOCK=~/.ssh/agent.sock
```

実機で確認すること。

```sh
# ssh 先のログイン shell で
echo "$SSH_AUTH_SOCK"           # ~/.ssh/agent.sock を指すこと
readlink ~/.ssh/agent.sock      # /tmp/ssh-XXXXXX/agent.<pid> を指すこと
ssh-add -l                      # 1Password の鍵が並ぶこと

# detach → logout → 再 ssh → herdr に attach したあと、pane の中で
ssh-add -l                      # 鍵が並ぶこと (これが本題)
```

## 8. 参考 (References)

- [`sshd(8)`](https://man.openbsd.org/sshd.8) — SSHRC 節（案 B の前提）、
  LOGIN PROCESS の step 8、`restrict` が `~/.ssh/rc` の実行も無効にすること
- [`sshd_config(5)`](https://man.openbsd.org/sshd_config.5) — `PermitUserRC`（既定 `yes`）、
  `PermitUserEnvironment`（既定 `no`）
- [ADR 004](../004_nix_wsl_ssh_wrapper_20260811T124616JST/README.md) —
  WSL で `ssh` / `ssh-add` が Windows 側の実体になる仕組み
