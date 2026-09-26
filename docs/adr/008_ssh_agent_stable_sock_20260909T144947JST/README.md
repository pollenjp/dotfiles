# ADR: ssh 先で herdr を開くときだけ、forward された ssh-agent を固定名の symlink へ張り替える

| 項目 | 内容 |
| --- | --- |
| ステータス | 提案 (Proposed) — レビュー中 |
| 日付 | 2026-09-09 (JST) |
| 改訂 | 2026-09-26 (JST) — レビュー中に決定を変えた。初版の「ログインのたびに shell の init が自動で張り替える」をやめ、「herdr を開くときだけ明示的に張り替える」にした（初版は「4. 検討した代替案」の案 A） |
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
   server は起動した client の env を継ぎ、pane はその server の env を継ぐ。
   つまり `SSH_AUTH_SOCK` は **server を起動した時点の接続の値**で固定される
3. **実行中プロセスの環境変数は外から書き換えられない。** 常駐している server と、
   その中で走り続けている shell や agent の `SSH_AUTH_SOCK` を後から直す方法は無い

| 時点 | `/tmp` の実体 | herdr server が抱える env |
| --- | --- | --- |
| ssh #1（`ForwardAgent yes`） | `/tmp/ssh-A/agent.1` 誕生 | — |
| herdr 起動 | 〃 | `SSH_AUTH_SOCK=/tmp/ssh-A/agent.1` を捕獲 |
| detach → logout | sshd が `/tmp/ssh-A` を削除 | 捕獲したまま（指す先が消滅） |
| ssh #2 | `/tmp/ssh-B/agent.2` 誕生 | **変わらない ← ここが問題** |

### 既存のフォールバックが、この状況を分かりにくい形で悪化させる

`nix/home/modules/bash.nix` / `fish.nix` の `299_ssh_agent` 複製ブロックは、
`ssh-add -l` が失敗すると次の順に倒れる。

1. 保存済みの `~/.ssh-agent` を読む（そこに書かれた agent も死んでいることが多い）
2. **ローカルに `ssh-agent` を起こし、`~/.ssh/id_ed25519` を `ssh-add` する**

herdr の pane で 2 に落ちると、forward されてきた 1Password の鍵とは**別の鍵を持つ agent**へ
静かにすり替わる。`ssh-add -l` は応答するので一見復旧したように見え、
「agent は生きているのに鍵が違う」という一番切り分けにくい壊れ方をする。

## 2. 決定 (Decision)

**固定名 `~/.ssh/agent.sock` を 1 枚挟み、ssh 先で herdr を開くときだけ、その接続が forward してきた socket へ張り替える。**
herdr のプロセスには固定名だけを渡し、ログイン shell の `SSH_AUTH_SOCK` は変えない。

変えられないもの（実行中プロセスの env）はそのままにして、変えられるもの
（パスが指す実体）を動かす。tmux + agent forwarding で古くから使われている定石で、
**すでに走っているプロセスまで直せる方法はこの形しかない。**

| # | 置き場所 | 役割 |
| --- | --- | --- |
| 1 | `ssh-agent-link` 関数 | 固定名を、この shell の接続が forward してきた socket へ向ける。手で打って「今の接続へ向け直す」にも使える |
| 2 | `herdr` 関数（同名のコマンドを包む） | ssh 先（`SSH_CONNECTION` がある）では 1 を呼んでから、`SSH_AUTH_SOCK=~/.ssh/agent.sock` を付けて本物の herdr を起動する。手元では素通し |
| 3 | init の `299_ssh_agent` ブロック | `SSH_AUTH_SOCK` が固定名の shell（= herdr の pane）では、ローカル agent へのフォールバックをしない |

既存の alias（`h` / `hss` / `ha` / `hkill` ほか）は `herdr` を呼ぶので、全部 2 を通る。

### なぜ herdr を開くときだけか

固定名が要るのは、ssh の接続より長生きする herdr だけ。だから張り替えも「herdr を開いた接続」に限れば足りる。

| | ログインのたびに自動で張り替える（案 A） | herdr を開くときだけ（本決定） |
| --- | --- | --- |
| 覗くだけの 2 本目の ssh | 固定名を奪い、閉じると他の接続まで失敗する | **影響なし** |
| herdr の外の素の shell | 固定名を使うので、他の接続が切れると巻き添えになる | **自分の接続の socket をそのまま使う**。巻き添えにならない |
| 回線断のあと ssh し直して herdr を開く | ログインした時点で新しい接続へ移る | herdr を開いた時点で新しい接続へ移る（同じ） |
| 別のマシンへ移る | ログインした時点で移る | herdr を開いた時点で移る（同じ） |

張り替えるときに `ssh-add` を呼ばない（指す先が生きているかを確かめない）のも意図したもの。
確かめる形にすると、回線断で sshd に残った古い socket に対して `ssh-add` が応答待ちのまま固まる（案 B）。

### `ssh-agent-link` が張らないもの

| 張らない | 理由 |
| --- | --- |
| `SSH_AUTH_SOCK` が socket でない | forward されていない shell（手元の WSL、`ssh -a`）。張る元が無い |
| `SSH_AUTH_SOCK` が固定名そのもの | herdr の pane の中で打った場合。張ると自分自身を指す symlink になり、`ln -sfn` は **exit 0 のまま**生きていたリンクを壊す（`Too many levels of symbolic links`、実測） |
| `SSH_AGENT_PID` が入っている | その `SSH_AUTH_SOCK` は既存のフォールバックが起こした（か `~/.ssh-agent` から読んだ）ローカル agent。`ssh -a` で入った shell がこれになる。張ると forward された鍵が `~/.ssh/id_ed25519` にすり替わる。sshd の forward では `SSH_AGENT_PID` は入らない |

### ssh 先では forward の無い接続からでも固定名を渡す

`herdr` 関数は、`SSH_CONNECTION` があれば forward の有無に関係なく `SSH_AUTH_SOCK=~/.ssh/agent.sock` を付ける。
`ssh -a` で入って最初に herdr server を起動したとき、固定名を渡さないと、その server の pane は寿命が尽きるまで
agent 無しになるため。固定名の指す先は、あとで forward 付きの接続から herdr を開いたときに張り替わる。

手元（`SSH_CONNECTION` が無い）では何も変えない。WSL の `ssh` / `ssh-add` は Windows 側の実体で
`SSH_AUTH_SOCK` を見ないので（ADR 004）、固定名を渡す意味も無い。

### pane ではフォールバックしない

固定名が dangling なのは、forward した接続が 1 本も無いあいだだけで、次に herdr を開けば戻る。
そのあいだに init がローカル agent を起こすと、その pane だけ別の鍵に固定され、固定名が戻っても元に戻らない。
detach 中でもエージェント（Claude Code など）は `herdr pane split` で pane を作れるので、この経路は実際に踏む。
`SSH_AUTH_SOCK` が固定名の shell では、フォールバックごと何もしない。

### なぜこれで安全性が下がらないか

| 論点 | 評価 |
| --- | --- |
| 到達権限 | 広がらない。アクセス制御は実 socket 側（`/tmp/ssh-XXXXXX` は 0700・本人所有、sshd が作る）で効いており、symlink を辿るときも target の権限チェックはそのまま働く。同一 UID のプロセスと root は元々 `/tmp` を走査すれば実 socket に到達できるので、symlink は「覚えやすい別名」を足すだけ |
| 固定名の置き場 | `~/.ssh`（0700）に置く。world-writable な `/tmp` に固定名を置く亜種（先取り・すり替えの温床）は採らない。`$XDG_RUNTIME_DIR` も採らない（最後の logout で消えるので、まさに herdr だけが生き残る今回の窓と最悪の相性。非 systemd 環境には存在しない） |
| 切断中の鍵 | **使えないままに保たれる。** logout 中はリンクが dangle するだけで、herdr 内の ssh は失敗する。不在中に鍵が使える方が危険なので、これは forwarding の良い性質を壊していない（棄却した案 D はこの性質を失う）。pane でのフォールバックも止めたので、ローカルの鍵で代わりに通ることもない |
| 残余リスク | 従来と同一。接続中は remote の root / 同一 UID プロセスが agent に署名を頼める。これは forwarding 自体の性質で symlink の有無と無関係。実質の緩和は 1Password 側の承認ダイアログ。OpenSSH agent の `ssh-add -c` や destination constraint (`ssh-add -h`) は 1Password agent に無いのでここでは使えない |

## 3. 変更点の詳細

| ファイル | 変更 |
| --- | --- |
| `nix/home/modules/bash.nix` | `299_ssh_agent` ブロックに「固定名の shell では何もしない」を足し、`ssh-add -l` の判定を 1 回にまとめた。直後に `ssh-agent-link` と `herdr` の関数を足した |
| `nix/home/modules/fish.nix` | 同じ内容を fish 構文で（関数は `programs.fish.functions`）。挙動は bash と一致（「6. 検証」） |
| `nix/README.md` | 「ssh について」に節を追加 |

### 既存フォールバックの判定を 1 回にまとめた

元のコードは、agent が生きているときも `ssh-add -l` を 2 回呼んでいた（フォールバックの if が 2 つ並び、それぞれが呼ぶ）。
WSL では `ssh-add` が interop 越しの `ssh-add.exe` になり 1 回あたりのコストが無視できないので、
最初の判定を 1 回にまとめ、以降はその中へ入れ子にした。herdr の pane（固定名）では 1 回も呼ばない。

### レガシー経路 (`shell/299_ssh_agent.sh` / `.fish/299_ssh_agent.fish`) を触らない

[ADR 001 の決定 3](../001_home_manager_migration_20260808T163454JST/README.md)
（既存ツリーは一切変更せず、`main.bash setup` で戻せる状態を保つ）に従う。

レガシー経路が現役なのは Windows (MINGW) と復旧用途で、いずれも
「ssh 先の Linux で herdr を常駐させる」今回の対象ではない。
**ただし ssh 先のマシンがまだ `main.bash setup` 運用なら、この修正はそこには届かない。**
その場合は当該マシンを Nix 経路へ移すのが筋（レガシー側への複製は行わない）。

## 4. 検討した代替案

### 案 A: ログインのたびに shell の init が自動で張り替える（後勝ち、PR #72 の初版）

`SSH_CONNECTION` があり、forward された socket が生きているログイン shell で、無条件に固定名を張り替え、
ログイン shell の `SSH_AUTH_SOCK` も固定名にする。**採らない。**

- **後勝ちになる。** 覗くだけの 2 本目の ssh でも固定名を奪う。**最新の接続が先に切れると、古い接続が
  まだ生きていても全員（古い接続のログイン shell を含む）が agent を失い、次のログインまで戻らない**（実測）
- ログイン shell の中で起動した入れ子の shell も `SSH_CONNECTION` を継ぎ、`SSH_AUTH_SOCK` は既に固定名なので、
  「固定名と違うこと」の比較が入れ子の shell を起動するたびに効く本流のガードになる。無いと `ln -sfn` が自己参照リンクを作る
- 素の shell まで固定名に依存するので、壊れたときの影響範囲が herdr の外にまで広がる

### 案 B: 有効な固定名があれば張り替えない（先勝ち）

案 A の「2 本目が奪う」を避ける形。**採らない。**

- 回線断やスリープのあとに ssh し直す場面で壊れる。sshd は相手が消えたことに気づくまで
  （既定の `ClientAliveInterval 0` では TCP のタイムアウト任せ）古いセッションと socket を残し、
  そこへの接続は受け付けるが agent の要求には返事をしない
- `ssh-add` には応答待ちのタイムアウトが無い（本物の `/usr/bin/ssh-add` で実測）。先勝ちだと固定名は古い socket を
  指したままになり、**新しいログインの init が `ssh-add -l` で固まる**。「有効か」を socket ファイルの有無で見ても、
  `ssh-add` で繋いで見ても、同じく固まった（実測）
- `timeout 1` を付ければ固まらないが、古い接続が残っているあいだはログインのたびに最大 1 秒待つ。
  別のマシンへ移ったあとも 1Password の承認ダイアログが元のマシンに出続ける

### 案 C: `~/.ssh/rc` で張り替える

sshd がセッション開始直前に `sh(1)` で実行するユーザーフック（`PermitUserRC` の既定は `yes`）。
**採らない。** 非対話の接続でも走るが、自動で張り替える点は案 A と同じで、案 A の問題をそのまま持つ。
加えて、stdout に 1 byte でも書くと git-over-ssh などのデータストリームを壊す、
rc を置くと sshd が xauth を自動で呼ばなくなる、といった落とし穴が増える。

### 案 D: remote に常駐 agent を置き、鍵も remote に持つ

systemd user unit + linger で固定 socket を持たせる方式。**採らない。**
「鍵は 1Password に集中させ、remote には秘密鍵を置かない」という現方針に反する。
さらに detach 中も鍵が生きたままになるので、安全性は下がる方向に動く。

### 案 E: herdr 側で attach 時に env を更新する（tmux の `update-environment` 相当）

仮に同等機能があっても**新しい pane にしか効かない**。すでに走っている
Claude Code や shell の env は誰にも変えられないので、今回の症状の中心
（detach したまま生き続けている session）は救えない。加えて herdr は
mise 管理の外部ツールで、こちらから手を入れる対象でもない。

## 5. 影響 (Consequences)

### 良くなること

- ssh を張り直して herdr を開けば、**detach 済みの herdr session がそのまま鍵を使える**
- 覗くだけの 2 本目の ssh は固定名に触れない。herdr の外の素の shell は他の接続に巻き添えにならない
- 回線断のあとの再接続で固まらない（張り替えるときに `ssh-add` を呼ばない）
- herdr の pane が、別の鍵を持つローカル agent へ静かに倒れなくなる
- WSL の手元の shell と herdr の挙動は変わらない
- `ssh-add` の呼び出しが対話 shell あたり 1 回減る（WSL で体感差が出る）

### 注意が必要なこと

- **herdr を関数を通さずに起動すると固定名が入らない。** `command herdr` やスクリプトから server を
  起動した場合がこれ。その server の pane は起動した接続の socket を抱えたままになる
- **2 つの接続から同時に attach し、後から開いた方を先に閉じると失敗する。** 固定名が閉じた方を指したまま
  dangling になるため。detach して `herdr` で開き直すか、生きている方のログイン shell（herdr の外）で
  `ssh-agent-link` を打てば戻る
- **誰も forward していないあいだは、herdr の中から鍵は使えない。** これは意図した性質（「2. 決定」の安全性の表）
- **すでに走っている herdr server には効かない。** 古い env を抱えたままなので、適用後に一度作り直す（「7. 移行・運用手順」）
- `ssh -a` で入った shell では、従来どおり既存のフォールバックがローカル agent を起こす（今回は変えていない）。
  `ssh-agent-link` はそれを張らない
- 既存のフォールバックは `ssh-add -l` の exit 1（agent には繋がるが鍵が 0 本）も「agent 無し」として扱う。
  forward された agent の鍵が 0 本のとき（1Password がロック中など）は、ログイン shell の `SSH_AUTH_SOCK` が
  ローカル agent に置き換わり、その shell からは `ssh-agent-link` が張らない。従来からの挙動で、今回は変えていない
- `ln -sfn` は unlink → symlink の 2 手なので厳密には atomic ではない。競合し得るのは同一 UID の自分の操作だけなので許容する
- `~/.ssh` が存在しないと `ln` がエラーを出す。`programs.ssh.enable = true` が全ホストで `~/.ssh/config` を
  書く（`ssh.nix`）ので、実際には到達しない

## 6. 検証 (Verification)

### 静的検査

```console
$ nix develop ./nix --command bash -c 'find nix -name "*.nix" -print0 | xargs -0 nixfmt --check'
$ nix flake check --all-systems --no-build ./nix
```

`.nix` の文字列として書いているので、**評価後のテキスト**も構文検査した
（`nix eval --raw ...config.programs.bash.initExtra` を `bash -n`、
`...fish.interactiveShellInit` と `...fish.functions.<名前>.body` を `fish -n`）。

### 挙動（bash / fish の両方で同一）

描画済みの init ブロックと関数を切り出し、偽の `HOME`、python で実際に bind した unix socket、
stub の `ssh-add` / `ssh-agent` / `herdr` で回した。stub の `ssh-add` は `SSH_AUTH_SOCK` が生きた socket のときだけ成功し、
WSL の `ssh-add.exe`（`SSH_AUTH_SOCK` を見ない）は「常に成功」で表した。stub の `ssh-agent` は本物と同じく
socket を作って `SSH_AGENT_PID` を出す。stub の `herdr` は受け取った `SSH_AUTH_SOCK` を出す。

| # | 場面 | 結果 |
| --- | --- | --- |
| 1 | 手元（WSL）で herdr | shell も herdr も `SSH_AUTH_SOCK` 未設定のまま。固定名は作られない |
| 2 | 接続 A でログインし herdr | ログイン shell は A の socket のまま。herdr は固定名を受け取り、固定名は A を指す |
| 3 | herdr の pane。中で herdr も打つ | pane は固定名で A に届く。中で打った herdr は固定名を張り替えない（自己参照にならない） |
| 4 | 接続 B で覗くだけ → 閉じる | 固定名は A のまま。B を閉じたあとも pane は A に届く |
| 5 | `ssh -a` の接続 D でログインし herdr | D の shell はフォールバックでローカル agent になるが、固定名は A のまま（張り替えない） |
| 6 | A が切れたあとに pane が作られる | 固定名は dangling。pane は固定名のままで、ローカル agent を起こさない |
| 7 | 接続 C でログインし herdr | 固定名は C へ移り、既存の pane も C に届く |

### 代替案の実測

| 案 | 場面 | 結果 |
| --- | --- | --- |
| A（後勝ち） | A → B でログイン → B だけ切断 | A は接続中なのに、A のログイン shell も pane も失敗。次のログインで戻る |
| A（後勝ち） | 「固定名と違うこと」の比較を外し、入れ子の shell を起動 | `ln -sfn` が exit 0 のまま自己参照リンクを作り、`Too many levels of symbolic links` |
| B（先勝ち） | 返事をしない socket（回線断で残った接続）を固定名が指す状態から再ログイン | socket ファイルの有無で判定する版も、`ssh-add` で判定する版も、init が固まった（8 秒で打ち切り） |
| — | 本物の `/usr/bin/ssh-add` を返事をしない socket へ | `timeout 3` に打ち切られるまで待ち続けた（ssh-add に応答待ちのタイムアウトは無い） |

### 検証していないこと

- **実機での再現と復旧**（ssh → herdr 起動 → detach → logout → 再 ssh → herdr → pane で鍵が引けるか）。
  適用後に実機で確認する（「7. 移行・運用手順」）
- herdr server が起動した client の env を継ぐこと。手元の server の environ に、起動元の shell が足した
  mise の PATH が入っていることは見たが、ssh 先で `SSH_AUTH_SOCK` が継がれることは実機で確かめる
- sshd が回線断のセッションを残すことそのもの（手元で sshd を立てて回線を切る形では確かめていない。
  sshd の既定値と、agent 転送がセッションの TCP 接続を通ることからの推論）

## 7. 移行・運用手順

```sh
~/dotfiles/setup --update            # home-manager switch
```

適用しても、**すでに走っている herdr server は古い env を抱えたままである。** 一度作り直す。

```sh
herdr server stop
# ssh -A でログインし直して、herdr で開く (関数が固定名を渡して server を起動する)
herdr
```

実機で確認すること。

```sh
# ssh 先のログイン shell で herdr を開いたあと
readlink ~/.ssh/agent.sock      # /tmp/ssh-XXXXXX/agent.<pid> (今の接続) を指すこと
tr '\0' '\n' </proc/"$(pgrep -f 'herdr server' | head -1)"/environ | grep SSH_AUTH_SOCK
                                # SSH_AUTH_SOCK=~/.ssh/agent.sock (展開済みのパス) であること

# pane の中で
ssh-add -l                      # 鍵が並ぶこと

# detach → logout → 再 ssh → herdr で開き直したあと、pane の中で
ssh-add -l                      # 鍵が並ぶこと (これが本題)
```

herdr の中で鍵が引けなくなったら、detach して `herdr` で開き直す（固定名が今の接続へ向き直る）。

## 8. 参考 (References)

- [`sshd(8)`](https://man.openbsd.org/sshd.8) — SSHRC 節（案 C の前提）、
  LOGIN PROCESS の step 8、`restrict` が `~/.ssh/rc` の実行も無効にすること
- [`sshd_config(5)`](https://man.openbsd.org/sshd_config.5) — `PermitUserRC`（既定 `yes`）、`ClientAliveInterval`（既定 `0`）
- [ADR 004](../004_nix_wsl_ssh_wrapper_20260811T124616JST/README.md) —
  WSL で `ssh` / `ssh-add` が Windows 側の実体になる仕組み
