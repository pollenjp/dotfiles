# Claude の作業が 1Password の SSH agent を使う前に知らせ、断られたら問いを出させる — 設計 (TKT-317)

- チケット: [TKT-317](https://app.notion.com/p/Claude-1Password-SSH-agent-herdr-hook-2-TKT-294-40179149a66f814ba604e1af911da5aa)
  (集約ハブの会話は [TKT-294](https://app.notion.com/p/infra-v2-pjp-wolf-NixOS-VM-TKT-243-PR-7-merge-40179149a66f81c4a513f0a330c60977))
- 方針は 2026-10-22 にユーザーが承認した (ハブの cc-page「1Password の SSH 承認を前もって知らせる (設計案)」)。
  この文書はその書き写しと、実装に要る細部 (「実装の細部」と「こちらの判断」)
- 関連: ADR 025 (herdr の中の agent は手元の PC から転送された接続を借りる)、ADR 008・022 (固定名の agent)。
  決定の記録は ADR 029

## 背景と意図

ユーザーの依頼 (原文):

> あと、ss-agent (1password の ssh-agent) の承認が来るようなタイプのリクエストを claude の作業の中で投げる際は事前に通知してほしいけど事前に調べるのは少しコスト高いかな？
> ユーザー (僕) はどこから送られたリクエストかわからないものは deny するようにしているので。
> ※tokenコスト高くなりそうなら失敗した後ユーザーにssh-agentの承認を依頼するような選択肢型の質問を提示して欲しい。
> これを skill に落とし込めるかな

- herdr の中の `SSH_AUTH_SOCK` は固定名 (`~/.ssh/agent.<session>.sock`) で、手元の PC から SSH の接続で転送された
  agent (`~/.ssh/agent/s.*.sshd.*`) を指す (ADR 025)。1Password は手元の PC で動き、承認の画面もそこに出るが、
  lavie のどの pane・どの Claude が頼んだかは出ない
- 2026-10-22、固定名が 08:59 の接続の口を指していて、承認の画面はその接続の端末に出ていた。ユーザーは気づけず、
  infra-v2 の子の ssh が `agent refused operation` で通らなかった。11:54 の接続の口へ切り替えたら通った
- 承認の画面がいつ出るかは 1Password の設定 (承認を覚える時間・ロック) しだいで、Claude の側からは分からない

## ゴール

- Claude Code が agent を使うコマンドを Bash で打つ前に、herdr の通知 (音つき) と会話の画面の 1 行で知らせる。
  どの workspace・agent からか、コマンドの頭、承認の画面が出る接続 (いつ入った接続か) を載せる
- agent に断られたら、Claude が同じコマンドを打ち直さず、何を・どこからを書いてから選択肢の問いを出す
- 中で ssh を打つ道具 (infra-v2 の `nix run .#vm` など) を、設定に書き足せば前もって知らせる対象にできる
- token を使わない (判断は script がする)。ハブも子も subagent も、このユーザーの Claude Code の会話なら同じに動く

## 非ゴール (やらないこと)

- 1Password の設定 (承認を覚える時間・ロック) を変える
- commit の署名を止める・変える
- 承認の画面が本当に出るかを前もって判定する (判定には署名が要り、それ自体が画面を出す)
- skill を作る (決まりは hook が Claude に足す文に書く)

## 設計 (承認済み)

hook を 2 つ足す。ユーザーの hook の決まり (ADR 019 の前例) に従い、script は `nix/files/claude/hooks/` に置いて
`nix/home/modules/claude.nix` が配り、登録は `nix/scripts/bootstrap-claude-hook.sh`、テストは flake の `checks` で流す。

| | いつ | すること |
| --- | --- | --- |
| hook 1: 打つ前の知らせ | PreToolUse・Bash | コマンドが一覧に当たったら、herdr の通知 (`--sound request`) と会話の画面の 1 行で知らせる。コマンドは止めない |
| hook 2: 断られたあとの問い | PostToolUse・Bash (失敗で返った Bash の event も) | 出力に agent の断りがあれば、Claude に指示を足し、herdr でも知らせる |

- herdr の通知は、同じ pane からは 10 分に 1 回まで (commit のたびに鳴らさない)。会話の画面の 1 行は当たるたびに出す
- hook 2 の指示: 同じコマンドを打ち直さない。何を (コマンド・接続先) と、どこから (workspace・pane) を書いてから、
  選択肢の問いを出す。① 1Password を開いて承認するので打ち直す (推奨) ② この手順を飛ばして進める ③ ここで止める。
  herdr の指揮役から依頼を受けた子は AskUserQuestion を使わず、問いを書いてターンを終える
- hook が失敗しても Bash を止めない
- 中で ssh を打つ道具は、設定に書き足せば hook 1 の対象になる。足していない道具でも、断られれば hook 2 が受ける

## 実装の細部 (決まったこと)

### 1. 置き場所と登録

- script は 1 本: `nix/files/claude/hooks/ssh-agent-notice.sh`。入力の `hook_event_name` で hook 1 と hook 2 を分ける
  (接続の見せ方・どこからの引き方・herdr の通知を 2 つで共にするため)
- `bootstrap-claude-hook.sh` が 3 件登録する: `PreToolUse`・`PostToolUse`・`PostToolUseFailure`、どれも matcher `Bash`、
  `if` なし
- 一覧に足す道具は host option `dotfiles.claude.sshAgentNotice.extraCommands` (文字列のリスト、既定 `[ ]`)。
  `~/.local/state/dotfiles/claude-ssh-agent-notice.json` (`{"extraCommands": [...]}`) にいつも書き、hook が読む

### 2. 今の Claude Code (2.1.306) で確かめたこと

使い捨ての `--settings` で `claude -p` を走らせ、hook の入力と env を記録した。

| 事実 | 設計への効き方 |
| --- | --- |
| 0 以外で終わった Bash には PostToolUse が呼ばれず、PostToolUseFailure が呼ばれる。入力の `error` は `Exit code <n>\n<出力>` (stdout と stderr を合わせたもの)、`is_interrupt` もある | hook 2 は PostToolUseFailure にも登録し、`error` も見る。`2>&1 \| tail` で終了コードが隠れたときは PostToolUse の `tool_response.stdout` / `stderr` に出る |
| PostToolUseFailure の `hookSpecificOutput.additionalContext` は Claude に届く | hook 2 の指示はこれで足す |
| PreToolUse の `systemMessage` は画面に「PreToolUse:Bash says: …」と出て、Claude には渡らない | 会話の画面の 1 行はこれで出す (token を使わない) |
| hook の env には settings.json の `env` (`GIT_CONFIG_*`) と `HERDR_*`・`SSH_AUTH_SOCK` が入る | git の実効の設定を hook の中で聞ける。herdr の pane も分かる |

### 3. git の commit は、Claude の会話では agent を使わない

dotfiles は Claude の会話にだけ `commit.gpgsign=false`・`tag.gpgsign=false` を env で入れている
(`claude.nix` の `gitConfigBase`。nix/README「Claude のセッションだけ git の設定を変える」)。手元のターミナルの
git は 1Password で署名するが、Claude の commit は無署名で、承認の画面は出ない (main の Claude の commit も無署名)。

そこで設計の一覧のうち git は「署名するときだけ」当てる。署名するかは hook の中で git に聞く
(`git [-C <dir>] [-c <k=v>]… config --type=bool --get commit.gpgsign`)。hook の env は Claude の会話と同じなので、
会話の Bash と同じ答えになる。`git -c commit.gpgsign=true` は env より勝つ (実測) ので、コマンドの `-c` も渡す。

### 4. 打つ前に当てるもの (hook 1)

コマンドの文字を単純コマンドに分け (§5)、1 つずつ見る。最初に当たったものを知らせる。

| 種類 | 当てるもの |
| --- | --- |
| ssh の接続 | `ssh`・`scp`・`sftp`・`ssh-copy-id`・`sshfs`・`mosh`・`autossh` (`ssh` の `-G`・`-V`・`-Q`・`-O` は繋がないので外す) |
| ssh の接続 | `rsync` で、引数に `<host>:<path>` (`::` と `rsync://` は daemon なので外す) がある |
| ssh の接続 | `nixos-rebuild`・`nixos-rebuild-ng` の `--target-host`・`--build-host`。`nix-copy-closure`。`nix`・`nix-*` の引数に `ssh://`・`ssh-ng://` |
| ssh の接続 | git の `clone`・`fetch`・`pull`・`push`・`ls-remote` で、相手の URL (`git ls-remote --get-url` で insteadOf を解いたもの) が ssh (`ssh://`・`<host>:<path>`)。`fetch --all`・`remote update` は全部の remote を見る |
| 署名 | git の `commit`・`merge`・`rebase`・`cherry-pick`・`revert`・`am`・`pull`・`commit-tree` で、`-S`・`--gpg-sign` があるか、実効の `commit.gpgsign` が真 (`--no-gpg-sign` と `--abort` などの後始末は外す) |
| 署名 | `git tag` で tag を作るとき、`-s`・`-u`・`--sign`・`--local-user` があるか、実効の `tag.gpgsign` が真 (`tag.forceSignAnnotated` と注釈つきの tag も)。一覧・削除・検証は外す |
| 署名 | `git push --signed`、実効の `push.gpgsign` が `true`・`if-asked`。`ssh-keygen -Y sign`・`ssh-add -T` |
| 設定の一覧 | `extraCommands` の項目 (§7) |

### 5. コマンドの読み方

- 引用符 (`'…'`・`"…"`・`$'…'`)・`\` を外して語にする。ヒアドキュメントの本文とコメントは捨てる
  (commit のメッセージや heredoc の本文に ssh と書いても当たらない)
- `;`・`&`・`|`・改行・`(`・`)` で単純コマンドに分ける。`$( )`・`` ` ` ``・`<( )`・`>( )` の中は別の単純コマンドとして見る
- 頭の `VAR=値` と、包むコマンドを外してから見る: `env`・`sudo`・`doas`・`exec`・`command`・`builtin`・`nohup`・`time`・
  `nice`・`ionice`・`setsid`・`stdbuf`・`timeout`・`xargs`・`watch`・`flock`・`sshpass`・`unbuffer`・`chronic`、
  `nix develop`・`nix shell` の `-c`/`--command` の後ろ、`if`・`then`・`do`・`!`・`{` などの予約語
- 中に文字列で渡すものは、その文字列をもう一度読む (3 段まで): `bash`・`sh`・`zsh`・`dash`・`ksh` の `-c`、
  `nix-shell` の `--run`・`--command`、`eval`、`su`・`runuser`・`script`・`flock` の `-c`
- `cd <dir>`・`pushd <dir>` は、同じコマンドの後ろの git を流す場所に効かせる。`git -C <dir>` も効かせる
- 見えないもの: script の中・関数・alias・変数に入れたコマンド。これらは hook 2 が受ける
- `SSH_AUTH_SOCK=<path>` を頭に付けた単純コマンドは、その path (頭の `~`・`$HOME` は置き換える) を接続として見せる (§6)
- 安く抜ける: コマンドの文字に `ssh`・`scp`・`sftp`・`mosh`・`rsync`・`nixos-rebuild`・`git` と、一覧の項目の頭の語の
  どれも無ければ、読まずに抜ける
- 読むのは 64 KB まで (gawk・mawk が無いマシンでは 16 KB)。それより長いコマンドは読まずに抜ける。macOS の awk
  (onetrue-awk) は 1 文字ずつ読むと長さの二乗で遅くなる (レビューで 80 KB に十数秒)。awk は gawk・mawk を先に使う

### 6. 承認の画面が出る接続

`SSH_AUTH_SOCK` (§5 で上書きされていればその値) の symlink の先を見る。

| 先 | 見せ方 |
| --- | --- |
| `s.*.sshd.*` (sshd が転送した agent。OpenSSH 10.1 から) | 「`<月/日 時:分>` に `<PJP_SSH_CLIENT>` から入った接続の端末」。時刻と値は pjp-agent-link の記録 (`~/.local/state/pjp-agent-link/conn/<basename>` の `opened`・`client`) から、無ければ socket の時刻 |
| 同じ dir に、それより新しい `s.*.sshd.*` がある | 「(より新しい接続: `<月/日 時:分>` `<値>`)」を添える。いちばん新しいもの 1 つ |
| それ以外 (手元の 1Password の `~/.1password/agent.sock` など) | 「このマシンの agent (`<path>`)」 |
| 先が無い | 「出ない (agent の口の先が無い)」。そのまま打てば hook 2 が受ける |
| `SSH_AUTH_SOCK` が空で WSL (`WSL_DISTRO_NAME` がある) | 「Windows の 1Password が出す (要求元は「Windows Terminal」としか出ない)」。WSL の `ssh` は Windows の `ssh.exe` へのラッパー |
| `SSH_AUTH_SOCK` が空 (ほか) | 「どこに出るかは分からない (SSH_AUTH_SOCK が空)」。ssh の設定の `IdentityAgent` で agent を使うことがあるので、出ないとは言わない |

socket かどうかは見ず、ファイルがあるかで見る (sshd は接続を閉じると socket を消す。テストで本物の socket を作らずに済む)。

### 7. 一覧に足す設定 (`extraCommands`)

- 項目は語を空白で区切った文字列 (例: `"nix run .#vm"`)。1 語目を単純コマンドの頭の語 (そのままか basename) に、
  残りの語を引数の中に順に (間に別の語があってよい) 当てる。各語は bash の glob として比べる (`"*/deploy.sh"` など)
- 例: `"nix run .#vm"` は `nix run .#vm -- create foo` にも `nix run -L .#vm -- ip` にも当たる
- 既定は空。infra-v2 の `nix run .#vm` は、使う PC のホストの値 (dotfiles-private の登録かローカル flake の tmp) に書く

### 8. herdr の通知と、どこから

- `HERDR_ENV=1` で `herdr` が PATH にあるときだけ。`herdr workspace get "$HERDR_WORKSPACE_ID"` の `label` と、
  `herdr agent get "$HERDR_PANE_ID"` の `name` (無ければ pane の ID) で「どこから」を作る
- 呼ぶたびに 2 秒で切る (`timeout 2`。無いマシン (macOS) では裏で流して見張る)。落ちた・返事をしないときは、その回の
  残りと続く 60 秒は herdr を呼ばない (印は同じ dir の `herdr-down`)。返事をしない herdr で Bash を毎回待たせない
- hook 1: title「🔑 1Password の承認が出るかも」、body は「どこから」・コマンドの頭・接続の 3 行、`--sound request`。
  同じ pane (`HERDR_SESSION` と `HERDR_PANE_ID` の組) からは 600 秒に 1 回まで。印は
  `${XDG_STATE_HOME:-~/.local/state}/pjp-ssh-agent-notice/notified-<組>` の時刻
- hook 2: title は理由ごと (「🔑 1Password に断られた」など)、`--sound request`。間引かない
- コマンドの頭は、当たった単純コマンドの語を空白でつなぎ、80 文字で切る (切るのは jq。文字の途中で切らない)

### 9. 断りの見分け方 (hook 2)

`error`・`tool_response.stdout`・`tool_response.stderr` を行に分け、行の終わりが文言のときだけ当てる (ssh・git の行は
文言で終わり、diff・コード・文書の行はそうでない)。成功した Bash (`2>&1 | tail` で終了コードが隠れたもの) は、行の頭も
ssh・git の出す形 (`sign_and_send_pubkey:`・`Couldn't sign`・`Signing`・`error:`) に固定する (成功した grep・cat の
結果では当てない)。偽の agent (鍵を見せて署名を断る・接続を切る) と使い捨ての sshd で、ssh・scp・git の実際の文言を
集めて決めた。

OpenSSH は自分のエラー行を `\r\n` で終え、Claude Code は tool の出力の `\r` を残す (2.1.306 で確かめた) ので、`\r` を
外してから見る。git は ssh-keygen の出力の `\r` を `?` に変えて出す (見本の行の終わりの `?` はこれ)。

| 理由 | 当てる行 | 出どころ |
| --- | --- | --- |
| 断られた | 行の終わりが `agent refused operation` (`?` が付いてもよい) | ssh・scp: `sign_and_send_pubkey: signing failed for ED25519 "…" from agent: agent refused operation`。git の署名: `Couldn't sign message (signer): agent refused operation?` |
| 通信が切れた | 行の終わりが `communication with agent failed` (`?` が付いてもよい) | 同じ形で、agent の接続が途中で切れたとき |
| agent に届かない | 行の終わりが `Couldn't get agent socket` の行 (成功した Bash は `error: ` で始まる行)・`error: Couldn't load public key …/.git_signing_key_tmp…: ` で始まる行 (終わりが決まらないので、git がいつも付ける頭で固定する) | git の署名で、agent の口が無いとき (鍵を `ssh-add -L` から引く設定では後者) |
| agent に届かない | `Permission denied (…publickey…).` で終わる行があり、`SSH_AUTH_SOCK` が空でなく、その先が無い | ssh は agent の口が無いと何も言わずに鍵の認証で落ちる。口が生きていれば鍵が相手に無いだけ、空なら agent を使っていない (WSL の ssh.exe など) |

### 10. Claude に足す文 (hook 2)

```
[ssh-agent] 直前の Bash は SSH agent (1Password) を使えずに失敗した: <理由の説明>。
同じコマンドを打ち直さない (承認されないまま同じ失敗を繰り返す)。
1. 何を (<コマンドの頭> の接続先や署名する対象) と、どこから (<どこから>) を書く。承認の画面は <接続>。
2. 選択肢の問いを出す: ① <理由ごとの 1 つ目> (推奨) ② この手順を飛ばして進める ③ ここで止める。
   ① が選ばれたら、同じコマンドを 1 回だけ打ち直す。
<herdr の子の決まり>
```

- 理由の説明: 断られた → 「1Password に断られた (承認の画面で断られたか、応えないまま時間切れになったか、1Password が
  ロック中だった)」、通信が切れた → 「agent との通信が切れた (agent への接続が途中で閉じた)」、届かない → 「agent に
  届かない (SSH_AUTH_SOCK の先に agent がいない)」
- 1 つ目: 断られた → 「1Password を開いて承認するので、打ち直す」。通信が切れた・届かないなら、agent の口の種類ごと:

  | 口 | 1 つ目 |
  | --- | --- |
  | sshd が転送した agent (`s.*.sshd.*`。先が無くても) | 手元の PC からこのマシンへ接続し直す (agent の口を張り替える) ので、打ち直す |
  | ほかの口 (手元の 1Password など) | 1Password を起動してロックを解除するので、打ち直す |
  | 空で WSL | Windows の 1Password を起動してロックを解除するので、打ち直す |
  | 空 | agent を使えるようにする (SSH_AUTH_SOCK を設定する) ので、打ち直す |
- herdr の子の決まり: 「herdr の指揮役から依頼を受けて動いている子は、AskUserQuestion を使わず、問いと選択肢を書いて
  ターンを終える (指揮役がユーザーに聞く)。それ以外は AskUserQuestion で聞く」。workspace の名前が 🌱 で始まるときは、
  その pane が子であることも添える
- subagent の中 (入力に `agent_id` がある) では問いを出させない: 「subagent の中なので、ユーザーには聞かず、ここまでの
  結果と、失敗したこと (何を・どこから・承認の画面) を報告に書いて作業を終える。問いは呼び出した会話が出す」
- 会話の画面にも `systemMessage` で 1 行出す

### 11. 壊れない

- 何があっても exit 0。`permissionDecision` は出さない (Bash の許可の流れを変えない)
- 先に stdin を読み切る。jq が無い・入力が壊れている・Bash でない → 黙って抜ける
- herdr・git の呼び出しは失敗しても黙って進む。設定のファイルが無い・壊れている → 一覧は組み込みだけ

## 確かめ方

- `nix/tests/ssh-agent-notice.test.sh` (`ssh-agent-notice-test`。scriptTest): 合成した入力で、hook 1 の当たり・外れ
  (引用符・heredoc・包むコマンド・`cd`・git の実効の設定・ssh の remote・一覧の項目)、知らせる文と接続の見せ方、
  herdr の呼び方と 10 分の間引き、hook 2 の理由ごとの文・行の形で当たらないもの・subagent、壊れた入力・jq が無いとき
- `nix/tests/claude-ssh-agent-notice.nix` (`claude-ssh-agent-notice-state`): option の既定と JSON の中身、hook が実行できる
  ファイルとして置かれること
- `nix/tests/bootstrap-claude-hook.test.sh`: 3 件の登録と冪等
- shfmt・shellcheck・nixfmt・`check-test-headers.sh`・`check-test-grep-q.sh`・`nix flake check`
- 実機: この worktree の script を、合成した入力で lavie の herdr に向けて流し、通知が出ることを 1 回見る

## 文書

- ADR 029 (決定と、捨てた案: skill にする・git の commit をいつも当てる・hook 2 を素の部分一致にする)
- nix/README の Claude Code の節 (状態ファイルの表・フックの節・git の設定の節からの参照)
- `options.nix` の一覧と description、`mk-home.nix` の例、`claude.nix`・`bootstrap-claude-hook.sh` の先頭のコメント

## こちらの判断 (ユーザーに確かめずに決めたもの)

- git は「署名するときだけ」当てる (§3)。設計の一覧は commit をいつも当てる前提だったが、Claude の会話では無署名なので、
  当てると承認の出ない commit のたびに知らせることになる
- ssh の remote への git (clone・fetch・pull・push) も当てる。GitHub は https に読み替えているので当たらないが、
  ほかの ssh の remote は agent を使う
- script は 1 本にし、3 つの event に登録する (接続・どこから・通知の部品を共にする)
- hook 2 の herdr の通知は間引かない (断られたのは毎回知らせる価値がある)
- 断りの文言は行の終わりに固定して見る。成功した Bash は行の頭も固定する (この hook の文書やテストを cat・grep・diff
  しただけで当たらないように)。計画の段階で一度「失敗した Bash は部分一致」にしたが、最終レビューで、失敗した diff や
  cat で誤って当たる (Claude が止まって音が鳴る) と指摘され、行の終わりに戻した
- agent に届かないとき (`Couldn't get agent socket` など) も hook 2 で受け、1 つ目の選択肢を口の種類ごとの直し方にする
- 最終レビュー (別の文脈のレビュアー) の指摘で直したもの: OpenSSH の行の終わりの `\r`、WSL と空の `SSH_AUTH_SOCK` の
  見せ方と選択肢、返事をしない herdr (2 秒で切り、60 秒は呼ばない。`timeout` の無いマシンでも)、`flock FILE -c`、
  頭の `SSH_AUTH_SOCK=~/…`、長いコマンドの読み方 (上限と、heredoc を 1 回の index で飛ばす)
- subagent の中では問いを出させず、報告に書いて終えさせる (subagent はユーザーに聞けない)
- `SSH_AUTH_SOCK=<path>` を頭に付けたコマンドは、その path を接続として見せる
- socket かどうかは見ず、ファイルがあるかで見る (§6)
- 状態ファイルの名前は `claude-ssh-agent-notice.json`、option は `dotfiles.claude.sshAgentNotice.extraCommands`

## 実装に任せること

- 包むコマンドのオプションのうち値を取るものの細かい一覧
- 時刻の形 (`%m/%d %H:%M`) と、macOS の `date`・`stat` への倒し方
