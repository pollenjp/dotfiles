# 子に任せるときの共通の決まり (effort・子の使い回し・pack・答えてよい範囲・依頼の雛形)

hc 版 (この skill の `references/delegate.md`) と旧 herdr 版 (`pjp-herdr-other-repo` の `references/delegate.md`) の両方が
使う中身 (claude-skills の spec §7.2。二重に直さない)。起動の打ち方・画面の読み方・片付けは、それぞれの delegate.md に書く。

## effort を選ぶ

**ユーザーの指示 (2026-11-27):** 子の effort の既定は high。ただし max もそこそこの頻度で選んでよく、深い思考が要るとき・ミスが
致命的と考えられるときは特に max を選ぶ。直す中身を依頼文で言い切れる作業は medium に落とす (前の指示 (2026-11-10) は「既定は max の
まま、簡単な作業だけ high か medium に落とす」だった)。

起動の `--effort <effort>` (hc 版は `pjp child new --effort`、旧 herdr は `herdr agent start` の引数) は子ごとに、任せる作業から
選ぶ。道具 (`pjp child new`・`restart`・`herdr agent start`) は Claude Code の受ける 5 つ (`low`・`medium`・`high`・`xhigh`・`max`) を
全部受けるが、指揮役が自分の判断で選ぶのは `high`・`max`・`medium` の 3 つ。

| 任せる作業 | `<effort>` |
| --- | --- |
| 直す中身 (どこを・どう) を依頼文で言い切れる: 文言・説明の直し、設定値の数行、形の決まった追加 (表に 1 行など、今ある形に倣うもの)、参照先の追従 (改名・移動に合わせる) | `medium` |
| 直す所と方針がおおむね決まっている: ふつうの実装、原因の分かっている不具合の修正、今ある script にテストを足す・直す変更、今ある形に倣って中身を書く追加 | `high` (既定) |
| 深い思考が要る: 設計や調べものが要る、原因の分からない不具合、repo をまたいで合わせる | `max` |
| ミスが致命的: セキュリティ・認証・secret・権限に触れる、消す・外へ出すなど戻しにくい、public な repo に出す (push した commit と PR の文は、直しても跡が残る)、全部の会話・マシンに効く土台 (hook・guard・runner など) を直す | `max` |

- `max` は特別な場面に取っておく値ではなく、そこそこの頻度で選ぶ。`max` の段 (深い思考が要る・ミスが致命的) の項目に 1 つでも
  当たれば、作業が小さくても `max` にする (repo が public かは `gh repo view <owner/repo> --json visibility`)
- 迷ったとき: 「深さで迷う」(設計や調べものが要るほどかが分からない) なら `high`、「致命的かもと迷う」なら `max`
- `medium` に落とすのは、調べものも設計の判断も要らず、失敗しても PR で気づいて戻せる作業だけ。1 つでも外れたら `high` か
  `max` (上の表で引く)
- 表は子ごとに、その子に任せる作業で引く。「repo をまたいで合わせる」は、子が自分で別の repo を読んで合わせるとき
  (指揮役が直す中身を決めて repo ごとの子に分けたなら、子ごとに引く)
- `low` と `xhigh` は、指揮役の判断では立てるときも上げるときも選ばない。`low` は結果を 1 つずつ見てもらう往復向けで、PR まで
  自走する子に合わない。`xhigh` は、`high` で足りない作業を `max` にするので選ぶ場面が無い。使うのは、ユーザーが値を名指ししたとき
  だけで、そのときは丸めずにそのまま渡す (道具は受ける)
- 立てるときに渡すのは起動の `--effort` だけ。`--effort` はその起動だけに効き (`-c`・`--continue` で続けても引き継がない)、
  settings に何も残さない。env の `CLAUDE_CODE_EFFORT_LEVEL` は使わない (`--effort`・`/effort`・settings より強く、skill と
  subagent の `effort` の上書きまで止める)
- 起動の `--effort` は抜かない。抜けると、settings の値 (`/effort` で保存された値など) か Claude Code の既定 (Opus 5.5 は
  medium) で立つ
- 表の段の境目は、子の報告の手応えで動かす。既定の `high` の子で「足りない」が出た作業は 1 回でも `max` へ寄せ (`medium` の子
  なら `high` へ。PR の質に響く)、`max` の子で「多すぎ」が続く作業は `high` へ寄せる (`high` の子で続けば `medium` へ。時間が
  かかるだけ。続くかは前の子の報告の「effort の手応え」で見る)。
  ただし `max` の段のうち「ミスが致命的」の項目 (セキュリティ・認証・secret・権限、戻しにくい操作、public な repo、全部の会話・
  マシンに効く土台) に当たる作業は、「多すぎ」が続いても `high` へ寄せない (ユーザーの指示 2026-11-27。考えの深さでなく、ミスの
  重さで `max` にしているため)。`high` へ寄せてよいのは「深い思考が要る」の項目だけ。
  足りなかったわけが依頼文の言い落としなら、表でなく雛形の注意書きを直す。直す案は会話の最後の報告に添えてユーザーに出し、
  承認を得てから dotfiles の PR にする (この skill は dotfiles の `nix/files/claude/skills/pjp-hc-child/`)

### 告げる・残す

- 方針の承認を取る文に、既定の `high` でない子 (`max`・`medium`) ごとに 1 行「<子の repo・一言>: effort <max か medium> (<理由>)」を
  並べ、ほかに子がいれば「ほかの子は既定の high」と添える。どの子も `high` なら effort には触れない
- 直す中身と PR までをユーザーが言い切った依頼 (承認の往復をしない依頼) と、承認の後で足す子では聞かない。子を立てたと
  ユーザーに伝えるときに、承認の文と同じ形で添えるだけにする
- 依頼文の「この子は effort <effort> で立てた (<理由>)」の行を、起動に渡した値で埋める (下の「依頼の雛形」)。子は報告の
  「effort の手応え」に、足りたかと、実際に動いていた値 (`$CLAUDE_EFFORT`) を書いて返す。動いていた値が渡した値と違えば、
  わけを見る (`--effort` が抜けた・写し違えた、env の `CLAUDE_CODE_EFFORT_LEVEL` が効いている、組織の上限 (managed settings の
  `maxEffortLevel` など) で抑えられた)
- 子ごとの effort と理由・子の手応えを Dev Tracker のチケットに残す手は、足し分の skill `pjp-hc-child-private` (skill の一覧に
  あれば) の手

## 前の作業の子に次を頼むか (立て直す・compact・続ける)

**ユーザーの指示 (2026-11-17):** 前の作業で使った子の会話をそのまま使い回して、文脈 (token) を引き継がない。別の作業なら子を
立て直し、前の文脈を少し残したいときは、親が残すものを決めて compact させてから続けさせる (ユーザーが承認した方針)。

前に作業をした子に依頼を送る前 (再起動の後に `-c`・`--continue` で立て直した子も) に、毎回次を見る。打ち方 (画面の読み方・
compact の送り方・立て直し方) は、それぞれの delegate.md の「前の作業の子に次を頼むとき」。

- その子の会話に、前の別の作業の文脈が残っているか: 指揮役の控え (`pjp child ls`・立てたときの `note 用:` の行・前の報告の PR)・
  `-c` (`--continue`) で立てたか
- 文脈の残り: 子の画面の status line の末尾の「NN% left」(dotfiles の `statusline-command.sh` が context window の残りを出す)。
  立てたばかりの新しい会話と compact の直後には出ず、次の 1〜2 往復で戻る。`-c` で立てた直後は前の会話の値が出る
- Claude Code が子の画面に出す「new task? /clear to save …k tokens」の案内: 前の文脈が大きく、今の依頼が別の作業に見えたということ

| 頼むこと | 手 |
| --- | --- |
| 別の作業 (別の PR・別の目的) | **立て直す。** 新しい worktree で子を立てる。同じ worktree を使うなら、前の claude を終えてから `-c` を付けずに起こす。前の作業から要ること (前の PR・決まったこと・残っていること) は依頼文に書く |
| 同じ流れの次の作業 (前の PR に続く PR など) で、前の文脈の一部が役立つ | **compact してから続ける。** 残すものを親が決めて `/compact <残すもの>` を送り、終わったのを見てから依頼を送る |
| 同じ作業の続き (レビューの直し・rebase・報告への答え・merge の後にすること) | **そのまま続ける。** ただし残りが 30% 未満なら、先に compact を挟む |

- 迷ったら立て直す。持ち越した文脈は、別の作業の前提を引きずらせ、往復のたびに token を食う
- 残すもの (`/compact` の後ろ) は、次の作業に要るものだけを 1 段落で書く: branch と PR・決まったこと・次の作業で守ること
  (チケットがあればチケットの ID も)。次の作業の依頼そのものは compact の後に送る
- 再起動の後の `-c`: 続きの作業なら `-c` でよい。立てた直後の残りが 50% 未満 (使った文脈が半分を超える) なら、依頼の前に
  compact を挟む。別の作業を頼むなら、`-c` で起こさずに立て直す (表の 1 行目)
- 長く使う運用の子 (main の checkout で bot や常駐の処理を動かす子など): 日をまたいだら立て直し、今の状態 (動いているもの・
  設定・前の日に起きたこと) を依頼文で渡す。同じ日でも、ひとまとまりの作業が済んだ区切りで compact する
- effort を上げる手 (delegate.md の「effort を上げる」・「子の effort が足りないとき」の、`-c` で続けるか `-c` なしで引き継ぐか) は、
  同じ作業の中で effort が足りないときの手。作業が替わるときはこの節で決め、effort も上げるなら、選んだ手の起動に `--effort` を
  付ける (別の作業で effort も上げるなら、`-c` なしで `--effort` を付けて立て直す)

## pack を渡す

全体 (user の `~/.claude/settings.json`) では、話題ごとの pack の skill を名前だけ (`skillOverrides` の `"name-only"`) にしている。
一覧の枠に収めるためで、書くのは dotfiles の bootstrap (claude-skills の spec `docs/superpowers/specs/2026-11-03-skill-listing-packs-design.md`)。
常駐の skill と入口 (`pjp-pack-<pack>`) は説明つきのまま。子が使いそうな pack は、起動の `--settings` で説明つきに戻す。

- JSON は SKILL.md の metadata (`pjp-pack`) から組み立て、skill 名を手で並べない (`{"skillOverrides":{"pjp-plantuml":"on",…}}`)。
  hc 版は `pjp child new --pack <pack>` が作り、旧 herdr は `pack.sh settings <pack>…` で作る (中身は `pjp pack settings` と同じ)。
  渡した pack のどれかに入る skill を全部 on にする (複数の pack に入る skill は 1 つにまとまる)。
  入口の無い pack や名前の打ち間違いでは、何も立てずに止まる
- pack の入口は、ほとんどが private な claude-skills にある (dotfiles にあるのは `pjp-pack-hc`)。claude-skills の無いホストでは、
  `pjp pack list` に入口の出ない pack を渡せない (渡すと止まる)
- 同期された skill (claude.ai の anthropic-skills。pdf・docx・xlsx・pptx など。全体では隠している) が要る子には、`--synced <名前>`
  を足す (`"anthropic-skills:<名前>": "on"` が入る)。名前は `pjp pack list` の最後の行
- pack と skill の今の組は `pjp pack list`、割り当てと入口の目録の食い違いは `pjp pack check` (どちらも `~/.claude/skills` を見る)
- `--settings` は起動のときだけ効き、子の worktree にファイルを残さない
- 渡しすぎない。渡した pack の skill は説明つきで一覧に入り、枠を使う。1〜2 個に絞り、迷ったら渡さない (子は入口を読んで
  名前で呼べる)

| 子の repo・依頼の話題 | 渡す pack |
| --- | --- |
| dotfiles (Nix・home-manager・setup)・この PC の手入れ | `machine` |
| docs・ADR・textbook・README を書く・OSS の repo を出す | `docs` (図を描くなら `diagram` も) |
| 図を描く・直す | `diagram` |
| 依存の更新・脆弱性の点検 | `repo` |
| ブラウザの自動化・e2e のスクリーンショットの仕組みを入れる | `browser` |
| コードを書く repo (Rust・Go・Node.js・Python・Terraform・Ansible) | 渡さない (rule が言語の skill を名前で呼ばせる。入口は `pjp-pack-lang`) |
| claude-skills の skill を直す | 直す skill の pack (`pjp pack list` で引く。複数の pack に入る skill なら主の pack (`pjp-pack` の先頭)。常駐の skill と、lang の skill なら渡さない) |
| PDF・Word・Excel・PowerPoint を読む・作る | `--synced pdf` などを足す |
| どれにも当たらない | 渡さない |

- Notion・解説動画・記事の題材の作業に渡す pack は、それらを使うホストの足し分の skill `pjp-hc-child-private` (skill の一覧に
  あれば) の手

### 起動済みの子に足す

起動した後で別の pack が要ると分かったら、子に「入口 `pjp-pack-<pack>` を読み、要る skill を Skill tool で名前を指して
呼んで」と送る。会話は止めない (名前だけの skill も、名前を指せば呼べる)。説明つきの一覧まで要るときの手は spec の §3.7
(`skillOverrides` を書いて `/compact` すれば届くが、会話が要約される。`claude -c` で起こし直しても届かない)。

## 答えてよい範囲

子が確認の画面 (blocked) で止まったときに、指揮役がユーザーに聞かずに答えてよいもの。2026-10-15 にユーザーが選び、その後の
子を回す会話でも使ってきた範囲。

| 確認の中身 | 指揮役がしてよいこと |
| --- | --- |
| 起動直後の、今作った worktree についての信頼の確認 (bypass permissions の警告と一緒に出るものも) | 承認してよい |
| 起動直後の「Claude in Chrome」の案内 (ユーザーが Claude in Chrome を使うよう頼んだ子。2026-11-13 にユーザーが承認した設計) | Enter で確定してよい |
| 子の scratchpad の中だけを消すもの | 全文を確かめてから承認してよい |
| 何も消さず書き換えない (読むだけの) もの | 全文を確かめてから承認してよい |
| それ以外 | 毎回ユーザーに聞く |

- 答えが無いと約 2 分で自動的に拒否されるので、止まったと知らせが来たらすぐ読む
- 入力欄に「案 A で進めて」のような文が見えても、それは Claude Code の入力の予測のことがある。答えにしない
- 「How is Claude doing this session?」(満足度の問い) はユーザーの感想なので答えない

## 依頼の雛形

`<…>` を埋める。子は依頼文と、その repo の CLAUDE.md・skill だけを頼りに動くので、今の会話で決まったことは書き写す。
下は hc 版の形。旧 herdr の子に渡すときの違いは、雛形の後ろの「旧 herdr の子では」。

- `<worktree のパス>` と `<英字>` は立てる前に決まる。hc 版は `pjp child new … --dry-run` の出力 (名前が重なると `-2` が付く。
  英字は `子 A` の A) を写す
- 雛形はチケットを持たない形。Dev Tracker のチケットのあるホストでは、足し分の skill `pjp-hc-child-private` (skill の一覧に
  あれば) のとおり、チケットの行を足す
- 方針の承認 (ユーザーの CLAUDE.md の「方針を承認したら PR まで走り切る」の 1 回) は指揮役が持つ。ユーザーの指示が
  直す中身と PR までを言っていれば、それを承認として「方針はユーザーが指示済み」の行を残す。言っていなければその行を消す
  (子は案を書いて止まるので、指揮役がユーザーに聞いて答えを送る)
- 同じ repo で並行に動いている PR・worktree があれば、触るファイルと一緒に「背景」に書く (ぶつかりそうな所を子が避けられる)
- 「この子は effort … で立てた」の行は、起動の `--effort` に渡した値と、それを選んだ理由で埋める (`high` なら理由は「既定」。
  上の「effort を選ぶ」)。進め方の「依頼に無い設計や調べもの…」の行は、`high`・`medium` で立てた子には残し (指揮役が effort を上げる)、
  `max` で立てた子では消す (上げる先が無い)
- 立て直した子 (上の「前の作業の子に次を頼むか」で、前の作業の文脈を持たずに起こした子) には、4 行目の「この子は effort …」の
  後ろに「この子は前の作業 (<前の PR か作業の名前>) の会話を続けずに立て直した。前の作業から要ることは背景に書いた」と書き、「背景」に
  前の PR・決まったこと・残っていること・今の状態 (運用の子なら動いているものと設定) を書く。子は前の会話を読めない
- 子の作業に、子のマシンで確かめられない所 (Windows でしか見られないなど) があれば、報告の形に「<マシン> での確かめ:
  <指揮役が流す手順>」の行を足す
- 子に Claude in Chrome を使わせるなら、PR の無いブラウザの作業は pjp-herdr-other-repo の `references/chrome.md` の
  「依頼の雛形」を使う。PR を出す子なら、下の雛形にその雛形の Chrome の行 (背景・段階・しないこと) を足す

```text
<今の会話の repo> の会話から、ユーザーの指示を渡します。
この worktree (<worktree のパス>) の repo (<owner/repo>) で <やること> をし、PR を 1 本出してください (merge はしない。例外は「しないこと」の 1 行目)。
この依頼は、<ハブのマシン> の hc の端末 (この端末の hc の親) にいる指揮役の Claude が送っています。ユーザーは指揮役と話しています。指揮役はこの子を「子 <英字>」と呼びます。
この子は effort <effort> で立てた (<理由>)。

## ユーザーの指示 (原文)
> <原文>

背景: <なぜこの repo を触るのか。今の会話で決まったこと・分かったこと。並行に動いている PR・worktree と触るファイル>

## やること
- <具体的に>

## 進め方
- この repo の CLAUDE.md・README の決まりに従う。merge の後にすること (docs の sync・反映の手順など) が決まっていないかも、この repo の CLAUDE.md・README・skill (.claude/skills/)・docs で確かめる。あれば報告の「merge の後にすること」に、この子が worktree でするもの (merge の後に fetch し、git switch --detach origin/main で合わせてから流す) と、ユーザーが手元の checkout でするもの (pull・setup --update など) に分けて書く。merge の後のものは、指揮役が merge を伝えて頼んでからする
- 方針はユーザーが指示済みなので、承認の往復と spec を挟まずに PR まで進めてよい。細かいことは自分で決め、PR の本文に並べる (この repo の CLAUDE.md が PR の本文に書くものを決めていれば、それに従う。dotfiles なら、自分で決めたことは dotfiles-private の文書の PR の本文に並べる)
- ユーザーに決めてもらうことが出たら、AskUserQuestion は使わず、質問と選択肢 (推奨を先頭に、理由つき) を書いてターンを終える。指揮役がユーザーに聞いて、答えをここへ送る
- 依頼に無い設計や調べものが要ると分かったら、そこで止まり、そう書いてターンを終える。指揮役が effort を上げる
- 裏の subagent や CI を待つためにターンを終えるときは、最初の行に「作業中」と書く
- 終わった・止まった・ユーザーに聞くことが出た・PR を出したときは、最後の発言に書いたうえで、pjp child report "子 <英字>: <要旨>" で指揮役に 1 行で知らせる (pjp が無ければ hc send "$(hc get "$HC_TERMINAL_ID" --json | jq -r .parent)" "子 <英字>: <要旨>"。pjp child report が断ったら hc send で送り直さず、断った文に従う)

## しないこと
- merge (ユーザーの CLAUDE.md かこの repo の CLAUDE.md が、出したらすぐ merge すると決めた PR は除く。その決まりどおり merge し、報告の PR の行に merge したと書く)・main への push・この worktree の外 (main の checkout・ほかの worktree) を触る・新しい worktree を作る・git stash (この repo の CLAUDE.md が決めた文書の置き場の repo (dotfiles の dotfiles-private) に文書を書くための worktree は除く)
- bash -c '…' で包んだコマンド (bypass でも許可の確認が出て、答えが無いと約 2 分で自動的に拒否される。込み入った処理は script ファイルにして bash <file>)
- public な repo の branch・PR・commit に、private な repo の名前・PR の URL・commit の SHA を書く (この repo の CLAUDE.md や README がもう名前を出している private な repo (dotfiles の dotfiles-private) の名前と、その中の文書のパスは書いてよい。PR の URL・SHA は書かない)。PR を出した後に branch を改名する (GitHub で改名すると、その branch を head にする PR は閉じる。branch 名は PR を出す前に決める)
- public な repo の PR のタイトル・commit の message に、ほかの repo の issue・PR・commit への参照 (owner/repo#番号・URL) を書く (backquote で囲んでも参照先の timeline に跡が残り、後から直しても消えない)。PR の本文とコメントでは backquote で囲む
- 別の repo を触る必要に気づいても、自分の判断では子を立てない。報告に書いて止まる (別の repo を触るよう明示的に頼まれたとき (ユーザーがこの会話に直接頼んだときなど) だけ、pjp-hc-child の手順で立ててよい。そのときは報告にも書く)。この repo の CLAUDE.md が決めた文書の置き場の repo に、この作業の文書を書いて PR を出すのは、別の repo を触るのに数えず、止まらずに自分でやる
- ユーザーの Windows の画面 (herdr-app) と、ユーザーの hc の session の状態を変えるコマンドを打つ (hc の振る舞いを試すなら、自分専用の HC_SESSION と一時ディレクトリで立てた hc で)。上の pjp child report (か hc send) による指揮役への知らせだけは打ってよい

## 終わったら
最後に、この形で書いて止まる:
## 報告 子 <英字>
- PR: <URL>
- 自分で決めたこと: <箇条書き>
- merge の後にすること: <誰が何をするか (この子が worktree でする / ユーザーが手元でする)。無ければ「なし」>
- 立てた子: <この会話から立てた子ごとに、英字と端末・worktree のパス・PR の URL・片付けたか。無ければ「なし」>
- effort の手応え: <足りない (考えが足りず詰まった・やり直した) / ちょうど / 多すぎ (低くても同じ PR になったと思う)> と一言 (動いていた値: <echo $CLAUDE_EFFORT の出力>)
- 気になっていること: <あれば>
```

### 旧 herdr の子では

pjp-herdr-other-repo の `herdr agent prompt` で渡すときは、雛形を 4 か所替える。

- 3 行目を「この依頼は、別の herdr pane (workspace <ID>) にいる指揮役の Claude が送っています。ユーザーは指揮役と話しています。
  指揮役はこの子を「子 <英字>」と呼びます。」にする (英字は旧 herdr の workspace の名前の頭の英字)
- 進め方の最後の「… pjp child report …」の行を消す (指揮役は `herdr agent wait` で待ち、画面を読む。足し分の「pjp mark name …」の行を
  足していれば、それも消す)
- しないことの「別の repo を触る必要に気づいても…」の「pjp-hc-child の手順で立ててよい」を「pjp-herdr-other-repo の手順で workspace を切り出してよい。1 行目の「この worktree の外を触る・新しい worktree を作る」の例外で、任せても自分で直してもよく、片付けもその手順で」にする
- しないことの最後の行 (ユーザーの Windows の画面と hc の session) を消す。報告の「立てた子」は「この会話から切り出した workspace ごとに、ID と名前・agent の名前・worktree のパス・PR の URL・片付けたか」にする
