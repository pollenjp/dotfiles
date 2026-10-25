# public な repo への push・PR の前に、ほかの repo への参照で止める hook (設計)

- 日付: 2026-10-24
- 出どころ: 集約ハブの会話でユーザーが承認した設計の書き写し。最後の「実装で決めた細部」は、実装で決めたこと
- 決定の記録は ADR 033

## なぜ

- dotfiles の PR #159 は、本文と commit の message に nixpkgs の PR 577218 への参照を書いていて、相手の PR の timeline に
  跡が 2 つ付き、消せなかった。
  - 本文 (Markdown) は backquote で囲めば跡が付かないが、commit の message は Markdown ではないので、backquote で囲んでも
    跡が付いた (force push した commit e97828b から付いた)。
  - commit の跡は push の時点で付き、PR の commit から外しても消えなかった。GitHub の既定では、PR のタイトルも merge の
    commit の message に写る。
- 決まりは claude-skills の pjp-dev-tracker (「repo に書くもの」の「ほかの repo への参照」) に書いた: PR のタイトルと
  commit の message には、ほかの repo の参照を backquote で囲んでも書かない。PR の本文とコメントは backquote で囲む。
  同じ repo の `#番号` はそのまま。
  - 同じ変更で、`ticket.sh pr` が PR を出したあとに注意を出すようにした。commit の跡は push の時点で付くので、PR を
    出したあとの注意では間に合わない。
- 書く前に止める仕組みはまだ無い。

ユーザーの依頼 (原文):

> pollenjp/dotfiles 自体が public repository のとき、外部の repository を参照しちゃうと、参照先のログに残ってしまう。
> ※この形以外にも PR や issue へのURL形式の記述も同様である。
> あまり他のOSS側に referenced by とか pollenjp mentioned this pull request みたいなメッセージが書かれてほしくない (明示的に知らせてほしくない) ので public repository のPR description や commit message にはそれらがそのままでないように注意したい。
> 参照するときは backquote などで囲んで inline code block としてしまうとこれを防げる。

「commit message の参照の跡は push の時点で付くので、ticket.sh pr の注意では間に合いません。public な repo へ push する前に
止める仕組みを足しますか？」への答えは「足す (推奨)」、下の設計への答えは「承認する」。

## ゴール

- Claude Code が Bash で打つ `git push` と `gh pr create` などを、ほかの repo への参照を書こうとしているときに、打つ前に
  止める。止めたら、どの commit・どの行かと直し方を Claude に返し、Claude が直して打ち直す。
- 止めるのは public な repo と、公開範囲を確かめられない repo だけ。
- 意図して参照するとき (ユーザーが明示したとき) は通せる。

## 非ゴール (やらないこと)

- ユーザーが手で打つ push (git の pre-push hook) を止める
- 付いてしまった跡を消す (GitHub の側で消せない)
- 自分の repo の中の参照 (`#番号`) を止める

## 設計 (承認済み)

- dotfiles の `nix/files/claude/hooks/` に、Claude Code の PreToolUse hook (matcher Bash) を足す。ADR とテストも足す。
  手本は ADR 029 の `ssh-agent-notice.sh` (コマンドを単純コマンドに分けて見る・登録は `claude.nix` と
  `bootstrap-claude-hook.sh`)。
- 止めるもの:
  1. `git push` (`git -C … push` も): push する commit (remote にまだ無いもの) の message に、ほかの repo への参照が
     あれば止める。commit の message は Markdown ではないので、backquote の中も数える。
  2. `gh pr create`・`gh pr edit` (と `gh pr comment`・`gh issue create`・`gh issue comment`): タイトルに参照が
     あれば止める。本文 (`--body`・`--body-file`) は、backquote の外に参照があれば止める。
- 対象は public な repo と、公開範囲を確かめられない repo。拾う形は claude-skills の `ticket.sh pr` と同じ
  (`owner/repo#番号`・`owner/repo@sha`・github.com の issues・pull・discussions・commit の URL。同じ repo の `#番号` は
  対象外)。
- 止め方: コマンドを止め (`permissionDecision` を `deny`)、どの commit・どの行かと直し方を Claude に返す。commit は
  「nixpkgs の PR 577218」の形に書き換え、本文は backquote で囲む、と示す。
- 抜け道: 意図して参照したいときのため、コマンドの頭に付ける環境変数で通す口を残す。使うのはユーザーが明示したとき
  だけ、と文書に書く。
- しないこと: ユーザーが手で打つ push (git の pre-push hook) は今回は対象外。
- 細部 (変数の名前・判定の置き場所・公開範囲の引き方と控え・テストの形など) は子が決め、PR の本文に並べる。

## 実装で決めた細部

### 1. 置き場所・名前・登録

- script は 1 本: `nix/files/claude/hooks/xref-guard.sh` (`ticket.py` の判定の名前 `xref` に揃える)。依存は bash・jq・
  awk・git と、参照が見つかったときだけ gh。
- `bootstrap-claude-hook.sh` が `PreToolUse`・matcher `Bash`・`if` なしで 1 件登録する。`if` で絞らないのは、
  `cd x && git push` や `bash -c '…'` のような形を取りこぼさないため (script の中の安い前段で抜ける)。
- `claude.nix` が `~/.claude/hooks/xref-guard.sh` に置く。option は作らない (マシンごとに変える値が無い)。

### 2. 通す口

- 単純コマンドの頭の `PJP_ALLOW_XREF=1` (`env PJP_ALLOW_XREF=1 …` も)。値は `1` だけ。その単純コマンドだけを通す。
- 止めたときに返す文にも書くが、「ユーザーがこの参照を書くと明示したときだけ付ける。自分の判断では付けない」と添える。
  文に書かないと、ユーザーが許しても Claude が通し方を知らない。

### 3. 拾う形と、数える場所

| 書く所 | 数える参照 |
| --- | --- |
| push する commit の message・同じコマンドで作る commit の message (`git commit -m`・`-F`) | backquote の中も数える |
| PR・issue のタイトル (`--title`)・merge の commit (`gh pr merge` の `--subject`・`--body`) | backquote の中も数える |
| PR・issue の本文 (`--body`・`--body-file`)・コメント (`gh pr comment`・`gh issue comment`・`gh pr review`) | code block (``` か ~~~ の囲み) と inline code の外だけ |

- 形は `ticket.py` の `XREF_RES` と同じ。`\w` は ASCII に限る (日本語の直後の `owner/repo#1` も拾う)。正規表現は jq
  (Oniguruma。lookbehind と `\k<名前>` が使える) で当てる。
- Markdown の code を外すのは `ticket.py` の `strip_code` と同じ (閉じない backquote は空行を越えない)。行の番号を
  保つよう、外した inline code の中の改行は残す。
- 同じ repo は、push なら push 先の repo、gh なら `-R`・引数の URL・`GH_REPO` の repo。どれも無い gh は、
  `gh repo set-default` が書く `remote.<名前>.gh-resolved` (その remote なら `base`、remote に無い repo なら `owner/repo`) の
  repo、それも無ければ dir の remote の repo を全部同じ repo とみなす (fork の clone で upstream への PR を出す形を止めず、
  fork の中に出す PR から upstream への参照は止める)。名前は大文字小文字を区別しない。
- 承認した設計の 5 つに、`gh issue edit` (タイトルと本文)・`gh pr review` (本文)・`gh pr merge` (merge の commit の
  message) を足した。どれも同じ跡を付ける。

### 4. push する commit

- 押す ref から辿れて、どの remote-tracking ref (`refs/remotes/*`) からも辿れない commit (`git log <ref>… --not --remotes`)。
  新しい方から 1000 個まで。fork で upstream の commit を押しても、upstream の remote-tracking ref にあれば数えない。
- 押す ref: refspec の左 (`+`・`tag <名前>`・glob も)。refspec が無ければ `remote.<名前>.push`、それも無ければ `HEAD`。
  解けない ref (`"$(git branch --show-current)"`・`"$BRANCH"`・同じコマンドで作る branch) は `HEAD` とみなす。
  `--all`・`--branches` は全 branch、`--mirror` (と `remote.<名前>.mirror`) は全 ref、`--tags` は全 tag。削除
  (`:<ref>`・`--delete`) と `--dry-run` は何も送らないので見ない。
- 押す先: 引数の remote (名前か URL)・`--repo`、無ければ `branch.<今>.pushRemote` → `remote.pushDefault` →
  `branch.<今>.remote` → `origin`。URL は `git remote get-url --push` (insteadOf を解いたもの)。手元の path・`file://`
  は GitHub に届かないので見ない。
- 同じコマンドの中で push より前に `git commit -m …` (`-F <file>`・`-F -` と heredoc も) があれば、その message も
  数える (hook が走る時点では、その commit はまだ無い)。`--amend` なら、後ろの push は書き換える前の HEAD を数えずに
  その親から辿り、message を変えない amend (`--no-edit`) は今の HEAD の message を数える (新しい commit になり、push すると
  跡がまた付く)。

### 5. gh のタイトルと本文

- `-t`・`--title`・`-b`・`--body`・`-F`・`--body-file` を `-tx`・`-t=x`・`--title=x` の形も読み、最後のものを使う。
- 値は、引用符を外した語。`"$(cat <<'EOF' … EOF)"` (Claude が PR の本文を渡す形) は heredoc の本文に、
  `$(cat <file>)`・`$(< <file>)` はファイルの中身に置き換える。同じコマンドの前の方の `BODY=…`・`export BODY=…` は、
  値がちょうど `$BODY`・`${BODY}` のときに置き換える。ほかの `$( )` は中の文字のまま数える (中に参照の文字があれば拾う)。
- `--body-file -` は、そのコマンドの heredoc・here-string・`< file`、パイプの前の `cat <<EOF`・`cat <file>`・
  `echo`・`printf` を本文とみなす。読めないファイルは、語の文字のまま数える。
- 同じコマンドの前の方で書いたファイル (`cat <<EOF > f`・`echo … > f`・`printf … > f`・`tee f`) は、`--body-file`・
  `git commit -F` で書いた中身を読む (hook が走る時点では、まだ無いか古い中身のまま)。中身の分からない書き方 (ほかの
  コマンドの `> f`) なら読まない。

### 6. 公開範囲

- 参照が見つかったときだけ、`gh repo view <host>/<owner>/<repo> --json nameWithOwner,visibility` で引く (gh の repo が
  決まらないときは、その dir で `gh repo view`)。10 秒で切る (`timeout` の無いマシンでは切らない)。
- `PRIVATE`・`INTERNAL` は通す。`PUBLIC` と、引けない (gh が無い・未ログイン・時間切れ・github.com でない host) ものは
  止める。
- 控え (キャッシュ) は持たない。引くのは参照が見つかったときだけで、private から public に変えた直後に古い値で通さない
  ため (`ticket.py` の `repo_visibility` と同じ)。

### 7. 読み方 (ssh-agent-notice.sh との違い)

- 単純コマンドに分ける awk は `ssh-agent-notice.sh` のものを元にし、次を変えた: heredoc の本文と here-string と
  `< file` を、その単純コマンドの stdin として残す。語の中の改行を残す (code block の判定に要る)。`$( )` の閉じ括弧は、
  引用符・heredoc の本文・コメントを見て探す (本文の `1)` で閉じない)。`$( )` を値に置き換える (上の 5)。パイプで
  つながっているかを残す。`(( … ))` を飛ばす。
- 包むコマンド (`env`・`sudo`・`timeout`・`nohup`・`nix develop -c` など)・`bash -c`・`eval`・`cd`・`git -C` の
  扱いは `ssh-agent-notice.sh` と同じ。`cd`・`git -C` の行き先を解けない (`$( )`・変数) なら今の dir のまま見る。`-c` も
  script のファイルも無い shell (`bash <<EOF`・`bash -s`・`cat … | bash`) は stdin を読み直す。
- 読むのは 64 KB (gawk・mawk の無いマシンでは 16 KB) まで (バイトで数える。awk はバイトで読む)。それより長いコマンドは、
  コマンドの文字のどこかに参照か `git … push` があれば止め、本文をファイルにして `--body-file` で渡すか、コマンドを分けるよう
  返す。公開範囲は dir の repo で引き、private・internal なら通す (長いコマンドの `-R` は読まない)。`git … push` は 1 行の
  中だけで探す (改行をまたぐと、git の多い長い文書で長さの二乗の時間がかかる)。

### 8. 黙って通すとき

- Bash 以外・`push` と `gh` を含まないコマンド・jq が無い・入力が壊れている (tool の流れを止めない)。
- `git` が無い・repo でないなど、push する commit を引けないとき。

### 9. 止めたときに返す文

```text
[xref-guard] ほかの repo の issue・PR・commit への参照を書こうとしているので止めた。GitHub は参照先の timeline に跡を残し、付いた跡は本文を直しても force push で commit を外しても消えない。

git push → pollenjp/dotfiles (public な repo):
- commit 2f1b1b6「feat(nix): 最初の nixpkgs の例外として…」の 3 行目: NixOS/nixpkgs#577218 —「…release の musl 版 (NixOS/nixpkgs#577218 は review 待ち)」

直し方:
- commit の message からは参照を消し、「nixpkgs の PR 577218」のように # も URL も使わずに書く (commit の message は Markdown ではないので、backquote で囲んでも跡が付く)。参照は PR の本文に backquote で囲んで書く
- 直前の commit なら git commit --amend、前の commit なら git rebase で message を書き換えてから push し直す
- ユーザーがこの参照を書くと明示したときだけ、コマンドの頭に PJP_ALLOW_XREF=1 を付けて打ち直す (自分の判断では付けない)
```

- gh のときは「タイトル: <参照>」「本文の 5 行目 (backquote の外): <参照> —「…」」の形で並べ、直し方は「本文の参照は
  backquote で囲む (`[文](URL)` のリンクにもしない)」「タイトルからは消す (merge の commit の message に写る)」。
- 公開範囲を引けなかったときは「pollenjp/dotfiles (公開範囲を確かめられない: gh: …)」。
- 見つけた参照は 20 件まで並べ、残りは件数だけ書く。

## テスト

- `nix/tests/xref-guard.test.sh` (flake の checks の `xref-guard-test`。scriptTest): 合成した hook の入力・使い捨ての
  git の repo (remote の URL は github.com、remote-tracking ref は `update-ref` で作る)・偽の gh (公開範囲を返し、呼ばれた
  引数を書き留める) で、止める・通す・返す文を確かめる。
- `nix/tests/bootstrap-claude-hook.test.sh`: 登録が 1 件増える。前の形には足すだけ。hook が無ければ止まる。
- `nix/tests/claude-xref-guard.nix` (`claude-xref-guard-state`): hook が repo の script から実行できるファイルとして
  置かれる。
