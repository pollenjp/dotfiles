# ADR: public な repo へ、ほかの repo への参照を書く Claude の git push・gh pr create などを、打つ前に hook で止める

| 項目 | 内容 |
| --- | --- |
| ステータス | 承認 (Accepted) — 方針は 2026-10-24 にユーザーが承認 (集約ハブの会話)。文面は PR でレビュー |
| 日付 | 2026-10-24 (JST) |
| 決定者 | pollenjp |
| 関連 ADR | [029_claude_ssh_agent_notice](../029_claude_ssh_agent_notice_20261022T194758JST/README.md)（Bash のコマンドを単純コマンドに分けて見る hook の手本。lexer はそこから分けた） |
| 運用手順 | [`nix/README.md`「ほかの repo への参照で push・PR を止めるフック」](../../../nix/README.md#ほかの-repo-への参照で-pushpr-を止めるフック) |
| 設計 | [`docs/superpowers/specs/2026-10-24-xref-guard-design.md`](../../superpowers/specs/2026-10-24-xref-guard-design.md)（承認した設計の書き写しと、実装で決めた細部） |

---

## 1. 背景 (Context)

ユーザーの依頼 (原文):

> pollenjp/dotfiles 自体が public repository のとき、外部の repository を参照しちゃうと、参照先のログに残ってしまう。
> ※この形以外にも PR や issue へのURL形式の記述も同様である。
> あまり他のOSS側に referenced by とか pollenjp mentioned this pull request みたいなメッセージが書かれてほしくない (明示的に知らせてほしくない) ので public repository のPR description や commit message にはそれらがそのままでないように注意したい。
> 参照するときは backquote などで囲んで inline code block としてしまうとこれを防げる。

「commit message の参照の跡は push の時点で付くので、ticket.sh pr の注意では間に合いません。public な repo へ push する前に
止める仕組みを足しますか？」への答えは「足す (推奨)」、設計への答えは「承認する」。

| 事実 | 出どころ |
| --- | --- |
| dotfiles の PR #159 は、本文と commit の message に nixpkgs の PR 577218 への参照を書いていて、相手の PR の timeline に跡 (cross-referenced・referenced) が 2 つ付いた。本文を直しても消えない | 相手の PR の timeline (GitHub の API) |
| commit の message は Markdown ではないので、backquote で囲んでも跡が付いた (force push した commit e97828b から付いた)。跡は push の時点で付き、PR の commit から外しても消えなかった | 同上 |
| PR の本文・コメントは Markdown で、inline code と code block の中は参照にならない。GitHub の既定では、PR のタイトルが merge の commit の message に写る | GitHub の挙動 |
| 決まりは claude-skills の pjp-dev-tracker の「repo に書くもの」(「ほかの repo への参照」) に書き、`ticket.sh pr` は PR を出したあとに注意を出す。commit の跡には間に合わない | claude-skills |
| PreToolUse の `permissionDecision: deny` は bypassPermissions でも効き、理由 (`permissionDecisionReason`) は「PreToolUse:Bash hook error: …」として Claude に届く | Claude Code 2.1.310 の `claude -p` で確かめた (§6) |

## 2. 決定 (Decision)

### A. 打つ前に hook (script) が止め、Claude に直させる

Claude Code の PreToolUse hook (matcher Bash) `nix/files/claude/hooks/xref-guard.sh` を足す。ほかの repo への参照を書こうと
している git push・gh pr create などを止め (deny)、どの commit・どの行か・どう直すかを返す。Claude が直して打ち直す。
判断は script がするので token を使わず、ハブ・子・subagent のどの会話でも同じに動く。

### B. 止めるものと数える場所

| コマンド | 書く所 | 数える参照 |
| --- | --- | --- |
| `git push` (`git -C … push`・`git gh push` も) | 押す commit の message と、同じコマンドで push より前に作る commit (`git commit -m`・`-F`) の message | backquote の中も |
| `gh pr create`・`edit`、`gh issue create`・`edit` | タイトル (`-t`・`--title`) | backquote の中も |
| 同上と `gh pr comment`・`gh pr review`・`gh issue comment` | 本文・コメント (`-b`・`--body`・`-F`・`--body-file`) | code block (``` か ~~~) と inline code の外だけ |
| `gh pr merge` | merge の commit の件名・本文 (`--subject`・`--body`) | backquote の中も |

拾う形は `ticket.sh pr` と同じ: `owner/repo#番号`・`owner/repo@sha` (7〜40 桁)・github.com の issues・pull・discussions・
commit の URL。同じ repo の参照と `#番号` は数えない。

### C. 押す commit は、どの remote-tracking ref からも辿れないもの

押す ref (refspec の左・`--all`・`--mirror`・`--tags`・`remote.<名前>.push`・`HEAD`。解けない ref は `HEAD`) から辿れて、
`refs/remotes/*` のどれからも辿れない commit を、新しい方から 1000 個まで見る (`git log <ref>… --not --remotes`)。ネットワークに
出ずに決まり、fork で upstream の commit を押しても upstream の ref にあれば数えない。削除と `--dry-run` は見ない。同じコマンドの
`git commit --amend` は、書き換える前の HEAD を数えずにその親から辿り、新しい message (変えないなら今の HEAD の message) を数える。

### D. 公開範囲は、参照が見つかったときだけ gh で引く

`gh repo view <host>/<owner>/<repo> --json nameWithOwner,visibility` (push は push 先の URL の repo、gh は `-R`・引数の
PR の URL・`GH_REPO` の repo、`gh repo set-default` の repo (`remote.<名前>.gh-resolved`)、どれも無ければ dir で
`gh repo view`) を 10 秒で切って引く。`PRIVATE`・`INTERNAL` は通し、
`PUBLIC` と引けないもの (gh が無い・未ログイン・時間切れ・github.com でない host) は止める。控えは持たない。手元の path・
`file://` への push は見ない。

### E. 通す口は、単純コマンドの頭の `PJP_ALLOW_XREF=1`

意図して参照するときのため、`PJP_ALLOW_XREF=1 git push` (`env PJP_ALLOW_XREF=1 …`・`bash -c` などの中にも効く) は通す。
値は `1` だけ。使うのはユーザーがその参照を書くと明示したときだけで、止めたときに返す文にも「自分の判断では付けない」と書く。

### F. コマンドの読み方は ssh-agent-notice.sh の lexer を元にし、本文を残すよう変える

ADR 029 の lexer は heredoc の本文と `$( )` の中を捨てるが、この hook は PR の本文 (Claude は `--body "$(cat <<'EOF' … EOF)"` で
渡す) を読む。lexer を写して変えた: heredoc の本文・here-string・`< file` を stdin として残す、語の中の改行を残す、`$( )` の
閉じ括弧を引用符・heredoc の本文・コメントを見て探す (本文の `1)` で閉じない)、`$(cat <<EOF …)`・`$(cat <file>)` を値に置き換える、
パイプを残す (`-F -` の本文)、`> f` の書き先を残す (同じコマンドで書いたファイルを `--body-file`・`git commit -F` で読む)。
前の代入 (`BODY=…`) は、値がちょうど `"$BODY"` の語に入れる。`cd`・`git -C` の行き先を解けなければ今の dir のまま見て、`-c` も
script のファイルも無い shell (`bash <<EOF`・`cat … | bash`) は stdin を読み直す。

### G. 方針の承認のあとに、こちらで決めたこと

| 問い | 決めたこと | 理由 |
| --- | --- | --- |
| hook の名前と登録 | `xref-guard.sh`、PreToolUse・matcher Bash・`if` なしで 1 件 | `ticket.py` の判定の名前 (`XREF_RES`) に揃える。`if` で絞ると `cd x && git push`・`bash -c` を取りこぼす (入力に `push` も `gh` も無ければ 4 ms で抜ける) |
| 通す口の名前と値 | `PJP_ALLOW_XREF=1` だけ | ほかの値で通すと、`PJP_ALLOW_XREF=0` の打ち間違いで通る |
| 承認した 5 つのコマンドのほか | `gh issue edit`・`gh pr review`・`gh pr merge` も見る | どれも同じ跡を付ける (タイトル・本文・コメント・merge の commit) |
| 同じコマンドの `git commit -m … && git push` | push より前の commit の message も数える | hook が走る時点では、その commit はまだ無い |
| 押す commit の数 | 新しい方から 1000 個 | 初めての push で履歴が全部数えられても待たせない (1000 個で 1.2 秒) |
| 公開範囲の控え | 持たない | 引くのは参照が見つかったときだけ。private から public に変えた直後に古い値で通さない (`ticket.py` と同じ) |
| repo を渡していない gh の「同じ repo」 | `gh repo set-default` の repo (`remote.<名前>.gh-resolved`)、無ければ dir の remote の repo を全部 | fork の clone で upstream への PR を出すとき、upstream の参照で止めない。set-default を fork にして fork の中に出す PR では、upstream への参照を止める (最終レビュー) |
| 解けない ref・dir (`"$(git branch --show-current)"`・`"$BRANCH"`・`cd "$(git rev-parse --show-toplevel)"`) | ref は `HEAD`、dir は今の dir | 黙って通すと抜け道になる。branch 名の打ち間違いなら git の側も失敗する (最終レビュー) |
| 同じコマンドで書いたファイル・stdin の script | 書いた中身を読む・読み直す | `cat > body.md <<EOF … && gh pr create -F body.md` は、hook の時点でファイルが無いか古い。`bash -c` を避ける環境では `bash <<EOF` が出やすい (最終レビュー) |
| 同じコマンドの `git commit --amend … && git push -f` | 書き換える前の HEAD を数えない | 止めたときに勧める直し方を 1 つのコマンドで打つと、また同じ commit で止まって Claude が迷う (最終レビュー) |
| 長いコマンド | 64 KB (gawk・mawk が無ければ 16 KB。バイトで数える) を超えたら中を読まず、文字のどこかに参照か `git … push` (1 行の中) があれば止め、本文をファイルにするかコマンドを分けるよう返す (dir の repo が private なら通す) | 黙って通すと抜け道になる。上限は ADR 029 と同じ (macOS の awk は長さの二乗で遅い)。`git … push` を改行をまたいで探すと、git の多い 113 KB の文書で 7.8 秒かかった (最終レビュー) |
| 返す文 | どこか (commit・行・参照・前後の文字) と直し方を 20 件まで | Claude がそのまま直せる。commit は「nixpkgs の PR 577218」の形、本文は backquote |
| ADR の番号 | 033 | open な PR に ADR を足すものは無かった |

## 3. 変更点の詳細

| ファイル | 変更 |
| --- | --- |
| `nix/files/claude/hooks/xref-guard.sh` | 新規。lexer・包むコマンドを外す・git push と gh の読み方・参照の判定 (jq)・公開範囲・返す文 |
| `nix/tests/xref-guard.test.sh` | 新規。偽の gh と使い捨ての repo で、止める・通す・返す文 (178 件) |
| `nix/home/modules/claude.nix` | hook を `~/.claude/hooks/xref-guard.sh` に置く |
| `nix/tests/claude-xref-guard.nix` | 新規。hook の置き方を評価時に確かめる |
| `nix/scripts/bootstrap-claude-hook.sh`・`nix/tests/bootstrap-claude-hook.test.sh` | PreToolUse・Bash の 1 件の登録 |
| `nix/flake.nix` | checks に `xref-guard-test`・`claude-xref-guard-state` |
| `nix/README.md` | フックの節と、bootstrap の表 |

## 4. 検討した代替案

| 案 | 採らなかった理由 |
| --- | --- |
| `ticket.sh pr` の注意だけにする | PR を出したあとに出るので、push の時点で付く commit の跡に間に合わない |
| git の pre-push hook にする | repo ごとに入れる要がある。ユーザーが手で打つ push まで止める (今回は対象外と決めた) |
| skill や CLAUDE.md に決まりを書くだけにする | 読み忘れ (子・subagent) で抜ける。決まりは pjp-dev-tracker にすでにある |
| 止めずに知らせるだけ (systemMessage) | 付いた跡は消せないので、打つ前に止めないと意味が無い |
| `ssh-agent-notice.sh` の lexer を共通のファイルに出す | ssh-agent-notice.sh の配置とテストも変わる。読み方 (本文を捨てる・残す) も違う |
| `if: "Bash(git push*)"` で登録する | `cd x && git push`・`bash -c '…'`・`timeout 60 git push` を取りこぼす |
| shfmt で構文木にして読む | 全マシンの hook の実行時に shfmt が要る (ADR 029 と同じ) |
| 公開範囲を控えに持つ | private から public に変えた直後に古い値で通す。引くのは参照が見つかったときだけなので、毎回でも重くない |

## 5. 影響 (Consequences)

### 良くなること

- Claude が public な repo に、ほかの repo への参照を書いた commit を push する・PR を出す前に止まり、どこを・どう直すかが
  Claude に届く。直して打ち直すので、参照先の timeline に跡が付かない
- token を使わない。参照の無いコマンドは、ネットワークに出ずに数十 ms で抜ける

### 注意が必要なこと

- **見えるのはコマンドの文字と、その場で読めるもの (repo の commit・本文のファイル・同じコマンドで書いたファイル) だけ。**
  script の中・関数・alias・変数に入れたコマンド、`gh api` で書くコメント、`gh pr create --fill` (commit から本文を作る)、
  `--body-file -` に読めない stdin を渡したもの、`gh pr new`・`gh issue new` (create の別名)・`gh pr -R x create` の書き順、
  `read -d '' BODY <<EOF`・`printf -v BODY` の変数、`direnv exec`・`mise exec` で包んだもの、`gh repo create --push` は見えない。
  読み方は近似で、bash を解釈しているわけではない (ADR 029 と同じ限り)
- CRLF の本文では、空行をまたいだ backquote を inline code と見なして参照を隠すことがある (`ticket.py` は隠さない)
- 押す commit は remote-tracking ref で決める。fetch していない remote の commit (ほかのマシンが push したもの) を手元で
  持っていれば数える (止めすぎる側に倒れる)
- 公開範囲を引けない (gh が未ログイン・github.com でない host・ssh のホスト別名の remote) と、参照があれば止める。通すなら
  ユーザーが明示して `PJP_ALLOW_XREF=1`
- ユーザーが手で打つ push・PR は止めない
- 効くのは merge のあと `~/dotfiles/setup --update` (switch と hook の登録) をしてから。動いている Claude Code は起動し直すと
  読む

## 6. 検証 (Verification)

- `nix build ./nix#checks.x86_64-linux.xref-guard-test`・`claude-xref-guard-state`・`bootstrap-claude-hook-test`
- `nix flake check ./nix`、shfmt・shellcheck・nixfmt・`check-test-headers.sh`・`check-test-grep-q.sh`
- 使い捨ての `--settings` で hook を付けた `claude -p` (Claude Code 2.1.310・bypassPermissions) に、参照のある commit の
  `git push` と本文に参照のある `gh pr create` を打たせ、どちらも打たれず、理由が Claude に届くことを確かめた (push 先も
  参照先も GitHub に無い repo にし、hook の中の gh は偽物にした)
- 手元の時間: 参照の無い push は 30 ms、`push` と `gh` を含まないコマンドは 4 ms (入力の JSON の cwd などに `gh` の文字が
  あると、jq で読んでから抜けるので 11 ms ほど)、60 KB の PR の本文は gawk で 0.5 秒、git の多い 110 KB のコマンドは 0.7 秒
- 別の文脈のレビュアー (opus) に branch 全体を見てもらい (ランダムな入力 3700 件で exit 0 と出力の形、`ticket.py` の判定との
  突き合わせ 4000 件で不一致 0)、指摘 (解けない ref・dir、同じコマンドで書くファイル、stdin の script、amend と push、長いコマンドの
  正規表現の遅さ、fork の set-default、文書の古さ) をテストで落ちることを確かめてから直した

## 7. 移行・運用手順

```sh
~/dotfiles/setup --update        # switch (hook を置く) → bootstrap-claude-hook.sh (PreToolUse の 1 件を登録)
```

- 動いている Claude Code は、起動し直すと hook を読む
- 意図して参照するときは、ユーザーが Claude に明示し、Claude がコマンドの頭に `PJP_ALLOW_XREF=1` を付けて打つ
