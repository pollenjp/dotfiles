---
name: pjp-hc-hub
description: >-
  `HC_TERMINAL_ID` がある会話 (herdr-app と hc の中) で、ハブ (`~/h`。Windows は `%USERPROFILE%\h`) かその worktree
  (`~/.herdr/worktrees/h/…`) にいるときに、会話の最初に読む (ハブの CLAUDE.md がそう指示する)。ハブを作る・雛形を直した
  PR を反映する (`pjp hub init`・`pjp hub check`。dotfiles の Windows の runner が打つ) とき、`pjp hub hello` が NG や !! を
  出したとき、Write / Edit が hook (`pjp hub guard`) に「… はハブ (pjp-hc-hub) の中」「… は repo (…) の中」「… は WSL (…) の
  git の work tree (…) の中」で止められたとき、ユーザーへの問い・状況・子の進み具合と PR の木・手順や流れの図を panel
  (herdr-app の mod `pjp-hub-panel` のペイン) で見せる・panel の図 (SVG と動き) を描く・ユーザーが panel の節に付けた消す印 (×) を読む・
  木の段に answer を書く・ユーザーが段を押した印 (panel.steps.json) を読む・panel を開き直す・問いのペインを開け閉めするとき、
  herdr-app の mod `pjp-spaces` (space の行の 2 行目の会話の印と、3 行目からの解説動画の行) を直す・確かめる・herdr-app を上げて
  取り込むとき、ハブの worktree を片付けるときも読む。T3 Code の中の会話 (`T3CODE_THREAD_ID` があり `HC_TERMINAL_ID` が無い) は
  pjp-t3-hub を使う (pjp-t3-hub がこのファイルを読み替えて使わせる)。
---

# 集約ハブ (herdr-app と hc) で会話する

skill の一覧に `pjp-hc-hub-private` (private な claude-skills の足し分) があれば、会話の始めに、このファイルの後でそれも読む
(Dev Tracker のチケット・Notion のコメント・解説動画の手)。無ければ、このファイルだけで動く (チケットを持たないハブ)。

ハブは herdr-app と hc の集約会話の受け口。Windows では `%USERPROFILE%\h` (`~/h`) に置き、ハブの会話は Windows の
Claude Code (PowerShell の tool) で動く。コードを持たず、herdr-app の worktree で会話を 1 つずつ分けるためだけに git 管理
している (remote は無い。push しない)。ハブの会話は、質問なら repo を読んで答え (答えは panel の Q&A に書く。下の「ユーザーの問い
への答え」)、repo の中を変えるなら直す repo ごとに子 (手元の WSL か SSH 先の Linux の Claude) を `pjp child new` で立てて任せる。
旧 herdr のハブ (WSL の `~/h`。`HC_TERMINAL_ID` の無い会話) は `pjp-herdr-hub` の決まり。T3 Code の中の会話 (同じハブ。T3 の
worktree のスレッドの `~/.t3/worktrees/h/…`) は `pjp-t3-hub` の決まりで、このファイルを T3 の違いの分だけ読み替えて使う。

**ユーザーの指示 (2026-10-20、2026-11-08 に改めた):** ハブの中にファイルを散らかさない。コードの変更があれば必ず子を立てる。

道具は `pjp` から打つ (`pjp hub …`・`pjp child …`・`pjp mark …`・`pjp pack …`。公開の dotfiles の道具 `nix/pkgs/pjp-tools`。Linux は
home-manager の package、Windows は dotfiles の runner の手順 pjp-tools が置く)。bash でも PowerShell でも同じ字面で打てるよう、
手順にパイプ・`jq`・`$(…)`・`&&` を使わず、shell が展開しないよう `~` を含む引数は `'~/h'` のように一重引用符で囲む。`pjp ticket` など
の private な道具は、private な claude-skills の shim (`pjp-skills`) のあるホストだけで動く (無いホストでは「private な claude-skills の
道具で、このホストには入っていません」と出して終了コード 127)。

**panel (ユーザーの指示 2026-11-17・2026-11-18・2026-11-19):** herdr-app の mod `pjp-hub-panel` のあるハブ (herdr-app の home の
`mods\pjp-hub-panel\main.js` がある所。今は Windows の runner が配った所だけ) では、ユーザーへの問い (merge してよいか・
選択肢)・子の進み具合・状況・流れ・手順・比べる案・ユーザーにしてほしいこと (どこを見て何を押すか) を、端末の横のペインの
panel にも出す。panel は 2 つのペインに分ける: まとめ (進み具合の木・状況・図) は端末の左に開いて残し ([まとめ | 端末] の 1:1)、問いは
出すときだけ端末を割ってその右に問いのペインを開き ([まとめ | 端末 | 問い])、答えが届いたら閉じる (閉じた幅は左隣の端末へ
戻る)。herdr-app には左へ割る手も幅を決める手も無いので、まとめは端末を右に割ってから `pane.swap` で入れ替える (ユーザーの
指示 2026-11-17・2026-11-18。この指示を、ペインを開け閉め・入れ替えする依頼とみなす)。ペインの ID は控えのファイルから
引いて閉じ、`pane.close` を ID なしで打たない (ハブの端末が閉じうる)。問いは返答の文にも短く書く (ユーザーが panel を見ていない
ことがある)。まとめの一番上 (Q&A の節があればその下) には進み具合の木 (節「チケット・進み具合・PR」。この会話の下に子を、その下に子の
進み具合の段と PR を入れ子にする。チケットがあれば行はチケットにし、ID と題は押すと開くリンク) を置き (2026-11-19。ユーザーが × で外したら、
新しい行が来るまで置かない。配った mod がこの節を知らなければ、前の 3 つの節で書く)、panel.json を書くたびに、その前にユーザーが × で付けた
消す印を読んで、その節を外す (2026-11-18)。済んだもの (済んだ行・done の段・merged の PR・済んだ話の図や説明) はハブから外さず、行は
状態を進めるだけ、節は `done: true` と `collapsed: true` を付けて下へ移し、mod が小さく畳んで出す (ユーザーの指示 2026-11-27)。panel を
開く・書く・閉じる前に `references/panel.md` を読む。
呼び名は「panel」で、ユーザーへの文 (返答・問いのカード・panel の中身・子への依頼) でも「panel」と書き、「板」とは言わない (ユーザーの
指示 2026-11-19: 問いの文で「板」と書かず、panel と呼ぶ)。これは panel を指すときの決まりで、株の注文の「板」の
ような別の意味の語はそのまま使う (ユーザーの補足 2026-11-19)。
ユーザーが `/pjp-hc-hub-panel` (hc の pack の skill。一覧では名前だけ) と打ったら、その skill を読み、panel を開いていなければ開き、
開いていれば開き直すか今の状況に書き直す (panel を開き忘れたときにユーザーが呼ぶ。手順は同じ `references/panel.md`)。

**ユーザーの問いへの答えは panel の Q&A に書く (ユーザーの指示 2026-11-23):** herdr-app では、ユーザーの問いへの答えがほかの子の
返答と重なり、どこで答えたかが分からなくなるため。答えは panel の Q&A の節の項目 1 つにトグルの形で書き、トグル 1 つごとに消す指示を
出せるボタンを置く。ユーザーの問い
(知りたいこと・確かめたいこと) への答えは、まとめのペインの一番上 (進み具合の木の上) の Q&A の節に、問い 1 つを開け閉めできる項目
1 つとして足して書き (新しい項目を頭に開き、前の項目は畳む)、端末の返答は「panel の Q&A に答えた: <問いの要旨>」の 1 行だけにする。
頼みごと・承認・ハブの問いへの答え・子の報告の取り次ぎは Q&A にせず、今までどおり端末と問いのペイン。項目ごとの × の印も、節の印と
同じく次に panel.json を書く前に読んで外す。書き方・雛形・qa を知らない mod のときは `references/panel.md` の「Q&A (ユーザーの問いへの
答え)」。panel を使えないハブ (mod の無いハブ・T3 Code の会話) では、今までどおり返答の文で答える。

**panel の説明はまず図で描く (ユーザーの指示 2026-11-18):** 状況・流れ・手順・比べる案・ユーザーにしてほしいことは、図 (SVG と
marks の動き) から描く。文は図の上の「いま」・図の下の 1 行・図に描けないことに留め、「いま」と図に描けないことの箇条書きは、
太字の見出しの項目を親にし、詳細をその下に一段下げた子の項目にする (ユーザーの指示 2026-11-19。見出しの項目は「いま」が 1〜3 つ・
図に描けないことが 3〜5 つ、詳細はそれぞれ 1〜3 行)。箇条書きの複雑な項目 (流れ・前と後・分岐・3 つ以上がかかわる) には、その下に
ミニ絵 (幅 200・高さ 80 の小さな図) を付けられる (ユーザーの承認 2026-11-19。1 回の書き直しで 3 枚まで。`references/panel.md` の
「ミニ絵」)。文だけで足りるのは 1〜3 行の知らせなど。panel に説明を書く前に `references/panel-figures.md` を読み、雛形
(`assets/panel/`) を写して描く。
panel で動くのは、1 枚の SVG に重ねる marks (流れる点・点滅する枠) だけ。場面を順に流す説明・押して見比べる見本は、6. の表の
「動く説明」のとおり HTML で作る (panel には出さない)。

**ユーザーの番の段は panel で押して伝えられるようにする (ユーザーの指示 2026-11-23・補足 2026-11-24):** ユーザーに委ねた段 (解説動画を
見るなど) は、ユーザーが panel のその段を押して、済んだことを会話に伝えられるようにする。押しただけで送らずに別の話へ移ったときも、
× を押したときと同じく次の書き直しで処理する。進み具合の木の段のうち、ユーザーの番の段 (ユーザーが手で確かめる段など) には、送る文 answer (「何を -> どうした」の
1 行) を書く。ユーザーが段を押して (①)「送る」(②) と、answer が問いの答えと同じ手でこの端末に届く。① だけで ② を押さなかった段は、
mod が panel.json の隣の `panel.steps.json` に印を残す。panel.json を書くたびに、その前に (消す印より先に) その印を読み、送られていない
印を「その answer が届いた」とみなして処理する。届いた answer も拾った印も端末で直に言われたときと同じに扱い、処理したら段を done に
して answer を外す。書き方と読む手は `references/panel.md` の「段の answer (押して送る)」と「段を押した印 (panel.steps.json)」。

## 1. 会話の始め

- 最初に `pjp hub hello` を打つ (ハブの CLAUDE.md の入口で打っていれば打ち直さない)。ハブの中か・雛形どおりか・この端末が
  状態を報告しているか・hc の machine (子を立てるマシン) につながるかを 1 行ずつ出す (手元の WSL の machine には「手元の WSL」と
  添え、Windows のハブに WSL の machine が無ければ「hc の machine (WSL)」の !! で足し方を出す。7. の「子を立てるマシンを足す」)。
  private な足し分 (`pjp-skills`) のあるホストでは、見回り役 (`pjp-hubd`) が動いているかの行も出る (公開の道具は見回り役を立てない)。
  NG はユーザーに伝えて直してもらう。!! の行は、その場で困るもの (子を立てるマシンにつながらない・WSL でしか動かない作業なのに WSL の
  machine が無いなど) だけ伝える。「この端末」の代わりに「T3 のスレッド」の行が出たら T3 Code の会話なので、`pjp-t3-hub` に移る
- 同じ worktree で前の会話を続けているとき (`claude -c` など) に、前の会話で panel を開いていたら、`references/panel.md` の「開き直す・
  置き場所を移す」で panel の props を確かめる
- **会話の主題が分かったらすぐ、この会話の space に名前を付ける** (ユーザーの指示 (2026-10-28): 何の会話かが herdr-app の
  一覧で分かるように)。最初の 1 往復のうちに `pjp mark name '<short-desc>'` を打つ (チケットのあるハブでは、頭にチケットの ID を
  付けた `'TKT-n <short-desc>'`。足し分の手)。space の名前を替え (herdr-app の無い Linux のハブでは、そのマシンの hc の doc
  `herdr-app` を書き替える。`references/spaces.md` の「名前の置き場所」)、この端末に label `pjp.role=hub` (名前がチケットの ID で
  始まれば `pjp.ticket` も) を付ける。short-desc は粗くてよい。付け直すのは方針が決まったとき・最初の子を立てたとき・主題が変わった
  ときだけ。名前は 42 桁に収める (半角 1 桁、全角と絵文字 2 桁。頭にチケットの ID を付けるなら、その分を引く。sidebar の space の
  一覧 (mod pjp-spaces) で名前が切れない桁。`references/spaces.md` の「名前の幅」)
- **ユーザーに問いを出してターンを終えるときは、答えを待つ印を付ける** (ユーザーの指示 2026-11-18: 答え・対応を待っている
  会話が space の一覧の印 `❓` で分かるように)。文で問い (方針の承認・merge してよいか・選択肢) や、ユーザーにしてほしい
  操作 (ログインなど) を出してターンを終える直前に `pjp mark asking '<問いの要旨>'` を打つ。答えが届くと (panel からでも、
  端末で直にでも)、雛形の hook (`pjp mark hook prompt`。UserPromptSubmit) が `❓` を外して要旨を label `pjp.asked` に移し、そのことを
  文脈で知らせる (ユーザーの指示 2026-11-19: 答えた後に外すのを hook で確実に)。答えを読んで、問いが済んだら `pjp mark answered`、
  答えていない問いが残る・新しい問いを出すなら `pjp mark asking '<その要旨>'` を打つ (どちらも `pjp.asked` を外す)。どちらも打たずに
  ターンを終えると、Stop の hook (`pjp mark hook stop`) が 1 回だけターンを続けさせて確かめさせる (2 回目は `pjp.asked` を外して終える)。
  子の報告 (`<hc from=…>`) や裏の作業の知らせが届いただけでは、hook も外さない。panel の問いのペインを開け閉めするのと同じ時
  (`references/panel.md` の「問いを出す」「答えが届いたら」) で、panel の無いハブでも打つ。hook の無い worktree (雛形に hook が入る前に
  切った worktree。`pjp hub hello` が !! を出す) では、今までどおり答えが届いたら answered を打つ。確認の画面 (AskUserQuestion など)・
  エラーの `❓` は mod pjp-spaces が status から出すので打たない (`references/spaces.md` の「印」)
- **図のファイルは scratchpad に絶対パスで書く** (相対パスで書くとハブの中にでき、hook が止める)。panel に出す図だけは 6. の表の
  置き場所

## 2. 子を立てずに済むとき (質問・このマシンの設定)

質問・相談のほか、このマシンの設定を直しただけ・片付けただけの会話も、子を立てずに終える。

- repo は読むだけ: ファイルを読む・`git -C <checkout> log` などの状態を見るコマンド。Windows に無い repo は `gh` で読むか、
  子のマシンの checkout を `hc exec --on <machine> -- git -C <checkout の絶対パス> log …` で読む (`hc exec` は shell を通さない
  ので `~` は展開されない)。build やテストのように repo の中に何かを作るコマンドと `git fetch` は打たない (要るなら 3. で
  子に任せる)
- repo の外にあるこのマシンの設定を変えるだけの依頼もハブで直す (それぞれの skill の確認の決まりはそのまま)。dotfiles が
  置くもの (`~/.claude` の skill・settings など) は dotfiles を直す子に任せる。反映に checkout で動く道具 (dotfiles の
  runner など) が要るなら、ハブからは打たず、ユーザーに `! <コマンド>` で打ってもらう
- 終わったら 4. の終わり方 (`pjp mark finished`)

## 3. repo の中を変えるとき (集約)

- 方針の承認は、ユーザーの CLAUDE.md の「方針を承認したら PR まで走り切る」の 1 回をハブで取る。直す中身も PR までも
  ユーザーが言い切っている依頼は、それを承認とみなしてよい。設計の文書が要るなら scratchpad に書き、依頼に場所を書いて
  子の repo に commit させる (子の repo の CLAUDE.md が置き場を別の repo に決めていれば、そちら)
- 子の effort は既定の high。深い思考が要る・ミスが致命的な作業は max をそこそこの頻度で選び、直す中身を依頼文で言い切れる作業は
  medium に落とす (迷ったら、深さで迷うなら high・致命的かもと迷うなら max。目安と、承認を取る文への書き方は `pjp-hc-child`)
- 直す repo ごとに `pjp-hc-child` の手順で子を立てる (`pjp child new --repo <owner/repo> …`)。`--on` を省くと、SSH 先の Linux を
  空きの多い順に自動で選び、使える所が無ければ手元の WSL に立てる。WSL でしか動かない作業 (Claude in Chrome を使う子・WSL の中を
  直す作業・Windows の WSL に依る作業) だけ `--on wsl` を付ける (`wsl` は、`hc machine ls` の手元の WSL の machine を名前によらず選ぶ
  語)。1 行の変更でも自分では直さない。依頼文・子への答えは scratchpad のファイルに書いて渡す (`--brief <ファイル>`・
  `pjp child send <英字> --file <ファイル>`)。子の claude は既定で `--no-chrome` で立ち、Claude in Chrome を使わせる作業の子だけ
  `--chrome` を付ける (ユーザーの決まり 2026-11-15)
- 子はハブと同じ Claude のアカウントで立つ (ユーザーの決まり 2026-11-19)。`~/.claude` が既定で、ほかのアカウントのハブは、
  herdr-app で worktree を切った後に、その端末で `claude-work` などを手で打って起こす (herdr-app の新規の menu は素の claude の
  まま。複数のアカウントを同時に使うため)。`pjp child new` はハブの `CLAUDE_CONFIG_DIR` から子のマシンの `claude-<名前>` を
  選び、子のマシンにそのアカウントの用意が無ければ何も作らずに止まる (替えるなら `--account <名前>|default`。`pjp-hc-child` の
  `references/delegate.md` の「アカウント」)
- 子の英字と控えは、この会話ごとに持つ (`pjp child ls`。チケットが無ければ、この端末の住所で控える)
- 子の報告は `<hc from="<machine>/t13">…</hc>` の形でこの会話の入力に届く。質問・報告・確認の画面・片付けは `pjp-hc-child` の
  とおり。子の PR が merge されたら、片付けの前に、子の報告の「merge の後にすること」のうち子がするものを子に頼んで済ませ、ユーザーが
  手元でするもの (pull・dotfiles の runner など) はユーザーに伝える
- 子を立てたとき・子の報告で進み具合が変わったとき・子の PR を merge してよいかをユーザーに聞くときは、panel にも出す (冒頭の
  「panel」。進み具合の木の行と段も進め、ユーザーの番になった段 (手で確かめる段など) には answer も書く。足す行と進める欄は
  `references/panel.md` の「チケット・進み具合・PR」)
- checkout で動かして checkout の中を書き換える作業は、その checkout で子を立てて任せる (`pjp child new --on <machine> --dir <checkout>`。
  既にあるパスは、同じパスのほかのマシンを自動で選ばないよう `--on` で名指しする)

## 4. 会話の終わり

- `git -C <この worktree> status --short --ignored` を見る。この会話で作ったものが残っていたら scratchpad へ移すか消す。
  作った覚えの無いもの (ユーザーが置いたもの・Claude Code が書いた `.claude/settings.local.json`) は触らず、要れば伝える
- 会話の作業が済んだら `pjp mark finished` を打ち、この端末に label `pjp.finished` を付ける (worktree の会話だけに付く。足し分の
  Dev Tracker のあるハブでは、チケットを閉じると付く)。子を片付けていれば、herdr-app の space の行の 2 行目に 🗑️ が出る (mod pjp-spaces。
  印の意味・取り付け・直し方は `references/spaces.md`)。ユーザーはそれを見て worktree を消す (5.)。答えを待つ印 (`pjp.asking`) が
  残っていると 🗑️ の代わりに ❓ が出るので、付ける前に `pjp mark show` で `pjp.asking` と `pjp.asked` を見て、問いが済んでいれば
  `pjp mark answered` を打つ (両方を外す)。作っている解説動画の行 (`🎬⏳:<名前>`) があっても 🗑️ は出ない。見ていない動画の行
  (`🎬✅:<名前>`) は、2 行目の 🗑️ の下に残る (`pjp mark show` の「動画」の行。子を片付けると、子の印はこの会話の端末へ移る)
- 子を立てたなら: 子の PR が全部 merge されたら、子を片付けて `pjp mark finished`。merge 待ちの子が残るなら子は残し、子の英字・
  端末 (`<machine>/t13` の形)・space・worktree・PR を返答に書き (scratchpad は消えることがある)、「merge したら、この worktree で
  `claude -c` して知らせる (子の「merge の後にすること」・子の片付けをこの会話がする)」と書く
- 子を立てずに終わるなら、`pjp mark finished` だけ

## 5. ハブの worktree を片付ける

- 消してよいのは、その会話の子を全部片付け、済んだ worktree。space の印に 🗑️ が出ているもの (`pjp.finished` があり、子が 0 人で、
  動いていない会話) がそれに当たる。印を付ける前に閉じた会話の worktree には出ないので、子が残っていないか (`pjp child ls`) で見る。
  見分けられない worktree は、消す前にユーザーに見せる。ハブの worktree には commit が無いので、消して失うのは会話の続き
  (`claude -c`) だけ
- 会話の中からは自分の worktree を消さない (Windows では、動いている process の cwd のディレクトリを消せない)。ユーザーが
  herdr-app の「Remove worktree」で消す
- T3 Code の worktree (`~/.t3/worktrees/h/…`。branch は `t3/…`) は T3 が作り、T3 が持つ。git や worktree の片付けの道具
  (`git worktree remove` など) で消さず、ユーザーが T3 の画面でスレッドと一緒に消す (`pjp-t3-hub` の 5.)。T3 のハブが子のスレッドを
  立てるリンク先 (SSH 先の Linux など) の `~/.t3/worktrees/<repo>/…` も同じ

## 6. ハブに置かないもの

| 作るもの | 置き場所 |
| --- | --- |
| 依頼文・子への答え・図の下書き・控え | scratchpad (絶対パス) |
| 動く説明・操作できる見本 (アニメーションで流す説明・案の見比べ) | scratchpad に 1 ファイルの HTML で書き、場所をユーザーに伝える (足し分の Dev Tracker のあるハブでは、会話のチケットに埋め込む)。panel には出さない |
| panel の中身 (panel.json) | scratchpad の panel だけのフォルダ (例 `<scratchpad>\hub-panel\panel.json`。`references/panel.md`) |
| panel のペインの控え (panes.json) | scratchpad の、panel のフォルダの隣 (例 `<scratchpad>\hub-panel-panes.json`) |
| panel に出す図 (SVG) | herdr-app の home の `pjp-hub-panel-media\<会話の名前>\` (チケットがあればチケットの ID。panel は home の下の図しか読めない。mod のフォルダには置かない) |
| 設計の文書 (spec・ADR) | 子の repo (子に commit させる)。その repo の CLAUDE.md が置き場を別の repo に決めていればそちら |

## 7. ハブを作る・新しくする

Windows のハブ `%USERPROFILE%\h` は、dotfiles の Windows の runner (手順 hc-hub) が公開の `pjp hub init` で作る (初回も更新も)。
WSL の旧ハブ (`~/h`) は `~/dotfiles/setup` が旧 herdr のハブの道具で作る (`pjp hub init` は旧 herdr のハブを書き換えずに止まる)。

```text
pjp hub check                                       書かずに雛形との差を見る (差があれば終了コード 1)
pjp hub init                                        ~/h を作る・雛形との差だけを直す (打ち直してよい)
pjp hub init --dir '<一時ディレクトリ>'               雛形を試す
```

- `pjp hub init` は git init・決まりのファイル 3 つ (`CLAUDE.md`・`.claude/settings.json`・`.gitignore`)・
  `git config pjp.devtracker.repo ~/h` (ハブの印) と `pjp.hub.skill pjp-hc-hub`・署名しない commit をする。別の repo の中・remote を
  持つ repo・ハブの worktree・ほかの skill のハブ (旧 herdr のハブ)・まだハブでないのに雛形の外のものがある場所では、
  何も書かずに止まる (`pjp hub --help`)
- 雛形は dotfiles の `nix/pkgs/pjp-tools/crates/pjp-hc-hub/assets/hub/` (道具に埋め込む)。直した PR が merge されたら、ユーザーが
  dotfiles の Windows の runner を打てば (Release の exe を置き直してから `pjp hub init`) `~/h` に写る。ハブからは打たず、ユーザーに頼む。
  作り済みの worktree の `CLAUDE.md`・`.claude/settings.json` は古いまま残る (`pjp hub hello` が !! で出す)。hook の道具は PATH の
  `pjp` から打つので、道具を新しくすれば作り済みの worktree でも新しくなる。雛形に足した hook は、登録が settings.json にあるので、
  その後に切った worktree の会話から効く
- 雛形を直す PR の前に試すなら、dotfiles の worktree の `nix/pkgs/pjp-tools` で `cargo run --bin pjp-hub -- init --dir '<一時ディレクトリ>'`
- `~/h` の決まりのファイルを手で直しても、`pjp hub init` が雛形へ戻す (作りどおり)。決まりを変えるなら雛形を直す
- 公開の雛形の `settings.json` は hook の登録 (Write / Edit の前の `pjp hub guard`、答えが届いたときの `pjp mark hook prompt`、
  ターンの終わりの `pjp mark hook stop`。8.) だけを持つ。private な足し分の skill `pjp-hc-hub-private` が雛形の重ね
  (`assets/hub/settings.overlay.json`。形は `{"skillOverrides": {"<skill>": "on", …}}`) を持っていれば、`pjp hub init`・`check`・`hello` が
  その skillOverrides を重ねる (ハブでよく使う pack の skill を説明つきに戻す。中身と、旧 herdr のハブの雛形との食い違いの確かめは
  claude-skills の側)。重ねのファイルが壊れていれば、何も書かずにパスとわけを出して止まる (終了コード 2)
- ハブで `/skills` の画面を開いて Esc で閉じると、その場の値が `.claude/settings.local.json` に書かれ、雛形の on より強くなる。
  pack の skill の説明がハブで消えたら、まずそこを見る
- herdr-app の New worktree で付ける branch 名は、旧ハブの `worktree/<名前>` の形にしない (旧ハブの見回りと読み分けるため。
  `pjp hub hello` が !! で出す)

### 子を立てるマシンを足す (hc の machine)

machine を足す・外す・作り直すときは、hc の machine のほかにも直すもの (ssh の接続先など) があるので、手順の skill があればその表と順を
なぞる (hc の machine は Windows のハブと Linux のハブで別々に持つ。ハブごとに打つ)。

子は `hc machine ls` の machine に立つ。SSH 先は `hc machine add <Host> [--name <名前>]` で足し (`<Host>` は ssh の設定の Host)、
`hc machine rm <名前>` で外す (向こうの端末は動いたまま残る。外す前にその machine の子を `pjp child cleanup` で片付ける)。Windows の
ハブの手元の WSL は `--via` で足す (ディストリビューションの名前は `wsl.exe -l -v` で見る)。`--cd ~ -e bash -lc` は WSL のホームで
login shell を起こし、dotfiles が入れた道具 (claude・ghq・pjp) を PATH に入れる。

```text
hc machine add --via 'wsl.exe -d <ディストリビューション> --cd ~ -e bash -lc' --name <名前>
```

- 名前は自由。`pjp child new --on wsl` は名前によらず、`--via` のコマンドが wsl.exe の machine を選ぶ。`hc exec --on`・
  `hc file write --on` には、足した名前を渡す (手順の `<WSL の machine>`。`pjp hub hello` の「hc の machine」の行に「手元の WSL」と出る)
- Windows のハブに WSL の machine が無いと、`pjp hub hello` が「hc の machine (WSL)」の !! で足し方を出す。hc の設定を変えるので、
  ユーザーに伝え、足してよいと言われてからハブで打つ
- 名前を `local`・`auto` にした machine と、名前を `wsl` にした SSH 先は、`pjp child new --on` で名指しできない (語が名前より先。
  `pjp hub hello` が !! で出す)。`hc machine rename <名前> <新しい名前>` で替える (替えると、その machine の端末の住所も替わる)。
  名前を `wsl` にした手元の WSL の machine は、語と同じ machine を指すのでそのまま使える (一時の machine は除く)

## 8. hook (`pjp hub guard`) に止められたら

ハブの `.claude/settings.json` が、Write / Edit / MultiEdit / NotebookEdit の前に `pjp hub guard` を呼ぶ。止めるのは
ハブの中 (ハブの別の worktree と `.git` も)、remote を持つ repo の中 (checkout・`~/.claude/skills/pjp-*` の先)、WSL の
`\\wsl.localhost\…` の git の work tree の中 (子の worktree)。理由の文のとおり scratchpad に書くか、子に任せる。Bash や
PowerShell に書き換えて回り込まない (hook はコマンドを見ないが、決まりは同じ)。

- 止めた理由は、Claude Code の画面に「PreToolUse:Write hook error: … はハブ (pjp-hc-hub) の中 …」の形で出る。error と
  あるが、hook が決まりどおりに止めたもの (2026-11-16 に Windows で確かめた)
- hook の command は shell の書き方を使わないので、Claude Code が hook を Git Bash で動かしても (Git for Windows のある
  Windows。確かめた)、PowerShell で動かしても (Git Bash の無い Windows) 同じ字面で動く。止める理由は ASCII だけの JSON で
  返す (code page で化けない)
- 入口の `pjp` は、`pjp` と同じディレクトリに `pjp-hub` が無いときは終了コード 127、在るのに起こせないときは 1 で終わる (2 にしない。
  2 だと hook に「止める」と読まれ、ハブの会話の Write / Edit が scratchpad へのものも含めて全部止まる)。`pjp` が PATH に無いときと同じく、
  hook のエラーとして出るだけで書き込みは止まらない (guard も効いていない)。dotfiles の道具を置き直す (Windows は `dotfiles apply` の手順
  pjp-tools、Linux は home-manager の switch)
- 答え待ちの印の 2 つの hook (`pjp mark hook prompt; exit 0`・`pjp mark hook stop; exit 0`。1.) は、guard と違って何も
  止めない。どう落ちても (`pjp` が無い・道具の設定の誤り・hc が落ちた) `; exit 0` と道具の側でいつも 0 で終え、発言は
  そのまま届き、ターンの終わりで回り続けない (失敗は hook の stderr に出て、Claude には見えない)。Stop の hook が続けさせた回は、
  transcript に「Stop hook feedback」と出る (エラーではない)
- 道具を直したら: dotfiles の `nix/pkgs/pjp-tools` で `nix develop ../..#pjp-tools --command cargo test --workspace` (Windows は CI の
  workflow pjp-tools)。偽のホームの一時ディレクトリにハブと repo を作って流し、手元の `~/h` と hc には触らない
