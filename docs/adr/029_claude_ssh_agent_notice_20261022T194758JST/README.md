# ADR: Claude の作業が SSH agent (1Password) を使う前に hook で知らせ、断られたら打ち直さずに選択肢の問いを出させる

| 項目 | 内容 |
| --- | --- |
| ステータス | 承認 (Accepted) — 方針は 2026-10-22 にユーザーが承認。文面は PR でレビュー |
| 日付 | 2026-10-22 (JST) |
| 決定者 | pollenjp |
| チケット | [TKT-317](https://app.notion.com/p/Claude-1Password-SSH-agent-herdr-hook-2-TKT-294-40179149a66f814ba604e1af911da5aa)（集約ハブの会話は [TKT-294](https://app.notion.com/p/infra-v2-pjp-wolf-NixOS-VM-TKT-243-PR-7-merge-40179149a66f81c4a513f0a330c60977)） |
| 関連 ADR | [025_herdr_agent_borrow](../025_herdr_agent_borrow_20261020T210555JST/README.md)（herdr の中の agent は手元の PC から転送された接続を借りる）、[019_claude_run_through_after_approval](../019_claude_run_through_after_approval_20261016T150008JST/README.md)（hook で Claude に文を足す前例） |
| 運用手順 | [`nix/README.md`「1Password の SSH 承認を知らせるフック」](../../../nix/README.md#1password-の-ssh-承認を知らせるフック) |
| 設計 | [`docs/superpowers/specs/2026-10-22-ssh-agent-notice-design.md`](../../superpowers/specs/2026-10-22-ssh-agent-notice-design.md)（承認した設計の書き写しと、実装の細部） |

---

## 1. 背景 (Context)

ユーザーの依頼 (原文):

> あと、ss-agent (1password の ssh-agent) の承認が来るようなタイプのリクエストを claude の作業の中で投げる際は事前に通知してほしいけど事前に調べるのは少しコスト高いかな？
> ユーザー (僕) はどこから送られたリクエストかわからないものは deny するようにしているので。
> ※tokenコスト高くなりそうなら失敗した後ユーザーにssh-agentの承認を依頼するような選択肢型の質問を提示して欲しい。
> これを skill に落とし込めるかな

| 事実 | 出どころ |
| --- | --- |
| herdr の中の `SSH_AUTH_SOCK` は固定名 (`~/.ssh/agent.<session>.sock`) で、手元の PC から SSH の接続で転送された agent (`~/.ssh/agent/s.*.sshd.*`) を指す | ADR 025 |
| 1Password は手元の PC で動き、承認の画面もそこに出る。lavie のどの pane・どの Claude が頼んだかは出ない | ユーザー |
| 2026-10-22、固定名が 08:59 の接続の口を指し、承認の画面はその接続の端末に出ていた。ユーザーは気づけず、infra-v2 の子の ssh が断られた。11:54 の接続の口へ切り替えたら通った | 集約ハブの会話 (TKT-294) |
| 承認の画面がいつ出るかは 1Password の設定 (承認を覚える時間・ロック) で決まり、Claude の側からは分からない | 1Password の設定 |
| **Claude の会話の git の commit・tag は無署名**。dotfiles が Claude の会話にだけ `commit.gpgsign=false`・`tag.gpgsign=false` を env で入れている (`claude.nix` の `gitConfigBase`)。main の Claude の commit も無署名 | `git cat-file -p` と hook の env の実測 |
| GitHub の remote は https (Claude の会話は ssh の URL も https に読み替える) で、push・fetch は agent を使わない | 各 repo の remote・`gitViaGh` |

## 2. 決定 (Decision)

### A. 前もって調べるのは hook (script) にさせ、skill は作らない

Bash を打つたびに「agent を使うか」を Claude に判断させると、その分の token を毎回使い、子・subagent の読み忘れで
抜ける。hook なら script がコマンドの文字を見るだけで token を使わず、このユーザーの Claude Code の会話なら全部
(ハブ・子・subagent) で同じに動く。拾えない道具 (script の中で ssh を打つものなど) は、断られたあとの問いで受ける。
決まり (打ち直さない・問いの形) は数行なので、hook が Claude に足す文に書く。

### B. 1 本の script を 3 つの event に登録する

`nix/files/claude/hooks/ssh-agent-notice.sh` を、`bootstrap-claude-hook.sh` が PreToolUse・PostToolUse・
PostToolUseFailure (どれも matcher `Bash`) に登録する。今の Claude Code (2.1.306) で、使い捨ての `--settings` を
付けた `claude -p` で確かめた。

| 事実 | 効き方 |
| --- | --- |
| 0 以外で終わった Bash には PostToolUse が来ず、PostToolUseFailure が来る (入力の `error` は `Exit code <n>` の行と出力) | 断られた ssh・git は失敗で終わるので、PostToolUseFailure にも登録する |
| PreToolUse の `systemMessage` は画面に出て Claude には渡らない。PostToolUseFailure の `additionalContext` は Claude に届く | 打つ前の知らせは token を使わない。断られたときだけ Claude に文を足す |
| hook の env には settings.json の `env` (`GIT_CONFIG_*`) と `HERDR_*`・`SSH_AUTH_SOCK` が入る | git の実効の設定と herdr の pane を hook の中で引ける |

### C. 打つ前に当てるもの

コマンドの文字を awk で単純コマンドに分け (引用符・heredoc の本文・コメントを外し、`$( )` などの中も見る。包む
コマンドを外し、`bash -c` などは読み直す)、最初に当たったものを会話の画面の 1 行と herdr の通知で知らせる。
コマンドは止めない。

| 種類 | 当てるもの |
| --- | --- |
| ssh の接続 | `ssh`・`scp`・`sftp`・`ssh-copy-id`・`sshfs`・`mosh`・`autossh`、`rsync` の `<host>:`、`nixos-rebuild` の `--target-host`・`--build-host`、`nix-copy-closure`、`nix` の `ssh://`、git の clone・fetch・pull・push・ls-remote で相手の URL が ssh |
| 署名 | git の commit・merge・rebase・cherry-pick・revert・am・pull・commit-tree・tag・`push --signed` で、**署名するとき**。`ssh-keygen -Y sign`・`ssh-add -T` |
| 設定の一覧 | host option `dotfiles.claude.sshAgentNotice.extraCommands` の項目 (中で ssh を打つ道具) |

git が署名するかは、hook の中で git に実効の設定 (`commit.gpgsign` など。コマンドの `-c`・`-C` も渡す) を聞いて
決める。hook の env は Claude の会話と同じなので、会話の Bash と同じ答えになる。Claude の会話の素の `git commit`
は当たらず、`-S` や `-c commit.gpgsign=true` のときだけ当たる。

### D. 承認の画面が出る接続を見せる

`SSH_AUTH_SOCK` の symlink の先が sshd の転送した agent なら、「`<月/日 時:分>` に `<PJP_SSH_CLIENT>` から入った
接続の端末に出る」と出す (pjp-agent-link の記録の時刻と値。無ければ socket の時刻)。同じ dir により新しい接続が
あれば添える (今日の取り違えに気づける)。手元の 1Password の口ならその path、先が無ければ「出ない」と出す。
`SSH_AUTH_SOCK` が空なら、WSL では「Windows の 1Password が出す (要求元は「Windows Terminal」としか出ない)」
(WSL の `ssh` は Windows の `ssh.exe` へのラッパー)、ほかでは「どこに出るかは分からない」と出す (ssh の設定の
`IdentityAgent` で agent を使うことがある)。

### E. herdr の通知は同じ pane から 10 分に 1 回

`HERDR_ENV=1` なら `herdr notification show` を `--sound request` で出す。body は「どこから (workspace の名前・
pane・agent の名前)」・コマンドの頭・接続の 3 行。同じ pane からは 600 秒に 1 回 (commit を続けても鳴らし続け
ない)。会話の画面の 1 行は毎回出す。断られたときの通知は間引かない。herdr は 2 秒で切って呼び (`timeout` の無い
マシンでは裏で流して見張る)、落ちた・返事をしないときは、その回の残りと続く 60 秒は呼ばない (返事をしない herdr で
Bash を毎回待たせない)。

### F. 断りの見分け方

偽の agent (鍵を見せて署名を断る・接続を切る) と使い捨ての sshd で、ssh・scp・git の文言を集めて決めた。

| 理由 | 文言 |
| --- | --- |
| 断られた | `agent refused operation` (ssh・scp は `sign_and_send_pubkey: …` の行、git の署名は `Couldn't sign message (signer): …?` の行) |
| 通信が切れた | `communication with agent failed` (同じ形) |
| 届かない | git の署名の `Couldn't get agent socket`・`Couldn't load public key …/.git_signing_key_tmp…`、鍵の認証の失敗 (`Permission denied (publickey)`) で agent の口があってその先が無いとき (ssh は口が無いと何も言わない。口が空なら agent を使っていないので当てない) |

OpenSSH は自分のエラー行を `\r\n` で終え、Claude Code は tool の出力の `\r` を残すので、`\r` を外してから見る
(git は ssh-keygen の出力の `\r` を `?` に変えて出す)。どれも行の終わりが文言のときだけ当てる (ssh・git の行は文言で
終わり、diff・コード・文書の行はそうでない)。成功した Bash は行の頭も ssh・git の出す形に固定する。`2>&1 | tail` で
終了コードが隠れた断りは拾い、成功した grep・cat の結果や、失敗した diff・cat に出た文言では当てない。

### G. Claude に足す文

「同じコマンドを打ち直さない。何を (コマンドの頭) と、どこから (workspace・pane・agent) を書いてから、
① 直し方 (推奨) ② この手順を飛ばして進める ③ ここで止める の問いを出す」。① は、断られたら「1Password を開いて
承認する」、通信が切れた・届かないなら agent の口の種類ごと (転送された接続 → このマシンへ接続し直す、手元の口 →
1Password を起動してロックを解除する、WSL で空 → Windows の 1Password を起動する、空 → SSH_AUTH_SOCK を設定する)。
herdr の指揮役の子は AskUserQuestion を使わず、問いを書いてターンを終える (workspace の名前が 🌱 で始まれば、子だと
言い切る)。subagent の中では問いを出させず、報告に書いて終えさせる。

### H. 方針の承認のあとに、こちらで決めたこと

| 問い | 決めたこと | 理由 |
| --- | --- | --- |
| 設計の一覧の git の commit をいつも当てるか | 署名するときだけ当てる (C) | Claude の会話の commit は無署名で承認の画面が出ない。当てると承認の出ない commit のたびに知らせる |
| ssh の remote への git を当てるか | 当てる (insteadOf を解いた URL で見る) | GitHub は https なので当たらないが、ほかの ssh の remote は agent を使う |
| script を 2 本に分けるか | 1 本にし、event で分ける | 接続の見せ方・どこからの引き方・通知を共にする |
| 断られたときの通知を間引くか | 間引かない | 毎回、人の手が要る |
| agent に届かないときも問いを出すか | 出す (1 つ目の選択肢は口の種類ごとの直し方) | 08:59 の口のように、接続が閉じると同じ形で止まる。手元の 1Password や WSL では直し方が違う |
| 失敗した Bash の断りを部分一致で見るか | 見ない (行の終わりに固定する) | 最終レビューで、失敗した diff・cat で誤って当たる (Claude が止まり、音が鳴る) と指摘された |
| 長いコマンドを読むか | 64 KB まで (gawk・mawk が無ければ 16 KB) | macOS の awk は長さの二乗で遅く、80 KB で十数秒かかった (最終レビュー)。この hook は Bash のたびに走る |
| subagent の中で問いを出させるか | 出させず報告に書かせる | subagent はユーザーに聞けない |
| `SSH_AUTH_SOCK=<path>` を頭に付けたコマンド | その path を接続として見せる | 指揮役が子に「この口で commit して」と渡す形がある |
| ADR の番号 | 029 | 028 は open の TKT-312 が使っている |

## 3. 変更点の詳細

| ファイル | 変更 |
| --- | --- |
| `nix/files/claude/hooks/ssh-agent-notice.sh` | 新規。打つ前の知らせ (C・D・E) と断られたあとの指示 (F・G) |
| `nix/tests/ssh-agent-notice.test.sh` | 新規。当たり・外れの表、git の設定・remote、接続の形、herdr の通知と間引き、断りの見分け方と文 |
| `nix/home/options.nix` | `dotfiles.claude.sshAgentNotice.extraCommands` (文字列のリスト、既定 `[ ]`) |
| `nix/home/modules/claude.nix` | hook と `~/.local/state/dotfiles/claude-ssh-agent-notice.json` を置く |
| `nix/tests/claude-ssh-agent-notice.nix` | 新規。option の既定・JSON・hook の置き方を評価時に確かめる |
| `nix/scripts/bootstrap-claude-hook.sh`・`nix/tests/bootstrap-claude-hook.test.sh` | 3 件の登録 |
| `nix/flake.nix` | checks に `ssh-agent-notice-test`・`claude-ssh-agent-notice-state` |
| `nix/lib/mk-home.nix` | `claude` 引数の例 |
| `nix/README.md` | 状態ファイルの表・フックの節・「commit を無署名にする」からの参照 |

## 4. 検討した代替案

| 案 | 採らなかった理由 |
| --- | --- |
| skill にして Claude に判断させる (ユーザーの最初の問い) | Bash のたびに token を使い、子・subagent の読み忘れで抜ける (A) |
| 承認の画面が本当に出るかを前もって判定する (署名を試す) | 判定には署名が要り、それ自体が承認の画面を出す |
| git の commit をいつも当てる (設計の一覧どおり) | H の 1 行目 |
| コマンドの文字を正規表現で探すだけにする | commit のメッセージや heredoc の本文に ssh と書くたびに当たる。この repo の作業がまさにそう |
| shfmt で構文木にして読む | 全マシンの hook の実行時に shfmt が要る (今は devShell にしか無い) |
| 断りを部分一致で見る (計画の段階では、失敗した Bash だけそうしていた) | この hook の文書やテストを cat・grep・diff するたびに当たる。失敗した diff・cat でも当たり、Claude が止まって音が鳴る (最終レビュー) |
| herdr の通知を毎回鳴らす | commit や ssh を続けるたびに鳴る |

## 5. 影響 (Consequences)

### 良くなること

- agent を使うコマンドの前に、どの pane・何を・どの接続の端末に承認の画面が出るかが、herdr の通知 (音つき) と
  会話の画面に出る。より新しい接続があることも分かる
- 断られたら、Claude は打ち直さずに選択肢の問いを出す。子は指揮役に問いを返し、subagent は報告に書く
- token は、断られたときに足す文の分だけ

### 注意が必要なこと

- **当たるのはコマンドの文字に出るものだけ。** script の中・関数・alias・変数に入れたコマンドは見えない (断られ
  れば F・G で受ける)。読み方は近似で、bash を解釈しているわけではない (`"…"` の中の `$( )` の閉じ括弧は引用符を
  見ずに数える、`cd` が `bash -c '…'`・`( … )` の外まで効く、`(( x << 2 ))` を heredoc と読む、など)。64 KB を
  超えるコマンドは読まない
- hook は Bash のたびに走る (当たらないコマンドは数十 ms で抜ける)。jq を 1 回に 5 回ほど起動するので、4 MB の
  出力を返した Bash の PostToolUse には 1 秒ほどかかる
- push の相手は fetch の URL で見る (`pushurl`・`pushInsteadOf` を使う repo では見逃す)
- 承認の画面が出るかは分からないので、「出るかも」と知らせる。1Password が承認を覚えている間は出ない
- herdr の通知の body は 3 行。herdr の画面での見え方は、送れたこと (`shown: true`) までしか確かめていない
- 効くのは merge のあと `~/dotfiles/setup --update` (switch と hook の登録) をしてから。動いている Claude Code は
  起動し直すと読む

## 6. 検証 (Verification)

- `nix build ./nix#checks.x86_64-linux.ssh-agent-notice-test`・`claude-ssh-agent-notice-state`・`bootstrap-claude-hook-test`
- `nix flake check ./nix`、shfmt・shellcheck・nixfmt・`check-test-headers.sh`・`check-test-grep-q.sh`
- Claude Code 2.1.306 の hook の入出力 (B の表) を、使い捨ての `--settings` の `claude -p` で記録した
- 断りの文言 (F の表) を、python の偽の agent と 127.0.0.1 の使い捨ての sshd で ssh・scp・git から集めた
- この worktree の script を、合成した入力で lavie の herdr の pane から流し、通知が出ることを確かめた
- 偽の agent と使い捨ての sshd を立てたまま、この hook を `--settings` で付けた `claude -p` に
  `ssh … 2>&1 | tail -3` を打たせ、`\r` の付いた実物の ssh の出力でも、PostToolUse から Claude に指示が届くことを確かめた
- 別の文脈のレビュアー (opus) に branch 全体を見てもらい、指摘 (`\r`・WSL・失敗の部分一致・返事をしない herdr・
  `flock FILE -c`・`SSH_AUTH_SOCK=~/…`・長いコマンド) をテストで落ちることを確かめてから直した

## 7. 移行・運用手順

```sh
~/dotfiles/setup --update        # switch (hook と JSON を置く) → bootstrap-claude-hook.sh (3 件を登録)
```

- 動いている Claude Code は、起動し直すと hook を読む
- 中で ssh を打つ道具を足すときは、使う PC のホストの値 (dotfiles-private に登録したファイルか、
  `~/dotfiles/flake.nix` の tmp) の `mkHome` に `claude.sshAgentNotice.extraCommands = [ "nix run .#vm" ];` を書いて
  `~/dotfiles/setup --update`
