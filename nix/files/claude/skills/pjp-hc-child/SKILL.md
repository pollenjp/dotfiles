---
name: pjp-hc-child
description: >-
  hc の端末の中の会話 (HC_TERMINAL_ID がある。Windows の herdr-app のハブと、その子の Linux の会話) で、今の会話の
  repo (cwd の repo) とは別の repo に手を入れる (ファイルを直す・branch を切る・commit する・PR を出す) ときに、
  その repo を触る前に読む。子を立てる側 (親の会話) が読む skill で、子の会話は別の repo に手を入れたくなったときだけ
  読む。別の repo や同じ repo の作業を子の Claude Code に任せる・並行に回すとき (pjp child new で
  子のマシンに worktree と herdr-app の space を作って立てる。子のマシン (SSH 先か WSL か)・effort・アカウント (claude-work など)・
  渡す pack・Claude in Chrome を使わせるかを選ぶときも)、子の報告 (<hc from=…> の文) が届いた・子が質問や確認の画面で止まったとき、子の effort を上げる・
  立て直すとき (pjp child restart)、前の作業の子に次を頼むとき (立て直すか compact するか)、子を片付けるとき
  (pjp child cleanup)、この会話の space の名前を付ける・済んだ印や答えを待つ印を付け外しする・確かめるとき (pjp mark)、
  herdr-app の space の行の 2 行目の印 (❓・🌱・🌳[N]・🔄・👀・🗑️・↑ 親の名札。mod pjp-spaces) の意味を確かめるとき、
  子の --settings の pack の JSON を作る・pack の割り当てを確かめるとき (pjp pack) に使う。ユーザーが hc や herdr-app を
  名指ししていなくても使う (ユーザーの常設の指示)。HERDR_ENV が 1 で HC_TERMINAL_ID の無い会話 (WSL の旧 herdr) は
  pjp-herdr-other-repo を使う。別の repo を読むだけ (参照のために開く・grep する) なら要らない。
---

# 別の repo は hc と herdr-app で子に任せる

skill の一覧に `pjp-hc-child-private` があれば、この skill の後にそれも読む (Dev Tracker・Notion・解説動画の手)。

**ユーザーの常設の指示 (2026-10-18):** 今の会話の repo とは別の repo をいじるときは、その作業のための worktree と
画面 (旧 herdr の workspace、herdr-app の space) を作り、そこで別のエージェント (claude) を起動して任せる。hc 版では
`pjp child new` が、子のマシンの worktree・herdr-app の space・子の端末をまとめて作る (claude-skills の spec:
`docs/superpowers/specs/2026-11-15-windows-herdr-app-hc-design.md` の §7)。

hc の skill (`hc --skill`) と herdr-app の skill (`herdr-app --skill`) は、herdr-app の画面を「頼まれたときだけ」変える
としている。**この指示がその依頼に当たる。** ほかの決まりは守る: ユーザーの core と herdr-app を止めない・立て直さない、
片付けるのは自分が立てた端末だけ、`hc send --force` で確認を飛ばさない、確認の画面は読んでからユーザーに聞く (例外は
`references/common.md` の「答えてよい範囲」)。

道具は入口の `pjp` で打つ (bash でも PowerShell でも同じ字面)。`pjp child`・`pjp mark`・`pjp pack` は公開の道具で、中身は dotfiles の
`nix/pkgs/pjp-tools/crates/pjp-hc-child/` (Linux は home-manager の package、Windows は dotfiles の runner の手順 pjp-tools が Release の
exe を置く)。`pjp ticket` などの private な道具は、private な claude-skills の shim (`pjp-skills`) のあるホストだけで動く (無いホストでは
「private な claude-skills の道具で、このホストには入っていません」と出して終了コード 127)。

## 使えないとき

- `HC_TERMINAL_ID` が無い (hc の端末の外): この手順は使えない。`HERDR_ENV` が 1 なら pjp-herdr-other-repo。どちらでも
  なければ、別の repo を直す前にユーザーに伝えて進め方を聞く
- `pjp` が無い: dotfiles が入れる (Linux は home-manager が、hc が入るホスト (`dotfiles.herdrCore.enable`) と claude-skills の道具を
  使うホストに入れる。Windows は runner の手順 pjp-tools が `%LOCALAPPDATA%\dotfiles\bin\` に置く)。入っていなければ、dotfiles を
  新しくするようユーザーに頼む (Linux は `~/dotfiles/setup --self-update --update`、Windows は `dotfiles --self-update apply`)。それも
  無理ならユーザーに聞く
- 今の会話が、指揮役から依頼を受けた子の会話 (`pjp mark show` の `pjp.role` が child か、親がいる): 自分の判断では子
  (指揮役から見た孫) を立てない。別の repo の変更が要ると気づいたら、報告に書いて止まる。別の repo を触るよう明示的に
  頼まれたときだけ、この skill で立ててよい (孫の親はこの会話になる)。立てた子は指揮役への報告の「立てた子」に書く

## 任せるか、自分でやるか

- ハブ (Windows) の会話は、いつも任せる。子の repo は子のマシン (Linux) にあり、ハブの会話はそのファイルを直さない
  (`\\wsl.localhost\…` 越しの書き込みは、ハブの hook が止める。claude-skills の spec §7.3)
- Linux の会話が、明示的に頼まれて別の repo を直す: 今の会話で決めたことを写すだけ (数行の設定・説明の直し、参照先の
  追従) なら自分でやってよい。`git -C <別の repo の checkout> fetch origin` の後に
  `git -C <checkout> worktree add -b <prefix>/<名前> ~/.herdr/worktrees/<repo>/<名前> origin/<既定の branch>` で切り、
  `git -C <worktree> branch --unset-upstream` で追跡先を外す。worktree のファイルを絶対パスで直して PR にする。決まり (push・
  報告) は pjp-herdr-other-repo の「2b. 自分でやる」と同じ (skill の一覧に無ければ、ユーザーの CLAUDE.md の決まりどおり)。迷ったら任せる

## 流れ

### 1. 会話の始めに、名前と印を付ける (ハブ)

```text
pjp mark name '<主題>'
```

この会話の space の名前を替え、この端末に label `pjp.role=hub` (ハブの中のとき) を付ける。チケットのある会話では、名前の頭に
チケットの ID を付け (`pjp mark name 'TKT-n <主題>'`)、label `pjp.ticket=TKT-n` も付く。herdr-app の無いマシン (SSH 先や WSL の
Linux のハブ) では、このマシンの hc の doc `herdr-app` (herdr-app が space を置く) の name を書き替え、Windows の herdr-app が付いて
くる (doc か space が無い・hc が答えないときは note を出して替えない。`pjp mark --help`)。子の英字を振る単位 (親のチケット。`pjp child`
の控えの名前) は、`pjp.ticket` があればそれ、無ければこの端末の住所 (`t-<住所>`)。会話を立て直した (再起動の後など) ときも、同じ名前で
打ち直す (チケットのある会話は、同じチケットで打たないと前の子の控えを引けない。チケットの無い会話は、前の端末の控えを
`--ticket t-<前の住所>` で指す。`references/delegate.md` の「子を英字で呼ぶ」)。名前は 42 桁に収める (下の「名前の桁」。チケットの
ID を頭に付けるなら、その分を引く)。ハブの会話の始めの手順は pjp-hc-hub。

### 2. 子を立てる

依頼を Write で scratchpad のファイルに書き (雛形は `references/common.md` の「依頼の雛形」)、1 つのコマンドで立てる。

```text
pjp child new --repo <owner/repo> --label '<repo>: <一言>' --agent <名前> --brief <依頼のファイル> [--on <machine>]
              [--effort low|medium|high|xhigh|max (既定 high)] [--pack <pack>]… [--synced <名前>]… [--chrome] [--account <名前>|default]
```

- **子のマシン:** `--on` を省くと (hub.toml の `default_machine` も無ければ) 自動で選ぶ: `hc machine ls` の SSH 先の
  Linux を測り、空きコア (コア数 - 1 分の負荷) の多い所 (空きコア 1・空きメモリ 4 GiB 以上で、ハブと同じアカウントの用意がある所)
  を選び、使える SSH 先が無ければ手元の WSL。選んだマシンと測った値・外したわけは出力の頭に出て、選んだマシンと値は
  `note 用:` の行にも出る (`--dry-run` でも測って選ぶ)。重い作業や、どのマシンでもできる repo の作業は `--on` を省く (ユーザーの望み
  2026-11-21: 手元や親の会話の subagent より SSH 先がよい)
- **WSL でしか動かない作業は、ハブが `--on wsl` を付ける:** Claude in Chrome を使う子 (`--chrome` の子は省いても WSL から選ぶが、
  手順では名指しする)・WSL の中を直す作業 (WSL の設定やファイル)・Windows の WSL に依る作業 (`/mnt/c` や Windows の道具を使うなど)。
  `wsl` は `local`・`auto` と同じ語で、`hc machine ls` の手元の WSL の machine (`--via` のコマンドが wsl.exe のもの) を名前によらず
  選ぶ (名前は PC ごとに違う。無い・1 つに決まらないときの止まり方と、WSL の machine の足し方は `references/delegate.md` の
  「起動する」の 1.)。順番・外す machine・下限は hub.toml の `[auto]` で変えられる (同じ 1.)
- 子のマシンで checkout を探し (無ければ `ghq get`)、`git fetch` して既定の branch から `worktree/<名前>` を切り、
  `~/.herdr/worktrees/<repo>/<名前>` に worktree を作る。herdr-app の space `<英字> <repo>: <一言>` を作り、
  `hc run --outlive-parent` で claude を立てる (この会話の子になり、この会話を閉じても止まらない)。依頼は起動の引数で渡す
- herdr-app の無いマシン (Linux のハブ) では、新しい id の label `herdr.space`・`herdr.tab` で立てて Windows の herdr-app に space を
  作らせ、子のマシンの hc の doc `herdr-app` で名前を付ける (作られなければ、名前つきの space を doc に足す)。`restart`・`cleanup` も
  doc で space の名前を保つ・片付ける。細部は `references/delegate.md` の「起動する」の 4.・「effort を上げる」・「片付け」
- GitHub へ出る fetch・`ghq get` は gh の資格情報で打つ (`git gh`、無ければ同じ組を `git -c`・env で付ける)。それでも落ちたときの
  回避 (worktree を手で切って `--dir`) と片付け方 (`cleanup --repo … --branch …`) は `references/delegate.md` の「起動する」の 3
- 出力の英字で子を呼ぶ (「子 A」)。英字は親のチケット (この会話の控え) ごとに A・B… と振り、片付けた子の英字も使い回さない
- **名前の桁:** space の名前は 42 桁に収める (半角 1 桁、全角と絵文字 2 桁)。herdr-app の mod pjp-spaces が、ユーザーの今の
  sidebar の幅 (406px) で、2 行の行の 1 行目に名前を出しきれる桁 (本体の下に字下げした worktree の行で測った。2026-11-18)。
  子の `--label` に使えるのは、そこから頭の `A ` (2 桁。AA 以降は 3 桁) を引いた 40 桁で、一言はさらに `<repo>: ` を引いた残り
  (`claude-skills: ` なら 25 桁・全角 12 字、`dotfiles: ` なら 30 桁・全角 15 字)。測った値と sidebar の幅ごとの桁は pjp-hc-hub の
  `references/spaces.md` の「名前の幅」
- 出力の `note 用:` の行 (`子 A = <repo> (<子の端末>・<worktree>・effort …)`) は、子を記録するときにそのまま貼れる 1 行
- effort (既定 high。深い思考が要る・ミスが致命的な作業は max をそこそこの頻度で選び、言い切れる作業は medium。`--effort` は 5 つを
  受けるが、指揮役が選ぶのは high・max・medium)・pack・`--chrome` の選び方は `references/common.md`。起動の細部・立った直後の画面・罠は
  **`references/delegate.md`** (子を立てるときに読む)。Claude in Chrome を使わせる子は **`references/chrome.md`** も読む
- 作業場所が repo の worktree でない子: `--checkout '<子のマシンの repo>'` (origin の無い `~/h` などから worktree を切る)・
  `--dir '<子のマシンのディレクトリ>'` (worktree を作らない)。PowerShell では `~` を引用符で囲む。どちらもパスはあるマシンの
  ものなので、既にあるパス (`~/h`・checkout・前からある作業ディレクトリ) は `--on <machine>` で名指しする (自動は、同じパスの
  ほかのマシンを選びうる。`--checkout` は `--on` を省くと止まる)。新しく作るディレクトリは省いてよい
- 打つ前に中身を見るなら `--dry-run` (書き換えるものを打たずに、打つ形を出す)
- 子はハブと同じ Claude のアカウントで立つ: ハブの `CLAUDE_CONFIG_DIR` が `~/.claude-<名前>` なら子のマシンの `claude-<名前>`、
  空・`~/.claude` なら素の claude (`--account <名前>|default` で替える。`restart` は立てたときのアカウント)。子のマシンに
  `claude-<名前>` が無い・アカウントの用意 (子のマシンの `claude-account check <名前>`。claude-account の無いマシンは /login の
  資格情報か token のファイル) が無ければ、何も作らずに止まる。素の claude の子も、子のマシンに claude-account があれば
  `claude-account check default` で確かめ、用意が無ければ止まる (default を知らない古い claude-account と、claude-account の無いマシンは確かめずに立てる)。
  ほかのアカウントのハブは、herdr-app で worktree を切った後に端末で `claude-work` などを手で打って起こす (ユーザーの決まり)。
  決め方・止まったときの手は `references/delegate.md` の「アカウント」

**ユーザーの指示 (2026-11-17):** 前の作業で使った子の会話をそのまま使い回して、文脈 (token) を引き継がない。前に作業をした
子に次を頼む前 (再起動の後に `restart` で続きから立てた子も) に、毎回、子の会話に前の別の作業の文脈が残っていないかと、
子の画面の status line の「NN% left」を見て決める: 別の作業なら立て直す (`pjp child new`、同じ worktree なら
`pjp child restart <英字> --fresh --brief <依頼>`)、同じ流れの次の作業なら親が残すものを決めて compact してから続ける、同じ
作業の続きならそのまま (残りが少なければ compact を挟む)。決め方と目安は `references/common.md` の「前の作業の子に次を頼むか」、
打ち方 (compact は `hc keys` と `pjp child send` の 2 手) は `references/delegate.md` の「前の作業の子に次を頼むとき」。

### 3. 報告を受ける・答える

- 子の報告は、この会話の入力に `<hc from="<machine>/t13">子 A: …</hc>` の形で届き、次のターンになる。子が止まった・
  終わったとき (子が報告できないとき) は hc が知らせる
- 届いたら `pjp child read <英字> --lines 120` で画面を読み、最後の見出し「## 報告 …」で終わったかを見分ける
- 質問への答えは、ファイルに書いて `pjp child send <英字> --file <答え>`
- `pjp child send` は送る前に、子の端末で Claude が動いているか (`hc get` の状態の報告と前面のプロセス) を確かめ、Claude が
  終わって hc が shell に替えた端末 (英字・住所・名前は残る) と、確かめられない端末には送らずに終了コード 1 で止まる (shell が
  文を 1 行ずつコマンドとして打つのを防ぐ)。出た文に従い、ふつうは `pjp child restart <英字>` で立て直してから送る。
  わざと shell に送るときだけ `--no-agent-check`。`pjp child ls` はそういう子を「Claude が動いていない (前面 bash)」と出す。
  細部は `references/delegate.md` の「依頼を送る (起動の後)」
- 確認の画面で止まった子は `pjp child read <英字> --lines 0` で画面を読み (`--lines` は画面の上の履歴の行数。0 は画面だけ)、
  答えてよい範囲なら `hc keys <子の端末> <キー>…`、外ならユーザーに聞く
- `hc send` の文は `<hc from=…>` の札で包まれて届くので、`/effort`・`/exit` のような command は効かない。effort を上げる
  のは `pjp child restart <英字> --effort <max か high> --brief <続きの依頼>` (同じ worktree で `claude --continue`)。
  `/compact` は `hc keys` で `/compact ` まで打ってから `pjp child send` (`references/delegate.md` の「前の作業の子に次を頼むとき」)
- `restart` は前の端末を終える前に、その端末が立てた端末 (孫) を探す。`!! 前の端末 … が立てた端末が N つ生きている` が出たら、
  その端末の親は消えた端末のまま残り、herdr-app の Agents 欄の木で立て直した子の下に出ない (hc には親を付け替える手が無い)。
  立て直した子への依頼に、残った端末を使わせるなら子の端末から `hc run --outlive-parent` で立て直させる (木で子の下に出る)・
  要らなければ子に閉じさせる、と書く。前の端末と一緒に終わる孫 (`--outlive-parent` なしで立てた端末) がいれば止まる
  (`--force` で進む)。細部は `references/delegate.md` の「effort を上げる」
- `restart` は、前の端末の見ていない解説動画の印 (`🎬✅`) を新しい端末へ引き継ぐ。作りかけの印 (`🎬⏳`) があり、前の端末の
  Claude が動いていれば止まる (前の端末を終えると作るのが止まる。`--force` なら引き継がずに立て直す)

### 4. 片付ける

PR が merge され、子の報告の「merge の後にすること」を済ませたら `pjp child cleanup <英字>`。PR が merge 済み・worktree に
変更が無い・孫がいない・子が働いていないのを確かめてから、`hc kill` → `hc rm` → space を閉じる → worktree と branch を
消す。子の見ていない解説動画の印 (`🎬✅`) は、子を終える前にこの会話の端末へ移す (ユーザーが見るまで、この会話の行に出る)。
子が解説動画を作っている (作りかけの印 `🎬⏳` があり、子の Claude が動いている) 間は片付けない (`--force` なら捨てる)。
どれかが外れたら何もせずに理由を出す。PR の無い子は、子の作業が済んだのを確かめてから (チケットのある子は Done になってから)
`--no-pr` を付ける。PR はハブの gh で引く (worktree の今の branch。detached なら reflog の直前の branch。分からなければ
`--branch <作業の branch>`)。細部は `references/delegate.md` の「片付け」。

herdr-app の無いマシンでは space.close を打てないので、子の端末を消すと herdr-app が space を消すのを doc で待ち、残っていれば
doc から消す。子の space に子のほかの端末 (ユーザーが開いた shell など) がいれば、確かめの段で止まる (`--force` なら、その端末と
space を残して進む)。

## 印 (label) と表示

| label | 付く端末 | 値 | 付けるもの |
| --- | --- | --- | --- |
| `pjp.role` | ハブの会話・子 | `hub`・`child` | `pjp mark name`・`pjp child new` |
| `pjp.ticket` | チケットのある会話の端末 | チケットの ID | `pjp mark name` (名前の頭がチケットの ID のとき) |
| `pjp.letter` | 子 | `A` | `pjp child new` |
| `pjp.finished` | 会話の端末 | 済んだ日時 | `pjp mark finished` (Dev Tracker のあるホストでは、チケットを閉じたときにも付く) |
| `pjp.asking` | ユーザーに問いを出しているハブの会話 | 問いの要旨 (1 行) | `pjp mark asking` (外すのは、答えが届いたときのハブの雛形の hook と `pjp mark answered`) |
| `pjp.asked` | 答えが届いたハブの会話 | 外したときの問いの要旨 | ハブの雛形の hook `pjp mark hook prompt` (外すのは `pjp mark answered`・`asking` と、ターンの終わりの `pjp mark hook stop`) |
| `pjp.video.<作り始めた日時>` | 解説動画を作る会話 (subagent が打つと会話の端末)。動画 1 本に 1 つ | JSON (名前・状態 `making`/`done`・作り始めた日時・済んだ日時) | `pjp mark video start`・`done` (外すのは `stop` と `watched`。`pjp child cleanup` は親へ移し、`restart` は引き継ぐ) |

- 名前は space の名前 (ハブは `<主題>` (チケットがあれば `TKT-n <主題>`)、子は `<英字> <repo>: <一言>`)。旧 herdr の sidebar の
  2 行目と同じ印は、herdr-app の mod pjp-spaces (dotfiles の `win/herdr-app/mods/pjp-spaces/`。Windows の runner の手順
  herdr-app-pjp-spaces が配り、layout の sidebar の spaces と差し替える) が、会話 (`pjp.role` が hub か child の端末と、子のいる端末) の
  いる space の行の 2 行目に、頭に会話の端末の hc の address (`<hc from="…">` と同じ形。このマシンは `t53`、ほかのマシンは
  `<machine>/t10d`。印の有無を問わず出す)、その後ろに label と hc の親子から印を出す: `❓` ユーザーの答え・対応を待っている
  (status が blocked (確認の画面) か error か、`pjp.asking` がある。印の先頭に出し、親へは伝えない)・`🌱` 親がいる・`🌳[N]` 子が
  N 人・`🔄` 子か孫が working・`👀` 裏の作業 (subagent か、`hc run --bg` で立てた手伝いの端末) が動いている (会話の状態を問わない。
  子孫の分も)・`🗑️` 済んだ (`pjp.finished` があり、子が 0 人で止まっていて、`❓` でなく、作っている解説動画も無い)・`↑ <親の名札>`
  親の `pjp.ticket` (チケットが無ければ親の space の名前)。裏の Bash・Monitor は `👀` にならない (Claude Code が records に載せない)。
  解説動画は 2 行目でなく 3 行目から 1 本 1 行で出す: `🎬⏳:<名前>` 作っている・`🎬✅:<名前>` 作り終えて載せた動画をユーザーが
  まだ見ていない (`pjp.video.<id>`。子孫の分も並ぶ。名前は印の名前)。細部・取り付け・確かめ方は pjp-hc-hub の `references/spaces.md`
- pjp-spaces の入っていない herdr-app (同梱の spaces のまま) では、親子・子の数・動いている子を Agents 欄 (hc の親子の木) で見る
- `pjp mark finished` は worktree の会話にだけ付く (repo の checkout の会話は、ほかの会話も使うので付けない)。打ち直しても
  日時は替わらない。外すのは `pjp mark unfinished`。印を確かめるのは `pjp mark show [<端末>]`
- `pjp mark asking '<問いの要旨>'` は、ユーザーに直に問いを出す会話 (ハブ) が、文で問いを出してターンを終える直前に打つ
  (打ち直すと要旨が替わる)。答えが届くと、ハブの雛形の hook (`pjp mark hook prompt`) が外して要旨を `pjp.asked` に移す。
  Claude は問いが済んだら `pjp mark answered`、まだ答えを待つなら `pjp mark asking` を打ち (どちらも `pjp.asked` を外す)、
  打たずにターンを終えると Stop の hook (`pjp mark hook stop`) が 1 回確かめさせる (いつ打つかは pjp-hc-hub の SKILL.md の 1.)。
  子は親 (指揮役) に聞くので打たない。確認の画面・エラーの `❓` は status から出るので打たない
- `pjp mark video start|done|stop|watched` は解説動画の印 (`pjp.video.<id>`) を付け外しする (打つのは動画を作る側の skill。打ち方は
  `pjp mark video --help`)。hc の端末の外では、どれも何もせずに終わる。`pjp mark show` が、その端末と子孫の動画を並べる。解説動画を
  作る・見る流れは、解説動画を使うホストの足し分の skill (`pjp-hc-child-private`。skill の一覧にあれば) の手

## pack

子の `--settings` の JSON は `pjp child new --pack <pack>` が作る (中身は `pjp pack settings <pack>…` と同じ)。pack と
skill の今の組は `pjp pack list`、割り当てと入口の目録の食い違いは `pjp pack check` (どちらも `~/.claude/skills` を見る)。
`pjp pack` は旧 herdr の `pack.sh` (`pjp-herdr-other-repo` の `pack.py`) の移植で、出力は同じ。

## 道具を直したら

dotfiles の `nix/pkgs/pjp-tools` で `nix develop ../..#pjp-tools --command cargo test --workspace` (Windows は CI の workflow
pjp-tools。`pjp child` の試験は hc・herdr-app・gh を偽物にして打つ形を見る)。`pjp pack` は pjp-herdr-other-repo の pack.py
(claude-skills) の移植なので、pack.py を直したら `pjp pack` (`crates/pjp-hc-child/src/pack/`) にも同じ直しを入れる (pack.py との
突き合わせの試験は claude-skills の側にあり、dotfiles には写していない)。

本物の hc で試すときは、ユーザーの core と herdr-app に触らない。`HC_TERMINAL_ID`・`HC_SCOPE`・`HC_TERMINAL_SOCKET` を外し、
自分専用の `HC_SESSION` と一時の `HOME`・`XDG_*` (`XDG_RUNTIME_DIR` は socket のために短いパス) で `hc server start` した
core に、偽の claude (引数を控えて sleep する script) を PATH の先頭に置いて試す。終わったら `hc server stop`。
