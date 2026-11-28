# pjp-spaces (space の行の 2 行目に会話の端末の address と印、3 行目から解説動画を出す herdr-app の mod)

herdr-app 0.1.16 の同梱の spaces mod (sidebar の Spaces の一覧) を写し、会話の端末がいる space の行を 2 行にして、2 行目の頭に
会話の端末の hc の address、その後ろに会話の印 (❓・🌱・🌳[N]・🔄・👀・🗑️・↑ TKT-n) を、3 行目から解説動画を 1 本 1 行
(`🎬⏳:<名前>`・`🎬✅:<名前>`) で出す mod。旧 herdr の sidebar の 2 行目 (`ws-mark.sh` の token の stat・parent) の
hc 版 (claude-skills の spec `docs/superpowers/specs/2026-11-15-windows-herdr-app-hc-design.md` の §7.5)。印は label と hc の親子から、描くたびに
作り直す (旧 herdr の plugin の hook と控えは要らない)。

## 置き場所と取り付け

| もの | 置き場所 |
| --- | --- |
| mod (herdr-app が読むファイルだけ: `main.js`・`mod.json`) | dotfiles の `win/herdr-app/mods/pjp-spaces/` |
| 写した元 (herdr-app 0.1.16 の同梱の spaces。元のまま、改行は LF) | dotfiles の `win/herdr-app/upstream/spaces/` |
| test | dotfiles の `win/herdr-app/pjp-spaces.test.mjs` (dotfiles の root で `node --test win/herdr-app/pjp-spaces.test.mjs`。CI の workflow pjp-spaces も流す) |

- Windows へは dotfiles の Windows の runner (手順 `herdr-app-pjp-spaces`。on/off はホストの値の `herdrHub`) が、dotfiles の clone の
  mod のフォルダを `%USERPROFILE%\.config\herdr-app\mods\pjp-spaces\` へ記録つきで写す。junction にしない (herdr-app が mod の
  フォルダに `gpui-kit.d.ts`・`jsconfig.json` を書き足す)。使う layout の sidebar の block `spaces` の `content.mod` を `"spaces"` から
  `"pjp-spaces"` に替えるのも同じ手順 (dotfiles の `win/README.md` の「herdr-app の印 (pjp-spaces)」)。props も印のほかの振る舞いも
  同梱の spaces と同じなので、それだけで差し替わる
- mod を直したら、dotfiles の PR を merge → Windows で clone を進めて runner を流す (`dotfiles --self-update apply`) の順で配る。
  手で写さない (runner の記録とずれる)
- mod のフォルダには herdr-app が読むファイルだけを置く (説明はこのファイル)。`mod.json` の title は `Spaces (pjp)`
- pjp-spaces の入っていない herdr-app (同梱の spaces のまま) では、親子・子の数・動いている子は Agents 欄 (hc の親子の木) で見る

## 印

会話は、label `pjp.role` が `hub` か `child` の生きている端末 (`pjp mark name`・`pjp child new` が付ける。pjp-hc-child の
「印 (label) と表示」) と、生きている子のいる端末 (`pjp mark name` より先に子を立てた会話も入れる) と、解説動画の印
(`pjp.video.<id>`) のある生きている端末 (`pjp mark name` を打っていない Linux の会話でも、作った動画の印が出る。会話の手伝いの
端末は除く: 印は親の会話の行に出る)。子は、`parent` がその端末で
`pjp.role` が `child` の生きている端末。会話ごとに、頭に会話の端末の address、その後ろに印を旧 herdr の stat・parent と同じ並び
(頭に `❓`) で出す。

| 2 行目の頭 | 出すもの |
| --- | --- |
| address | 会話の端末の hc の address。`hc send` が届ける `<hc from="…">` の from と同じ形 (`terminals()` の `address`): このマシンの端末は素の ID (`t53`)、ほかのマシンの端末は `<machine>/<ID>`。印の有無を問わず、会話の端末がいる space の行には必ず出す。印との間は空白 1 つ、字の色は印と同じ |

| 印 | 出すとき |
| --- | --- |
| `❓` | ユーザーの答え・対応を待っている: その端末の `status` が blocked (確認の画面) か error (エラーで止まっている) か、label `pjp.asking` がある (文で問いを出している間。`pjp mark asking` が付け、答えが届くとハブの雛形の hook (`pjp mark hook prompt`) が外す。`pjp mark answered` も外す。hook は要旨を `pjp.asked` に移すが、`pjp.asked` は印を出さない。`status` は問わない)。印の先頭 (`🌱` より前) に出し、親の行へは伝えない |
| `🌱` | その端末に親がいる (`parent` が空でない) |
| `🌳[N]` | 生きている子が N 人 |
| `🔄` | 子か孫 (子をたどる) のどれかが working。`🌳[N]` の直後に出す |
| `👀` | 裏の作業が動いている: `records` に working がある (subagent) か、その端末が立てた手伝いの端末 (`pjp.role` の無い生きている端末。`hc run --bg`) が working。会話の状態は問わない。子孫の `👀` も上の親へ伝える (旧 herdr と同じ) |
| `🗑️` | `pjp.finished` があり、子が 0 人で、working でもなく、`❓` でも `👀` でもなく、作っている解説動画 (3 行目の `🎬⏳`) も無い |
| `↑ TKT-n` (親の名札) | 親の端末の `pjp.ticket`。無ければ (チケットの無い会話) 親の space の名前 (チケットの ID で始まる名前なら ID だけ)。親が `terminals()` にいなければ出さない |

解説動画は 2 行目に出さず、3 行目から動画 1 本に 1 行で出す (ユーザーが選んだ形。claude-skills の spec
`docs/superpowers/specs/2026-11-21-spaces-video-mark-design.md` の §11)。名前は印の名前 (`pjp mark video start` に渡した字) のまま。

| 行 | 出すとき |
| --- | --- |
| `🎬⏳:<名前>` | 解説動画を 1 本作っている (作り始めから載せ終えるまで。`pjp mark video start` から `done` まで) |
| `🎬✅:<名前>` | 解説動画を 1 本作り終えて載せたが、ユーザーがまだ見ていない。見たと言われて `pjp mark video watched` が外すまで出る |

- 例 (Windows のハブの会話 `t53`、ほかのマシンの子 `<machine>/t10d`。ハブの space の名前は `panel を直す` で、チケットのある
  ハブなら `TKT-n panel を直す`): ハブの space に `t53 🌳[2]🔄`、子の space に `<machine>/t10d 🌱 ↑ panel を直す` (チケットのある
  ハブなら `↑ TKT-n`)、子を片付けて閉じた会話の space に `t53 🗑️`、ユーザーに問いを出してターンを終えたハブの space に `t53 ❓🌳[2]`、
  確認の画面で止まった子の space に `<machine>/t10d ❓🌱 ↑ panel を直す`、印の無い会話の space に `t53`。解説動画を作っている子の
  space は 2 行目が `<machine>/t10d 🌱 ↑ panel を直す` で 3 行目が `🎬⏳:短尺 space の動画の印`、そのハブの space は 3 行目から
  `🎬⏳:短尺 space の動画の印`・`🎬✅:短尺 ハブで作った動画` の 2 行 (ハブで作った見ていない動画が 1 本)

  ```text
  [A] A dotfiles: panel の × を直す
      <machine>/t10d 🌱 ↑ panel を直す   dotfiles feat/…
  [h] panel を直す
      t53 🌳[1]🔄             h worktree/…
  ```

- address を頭 (avatar のすぐ右下。印より前) に置くのは、印の数で address の位置がずれないようにするため (印のすぐ後ろに置く案は
  退けた)。印は address の後ろになるので、狭い sidebar で 2 行目が右から切れても、address と `❓` は先に見える
- 解説動画の行のもとは、動画を作る端末の label `pjp.video.<作り始めた日時>` (値は 1 行の JSON: `name`・`state`
  (`making`・`done`)・`started`・`ended`・`from`)。動画を作る側 (動画の skill) が `pjp mark video start`・`done` で付け、
  `stop` (やめた)・`watched` (ユーザーが見た) で外す。subagent は会話の端末の `HC_TERMINAL_ID` を受け継ぐので、動画を作る
  subagent の印は会話の端末に付く。会話の端末・その手伝いの端末・子をたどった子孫とその手伝いの端末の動画を集め (`👀` と同じ範囲)、
  作っているものを先、見ていないものを後に、それぞれ作り始めた順に並べる。読めない値の label は数えない。
  同じ動画の写し (名前・作り始めた日時・状態が同じ。片付けで親へ移した後に子を終えられなかったとき) は 1 本に数える
- `pjp child cleanup` は子の見ていない動画の印をハブの端末へ移す (ユーザーが見るまでハブの行に出る)。`restart` は新しい端末へ
  引き継ぐ
- `❓` は `status` の done だけでは出さない。文で問いを書いてターンを終えた会話も、子の報告や merge を待つ会話も done で、
  `status` だけでは見分けられない (2026-11-18 の Windows の一覧でも done が 10 近くあり、多くは子の報告待ち・merge 待ちだった)。
  文の問いは、ユーザーに直に問いを出す会話 (ハブ) が、ターンを終える直前に `pjp mark asking '<問いの要旨>'` で知らせる。答えが
  届くと、ハブの雛形の hook (`pjp mark hook prompt`) が外す (子の報告・裏の作業の知らせでは外さない。hook の無い古い worktree
  では `pjp mark answered` で外す。pjp-hc-hub の SKILL.md の 1.)。子は親に聞くので打たない
- ユーザーの Claude は bypass で動き、子も `--dangerously-skip-permissions` で立つので、blocked はほぼ AskUserQuestion などの
  選択の画面のときになる。Claude Code は bypass の会話でも、選択の画面を出している間は status を blocked と報告する (2026-11-19 に
  Windows の Claude Code 2.1.318・herdr-app 0.1.16・hc 0.1.21 で確かめた。ハブの会話の行が `❓🌳[1]` になった。spec §13 の #14)
- `❓` は親の行へ伝えない (`👀` と違う)。子の行に出るし、子の blocked・error は hc が親に知らせる。`🔄` も今までどおり working の
  子孫だけを数える (blocked・error の子は数えない)
- Claude Code が `records` に載せるのは動いている subagent だけ。裏の Bash (`run_in_background`) と Monitor は、ターンを終えて
  done になった後も載らない (2026-11-17 に WSL の Claude Code 2.1.325 で確かめた)。なので `👀` は subagent か手伝いの端末が
  動いている会話に出る (旧 herdr は裏の shell だけを拾い、subagent を拾えなかった)
- 旧 herdr の `👀` は「ターンを終えて裏の作業を待っている会話」だったが、subagent が動いている間は、ターンを終えても会話の
  status が working のまま (2026-11-18 に Windows の Claude Code 2.1.318 と WSL の 2.1.325 で確かめた) で、待っている会話と
  ターンの中の会話を見分けられない。なので会話の状態を問わず出す (ターンの中で前の subagent を待つ間も出る)
- herdr-app 0.1.15 の `terminals()` は `records` を写す (2026-11-18 に Windows で、ハブの会話が subagent を動かしている間、
  その space の行が `🌳[3]👀` になった)。0.1.16 でも写す (2026-11-19 に Windows で、ハブの会話の subagent が `hc get` の
  `records` に載っている間に撮ると、その space の行が `🌳[1]👀` になった)
- 手伝いの端末は会話の子ではないので、`🌳[N]` にも `🔄` にも数えない。子の手伝いの端末が動いていると、子に `👀` が出て、
  それがハブへ伝わる (Agents 欄は、子の下の手伝いの状態を子の状態として出す)
- 1 つの space に会話が 2 つ以上いる (ハブの space `h` の tab に別の会話が並ぶ) と、会話ごとに頭へ address、その後ろに名札
  (`pjp.ticket`・英字・名前の順に、あるもの) を付け、「 │ 」で区切る (例 `t53 TKT-n 🌳[2] │ t5k TKT-m 🌳[1]🔄`)。名札が無い
  (address しか無い) 会話は address を二重に出さない。印の無い会話も address と名札を出す (address は必ず出すため)。並びは tab の
  順、同じ tab なら作った順 (hc の address は `t` の後ろが 36 進の数なので、桁の数、次に字の順で比べる)。会話が 1 つなら名札は
  付けない (1 行目の space の名前と重なる)。3 行目からの動画の行は会話ごとに分けず、その space の会話の動画をまとめて同じ並びにする
  (同じ space の親子の会話から 2 度集まった動画は 1 本。どの会話のものかは動画の行のホバーの頭に出る)
- 2 行目の address と印にホバーすると、会話ごとの説明 (チケット・端末・英字・待っているもの・親・子の数と英字・動いている子孫・動いている
  裏の作業・解説動画の数・済んだ日時) が出る。解説動画があれば、会話の行の下に字下げして 1 本 1 行で、状態・名前 (60 字で切る)・
  どの端末か (`この会話`・`子 A <machine>/t92`・`TKT-n <machine>/t40`・`手伝いの端末 t60`)・時刻を出す
  (`  🎬⏳:短尺 x (子 A <machine>/t92・11/21 13:05 から作っている)`・`  🎬✅:… (この会話・11/21 13:41 に載せた・見ていない・片付けた子 A (<machine>/t92) から移した)`)。
  3 行目からの動画の行にホバーすると、その 1 本の同じ説明が出る (space に会話が 2 つ以上なら、頭に `TKT-n · t1q: ` (チケットの無い会話は `チケットなし · t1q: `) の形でどの
  会話のものか)。`pjp mark show` の動画の行と `pjp mark video` の候補の行も同じ形。待っているものは、先頭に `待っている (確認の画面)`・`待っている (エラーで止まっている)`・
  `待っている (問い: <pjp.asking の要旨>)` の形で出る (重なれば `・` で並べる。要旨の改行と続く空白は 1 つの空白にし、60 字を
  超える分は `…` にする。`pjp mark asking` も 60 字を超える要旨には note を出す)
- 端末の space は label `herdr.space` で引く。ほかのマシンの端末の label は、そのマシンの中の id なので、頭に `<machine>/` を
  足して `spaces()` の id と比べる。label の無い端末は、映っているペイン (`panes()`) から引く

## 行の形

- 会話の端末がいる space の行は 2 行 (高さ 44。worktree を本体の下に字下げした行は 42)。1 行目に avatar (worktree の行は枝) と
  名前を行の幅いっぱいまで (同梱の 1 行の行は名前と git が幅を分け合う)、2 行目の左に会話の端末の address と印、右に同梱の 1 行目の
  git (repo・branch・ahead/behind)
- 解説動画があれば、3 行目から 1 本 1 行 (行ごとに高さ 17 を足す。行の高さ 16 と行の間 1 は 2 行目と同じ)。字下げと字の大きさ
  (11.5px) も 2 行目と同じで、字の色は作っている間 (`🎬⏳`) がテーマの ansi3 (黄)、見ていない間 (`🎬✅`) が ansi2 (緑)。長い名前は
  行の幅で `…` になる (全部は動画の行のホバーで見る)。動画の本数に上限は置かない
- 2 行目の git は、address と印が字の幅を取った残りに出す (溢れたら git の側が `…` になる)。address と印だけでも溢れる (1 つの space
  に会話がいくつもいる・sidebar が狭い) と、右の端 (`↑ TKT-n` の側) から `…` になる。同梱 (0.1.16) の git は、1 行の行で名前と
  字の幅の比で譲り合う形 (`flex_auto`・最小 48px) なので、そのままでは長い branch に印が削られる。2 行目だけ 0.1.15 の形
  (`flex_1`・最小 0) に戻している
- 印の無い会話でも 2 行のまま (印が付け外しされるたびに行の高さが変わって一覧がずれないように)。2 行目の左には address だけが出る。
  会話の端末がいない space は同梱と同じ 1 行 (高さ 30・28)。動画の行だけは、動画を作り始めた・見たと外したときに行の高さが変わり、
  下の行がずれる (ユーザーが承知のうえで選んだ。`🎬⏳` から `🎬✅` に替わるときはずれない)
- 細い表示 (sidebar が 160px 未満の rail) には 2 行目も動画の行も無いので、space のセルにホバーすると名前と 2 行目の文字 (address と
  印) と動画の行が出る
- 一覧を表示中の space の行までスクロールして見せるのは、表示中の space か一覧の中のその位置が替わったときと、mod の大きさが
  替わったとき (上のほかの mod の領域が伸びた・窓の大きさが替わった) だけ。行の高さが替わって一覧の中身が伸び縮みしても (解説動画の
  行の増減・会話の行が 1 行と 2 行で替わる・表示中の space より下で space が増減する)、ユーザーがスクロールした位置は動かさない。
  元 (0.1.16) は一覧の要素に `on_size_change` を付けていて、中身の高さが替わるたびに表示中の space の行へ戻した (動画の行の増減で
  ユーザーのスクロールが戻ったので、mod の root に移した。2026-11-22)

## 名前の置き場所

- space (名前・folder・tab・ペインと端末) は、マシンごとに、そのマシンの hc の core の doc `herdr-app` にある (hc の API の
  `doc.get`。CLI には無く `hc connect` で読む)。値は `{"spaces": [{"id", "name", "folder", "tabs": [{"id", "name", "root"}]}]}`
  (Linux では `~/.local/state/herdr-core/default/docs.json`)。端末の label `herdr.space` は、そのマシンの中の space の id
  (`spaces[].id`)
- herdr-app は doc の event を読んで、space の一覧を描き直す。herdr-app の無いマシンで doc を書き替えても付いてくる (2026-11-21 に
  SSH 先の Linux から `doc.set` で名前を替えると、Windows の herdr-app が、その space の端末の label `where` を新しい名前に書き直した)
- `pjp mark name` は、herdr-app のあるマシン (Windows のハブ) では `herdr-app do space.rename`、無いマシン (SSH 先や WSL の Linux の
  ハブ) では、そのマシンの doc の、この端末の space の `name` だけを書き替える (`doc.set` は版が合うときだけ書くので、合わなければ
  読み直して打ち直す。pjp-hc-child の `pjp mark --help`)
- 子の space も、herdr-app の無いハブでは doc で扱う (pjp-hc-child の `references/delegate.md`)。`pjp child new` は新しい id の
  label `herdr.space`・`herdr.tab` で子を立て、herdr-app がその id で作った space の `name` を `<英字> <label>` にする (作られなければ、
  名前つきの space を doc に足す)。`restart` は前の端末を消すのを、herdr-app が新しい端末を space に置いた後にして space を
  空にせず、名前を前と同じにそろえる。`cleanup` は、子の端末を消すと herdr-app が space を消すのを待ち、残っていれば (中に
  ほかの生きた端末が無ければ) doc から消す (子のほかの端末がいれば、確かめの段で止まる)。
  別のマシンの子の doc は、`doc.get`・`doc.set` の `on` で指す
- herdr-app が doc に見せる振る舞い (2026-11-21 に SSH 先の Linux から確かめた): 知らない id の label を付けた端末を見ると、その id の space を
  作る (name は空で、一覧にはフォルダ名が出る)。既に space に入っている端末の label を付け替えても動かない。space の最後の端末を
  消すと space を消す。doc から space を消すと画面から消える (中の端末は終わらない)

## 名前の幅

2 行の行の名前は、1 行目の、sidebar の幅から avatar (worktree の行は字下げと枝) を引いた幅まで出て、溢れた分は `…` になる。
1 行の行 (会話の端末がいない space) は同梱のまま (0.1.16 は、名前と git がそれぞれ字の幅から始めて、行が埋まると字の幅の比で
譲り合う。どちらも 48px より狭くならない。0.1.15 までは名前を 150px で切っていた)。

**決まり: space の名前は 42 桁に収める** (半角 1 桁、全角 (漢字・かな・全角の記号) と絵文字 2 桁)。ユーザーの今の sidebar の幅
(406px) の worktree の行で、名前を出しきれる桁。ハブの worktree の会話の space は本体 `h` の下に字下げされるので、字下げの無い
行 (ほかのマシンの子の space など。44 桁) も含めて、狭い方に揃える (旧 herdr の 29 桁も、字下げした行の値をどの名前にも使った)。

| 名前 | 使える桁 |
| --- | --- |
| ハブの会話 `<short-desc>` (`pjp mark name`。チケットがあれば `TKT-n <short-desc>`) | short-desc は 42 桁 (全角だけなら 21 字)。チケットの ID を頭に付けるなら、その分を引く (`TKT-` と 3 桁の数と空白の 8 桁なら、残り 34 桁・全角 17 字) |
| 子 `<英字> <repo>: <一言>` (`pjp child new --label '<repo>: <一言>'`) | `--label` は 42 桁から `A ` (2 桁。AA 以降は 3 桁) を引いた 40 桁。一言はさらに `<repo>: ` を引いた残り (`claude-skills: ` なら 25 桁・全角 12 字、`dotfiles: ` なら 30 桁・全角 15 字) |

測った値 (2026-11-19 に Windows の herdr-app 0.1.16 で、props の width を替えた物差しの行で数えた。`…` の前に見えている字の数。
画面の倍率 120%。右端の常に出るスクロールバーの分も含む):

| sidebar の幅 | 字下げの無い行: 半角 | 全角 | worktree の行: 半角 | 全角 |
| --- | --- | --- | --- | --- |
| 268px (layout main の既定) | 26 | 15 | 24 | 14 |
| 406px (ユーザーの今の幅) | 44 | 26 | 42 | 24 |
| 480px (最大) | 54 | 31 | 52 | 30 |

- 2026-11-18 に herdr-app 0.1.15 で測った値と同じ。違うのは 406px の字下げの無い行の全角だけ (0.1.15 は 25、0.1.16 は 26)。
  決まりの 42 桁は worktree の行で決めているので変わらない

- 全角 1 字は半角の約 1.75 字の幅。全角を 2 桁と数えると、全角まじりでも桁の数で収まる (全角だけの名前は 21 字 = 42 桁で、
  24 字まで出る行に収まる)。物差しの半角は数字と大文字なので、`W`・`M` の多い名前は少し早く切れる
- sidebar を狭めると切れる: 268px では worktree の行で 24 桁まで (42 桁の名前は 18 桁ぶん `…` になる)。sidebar の幅を
  大きく替えたら、物差しで測り直して決まりを直す
- 3 行目からの動画の行 (`🎬⏳:<名前>`) は 2 行目と同じ字下げで、字が名前の行 (13px) より小さい (11.5px) が、頭の `🎬⏳:` の分を
  引くと、出せる字の数は名前の行とほぼ同じ。測った値 (2026-11-22 に Windows の herdr-app 0.1.16 で、物差しの 3 行目の、`🎬⏳:` の
  後ろに見えている字の数):

  | sidebar の幅 | 字下げの無い行: 半角 | 全角 | worktree の行: 半角 | 全角 |
  | --- | --- | --- | --- | --- |
  | 268px | (読めず) | 14 | 22 | 13 |
  | 406px | (読めず) | 26 | 43 | 25 |

  (字下げの無い行の半角は、物差しの 1 本目が一覧の上に隠れて読めなかった)。**目安: 解説動画の印の名前も 42 桁に収める** (space の
  名前と同じ数え方。406px の worktree の行の動画の行に出しきれる)

## 確かめ用の props

layout の sidebar では付けない。ペインに開いて確かめるときに渡す。

| props | すること |
| --- | --- |
| `"debug": true` | 一覧の上に物差しの行を 4 本 (字下げの無い行と worktree の行に、半角 70 字・全角 40 字を 1 本ずつ。10 字ごとに `A`・`B`… と `十`・`廿`・`卅`・`卌` の目盛り。動画が 1 本ある行の形で、1 行目が名前、3 行目が `🎬⏳:` の後ろに同じ物差しを置いた動画の行)、一覧の下に印に使う生の値 (`terminals()` の件数とキー、space の id、会話の端末と解説動画の label のある端末ごとの address・parent・status・report・records・labels と、読んだ動画ごとの `video <address> <キー>: <state> <started>〜<ended> <name>` の行) を出す |
| `"width": <px>` | その幅で並べる (ペインで sidebar の幅を写す。今の sidebar は 406 (layout の `.state` の sidebar の size)、layout main の既定は 268) |

## 確かめ方 (Windows。herdr-app の窓が要る)

Linux (SSH 先・WSL) には herdr-app が無いので、窓で見る確かめは Windows のハブの会話がする。mod を一時の名前 `pjp-spaces-try` で置いて
ペインに開き、shot で見て、片付ける。ユーザーの layout は替えない (差し替えは dotfiles)。

PowerShell から herdr-app を打つときは、いつも出力を pipeline に流す (`| Out-String`・`| ConvertFrom-Json`・`| Out-Null`)。
herdr-app.exe は GUI の exe で、PowerShell は出力を pipeline に流すときだけ終わりまで待つ。行に単独で打つと待たずに次へ進み、
出力は空・`$LASTEXITCODE` は前のコマンドの値のままで、herdr-app は後から `os error 232` で落ちる (`references/panel.md` の
PowerShell の手と同じ決まり)。

1. 置いて check する (PowerShell。clone の作業ツリーと index には触らない)

   ```powershell
   $hh = if ($env:HERDR_APP_HOME) { $env:HERDR_APP_HOME } elseif ($env:XDG_CONFIG_HOME) { Join-Path $env:XDG_CONFIG_HOME 'herdr-app' } else { Join-Path $HOME '.config\herdr-app' }
   $clone = Join-Path $HOME 'ghq\github.com\pollenjp\dotfiles'
   git -C $clone fetch origin <確かめる branch か main>
   $zip = Join-Path $env:TEMP 'pjp-spaces-try.zip'; $tmp = Join-Path $env:TEMP 'pjp-spaces-try'
   git -C $clone archive --format=zip -o $zip FETCH_HEAD win/herdr-app/mods/pjp-spaces
   Expand-Archive -Path $zip -DestinationPath $tmp -Force
   Copy-Item -Recurse (Join-Path $tmp 'win\herdr-app\mods\pjp-spaces') (Join-Path $hh 'mods\pjp-spaces-try')
   herdr-app check (Join-Path $hh 'mods\pjp-spaces-try') | Out-String
   "check: $LASTEXITCODE"
   ```

2. ペインに開く: panel のまとめのペイン (控えの `summary`。`references/panel.md`) の下に `pane.split` で開く。props は
   `{"debug": true, "width": <px>}` (px は今の sidebar の幅と layout の既定の 268。一覧の下の生の値まで見るなら、背の高いペインに
   開く)。ID はペインの控えに書き足す (閉じるときに使う。panel を開き直す前に閉じる。開き直すと控えを書き直し、ID が消える)

   ```powershell
   $arg = @{ direction = 'down'; pane = '<まとめのペイン>'; mod = 'pjp-spaces-try'; props = @{ debug = $true; width = 406 } } | ConvertTo-Json -Compress
   $r = (herdr-app do pane.split $arg | Out-String).Trim()
   "split: $LASTEXITCODE $r"
   ```

3. `herdr-app shot <scratchpad の png> | Out-Null` で撮り、Read で見る (ハブの tab に替えた直後は、前の tab の絵が撮れることが
   ある。描き直してから撮る)。開いてから 6 秒ほど待って撮る (0.1.16 では、開いた直後の 3 秒ほどは git の確かめが済む前の絵で、
   worktree の行が字下げされず、2 行目の右の git も無い。さらに 3 秒後には揃っていた)
   - 2 行目の頭の address が、その space の会話の端末の address (`hc ls --json`・`pjp child ls`。子からの `<hc from="…">` と同じ字) か。
     ハブの space は素の ID (`t53`)、ほかのマシンの子の space は `<machine>/<ID>`。avatar の右下 (1 行目の名前の頭と同じ字下げ) に出て、印は
     その後ろに空白 1 つで並ぶか。印の無い会話の space にも address だけが出るか
   - 印が `hc ls --json`・`pjp child ls` の親子と label に合うか (ハブの space に `🌳[子の数]`、子の space に `🌱 ↑ <親の名札>` (親のチケットか、無ければ親の space の名前)、
     動いている子があれば `🔄`)。絵文字が欠けずに出るか、2 行の行の字と字下げが詰まりすぎていないか
   - 一覧の下の生の値: `keys:` に `labels`・`parent`・`status` があるか、ほかのマシンの子の `parent` が素の端末の ID
     (`t1m` の形) か、space の id の頭に `<machine>/` が付くか
   - `👀`: 会話で subagent を走らせている間 (`hc get <会話の端末> --json` に `records` が載っている間) に shot を撮り、その会話の
     space に `👀` が出るか (herdr-app 0.1.15 でも 0.1.16 でも出た。herdr-app を上げたら見直す)。subagent に前景で
     `Start-Sleep -Seconds 120` だけを打たせると、harness が止める (subagent は背景に回してすぐターンを終え、`records` から消える)。
     合図のファイルができるまで 2 秒ごとに見る loop を前景で打たせ、撮ってからファイルを作ると撮れる
   - `❓`: 会話で `pjp mark asking '<要旨>'` を打って shot を撮り、その会話の行の印の先頭に `❓` が出るか、印のホバーの先頭に
     `待っている (問い: <要旨>)` が出るか、`pjp mark answered` で消えるか。確認の画面 (AskUserQuestion など) で止まっている会話
     (`hc get <会話の端末> --json` の `status` が blocked) の行にも出るか (herdr-app 0.1.16・Claude Code 2.1.318 では出た。herdr-app か
     Claude Code を上げたら見直す)。子の `❓` が親の行に伝わらないか、`pjp.finished` のある会話で `🗑️` と並ばないか。sidebar を
     狭くし (width 268)、branch が長い worktree の行でも、2 行目の印 (`❓` を含む) が残って git の側が `…` で切れるか
   - 解説動画の行: ハブの端末と子の端末に `pjp.video.<id>` の label を付けて (`hc label <端末> 'pjp.video.<id>={"name":"…","state":"making","started":"…"}'`。
     本物の会話で付けるなら `pjp mark video start`) shot を撮り、子の行の 3 行目から `🎬⏳:<名前>` が 1 本 1 行で出るか、2 行目に
     動画の印が無いか、ハブの行に子の分も並ぶか、⏳ が ✅ より先か、動画の行と 2 行目の印のホバー、`pjp.finished` を付けた会話で
     ✅ だけなら 2 行目に `🗑️` が出て、⏳ があれば消えるか、width 268 で長い名前が行の幅で `…` になるかを見る。終わったら付けた
     label を `key=` で外す
   - スクロール: ユーザーに、表示中の space の行が見えなくなるまでペインの一覧をスクロールしてもらい (1 回で済むよう、動画の行の
     ある子の行が見える所まで)、その間に子の端末の ⏳ を付け外しして、一覧が表示中の space の行へ戻らないかを見る。続けて
     確かめのペインの高さを替え (ペインを `pane.split` で割ってから閉じるなど)、一覧が表示中の space の行まで戻るかを見る (元の、
     mod の大きさが替わったときに表示中の space を見せる働き)
   - 名前の幅: 物差しの行で、字下げの無い行と worktree の行の、半角と全角それぞれの最後に見えた目盛りを読む (1 行目が名前、3 行目が
     動画の行)。props の width を替えて開き直し (今の sidebar の幅・268・480)、同じく読む
4. 片付ける: 開いたペインを ID を指して閉じ (`pane.close` を ID なしで打たない)、`<home>\mods\pjp-spaces-try` と
   `$zip`・`$tmp` を消す

herdr-app 0.1.16 での確かめ (2026-11-19。0.1.16 の差を取り込んだ pjp-spaces を `pjp-spaces-try` として置き、props の debug と
width でペインに開いて撮った):

- `herdr-app check` は通り、`status` の errors も無かった
- 名前の幅は上の「名前の幅」の表。`👀` は「印」の節のとおり出た
- `❓`: `pjp mark asking` でその会話の行の印の先頭に出て、`pjp mark answered` で消えた。width 268 で、branch が長い worktree の
  行の 2 行目は `❓🌳[3]🔄` が残り、git の側が `worktree/noble-bay…` と切れた
- 窓で見ていないもの (0.1.16 では窓で見ていない。test で見ている): 表示中の space へのスクロール (表示中の行が一覧の上の方に
  あり、スクロールが起きなかった)・子の行 (短いペインで一覧の下に隠れた)・1 行の行・ホバー・細い表示 (rail)

解説動画の印の確かめ (2026-11-21。動画を 2 行目に組で出していた前の版を `pjp-spaces-try` として開いた):

- 2 行目の印のホバーに、会話の行とその下の動画ごとの行が出た (ユーザーが見た)。width 268 で、2 行目は git の側から、次に印の
  右の端から `…` になった
- PR の版の `pjp mark show`・`pjp mark video stop --all`・`watched` が Windows と WSL をまたいで動き、ハブの `hc ls --json` は子の
  端末を `<machine>/t92`・parent `t48` で並べた (`watched` と `stop` が子孫をたどる前提)
- 3 行目から 1 本 1 行の今の形・動画の行の字の数・`🗑️` との並びは、まだ窓で見ていない

解説動画の行の確かめ (2026-11-22。3 行目から 1 本 1 行の版を `pjp-spaces-try` として開いた):

- ハブの行は 2 行目が `🌳[1]` と git だけで、3 行目から子 A の分も入れて 3 本 (⏳ は黄、✅ は緑) が並んだ。width 268 で長い名前は
  行の端で `…` に切れ、2 行目の印は残った
- 子 A の行 (⏳ と `pjp.finished` がある) は 2 行目が `🌱 ↑ TKT-n` で 🗑️ が出ず、⏳ を外すと `🌱🗑️ ↑ TKT-n` と ✅ の 1 本に
  なった。ハブの行も子 A の行も 1 行ぶん低くなった
- PR の版の `pjp mark show` は、端末と子孫の動画を `🎬⏳:… (子 A <machine>/t108・11/21 15:10 から作っている)` の形で並べた
- 見込みと違った所: 動画の行を増減すると、ユーザーがスクロールしていた一覧が表示中の space の行まで戻った (`pjp.finished` だけを
  付けて行の高さが替わらないときは戻らなかった)。上の「行の形」の、`on_size_change` を root に移した直しの元

## herdr-app を上げたら (元との差を取り込む)

herdr-app は起動のたびに同梱の mod を書き戻すので、上げた後の Windows には新しい元しか残らない。3-way で取り込む基に、
`upstream/spaces/` に写した元を残してある。足した・替えた所には `pjp-spaces:` の注がある。

```sh
# dotfiles の worktree の root で。新しい元は Windows の herdr-app の home から (WSL なら /mnt/c/Users/<Windows のユーザー名>/.config/herdr-app)
new=/mnt/c/Users/<Windows のユーザー名>/.config/herdr-app/mods/spaces
tr -d '\r' <"$new/main.js" >"<scratchpad>/spaces-new.js"
git merge-file win/herdr-app/mods/pjp-spaces/main.js win/herdr-app/upstream/spaces/main.js "<scratchpad>/spaces-new.js"
# 衝突 (<<<<<<<) があれば直す。済んだら元の写しを新しい版にする
tr -d '\r' <"$new/main.js" >win/herdr-app/upstream/spaces/main.js
tr -d '\r' <"$new/mod.json" >win/herdr-app/upstream/spaces/mod.json
```

- `main.js` の頭の注とこのファイルの「写した元の版」(今は herdr-app 0.1.16) を新しい版に替える。元の `mod.json` が変わっていたら、
  pjp-spaces の `mod.json` (title だけ違う) にも写す
- 元の一覧の `on_size_change` (表示中の space を見せ直す) は、pjp-spaces では mod の root に移してある (「行の形」)。元のその辺りが
  変わったら、root に付けたままになるように取り込む (一覧の要素に戻すと、行の高さが替わるたびにスクロールが戻る)
- dotfiles の root で `node --test win/herdr-app/pjp-spaces.test.mjs` と下の型の確かめを流し、Windows で「確かめ方」を流してから PR にする

## 直したら

- `node --test win/herdr-app/pjp-spaces.test.mjs` (dotfiles の root で。CI の workflow pjp-spaces も流す): 印の計算 (`spaceMarks`) と、
  偽の要素で `render` を通した行の形 (高さ・2 行目と動画の行の文字・ホバー・rail・props) を見る
- 型 (herdr-app の型が手元にあるとき): herdr-app が mod のフォルダに書く `gpui-kit.d.ts` (herdr の型も入る) を `main.js` と同じ
  一時ディレクトリに写し、次の tsconfig で `tsc -p <dir>/tsconfig.json` (tsc は dotfiles の devShell に無い。手元に無ければこの確かめを
  飛ばし、PR の本文にそう書く)。同梱の spaces でも出る色の型の
  `TS2345` (`` `#${string}` `` に string を渡す) 4 件と、同梱 (0.1.16) の `both()` の `TS2339` (`PromiseSettledResult` の
  `value`) 1 件だけなら通り (2026-11-19 に 0.1.16 の `gpui-kit.d.ts` で、同梱の spaces にも同じ 5 件が出ると確かめた)

  ```json
  { "compilerOptions": { "target": "ES2022", "module": "ES2022", "moduleResolution": "bundler", "lib": ["ES2022"],
      "allowJs": true, "checkJs": true, "strict": false, "skipLibCheck": true, "noEmit": true },
    "files": ["main.js", "gpui-kit.d.ts"] }
  ```

- 窓での確かめ (`herdr-app check`・shot) は Windows で上の「確かめ方」
