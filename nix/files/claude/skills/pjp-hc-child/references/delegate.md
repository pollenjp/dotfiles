# 子の Claude に任せる (hc 版)

SKILL.md の「2. 子を立てる」〜「4. 片付ける」の細部。CLI の正は `pjp child --help`・`hc <command> --help`・`hc --skill`。
effort・子の使い回し・pack・答えてよい範囲・依頼の雛形は `references/common.md`。

## 子を英字で呼ぶ

- 英字は `pjp child new` の出力 (`子 A を立てた: …`) から取る。自分で振らない
- 英字は親のチケット (子の控えの名前) ごとに A・B・…・Z・AA… と振る。親のチケットは、この端末の label `pjp.ticket` (チケットの
  ある会話で `pjp mark name 'TKT-n …'` が付ける)、無ければこの端末の住所 (`t-t8` の形)。ほかの会話の子を扱うときは
  `--ticket <親のチケット>` を付ける (チケットの無い会話なら `--ticket t-<その会話の端末の住所>`)
- ハブの会話を立て直した (Windows の再起動の後など) 新しい端末には `pjp.ticket` が無い。チケットのある会話は、同じチケットで
  `pjp mark name` を打ち直してから `pjp child …` を打つ (打たないと `t-<新しい端末>` の空の控えを見る)。チケットの無い会話は、
  前の端末の控えを `--ticket t-<前の端末の住所>` で指す (住所は控えのファイルの名前で分かる。下の行の置き場所)
- 片付けた子の英字は欠番のまま (会話の前の方の「子 A」が、後から別の子を指さない)。立てられなかった子の英字も欠番
- 控えはハブのマシンの `<XDG_STATE_HOME>/pjp/children/<親のチケット>.tsv` (Windows も `~/.local/state/pjp/children/`)。
  英字・状態・子の端末・名前・マシン・repo・worktree・branch・space・アカウントの 1 行 1 子。`pjp child ls` で見る
- 子を立てる前 (方針の案・承認を取る文) は repo の名前で呼ぶ。英字は立てた後から使う

## 起動する

`pjp child new` は次の順に打つ (spec §7.4)。

1. 子のマシンを決める: `--on <machine>` (`hc machine ls` の名前。`local` はこのマシン、`wsl` は手元の WSL、`auto` は自動)、無ければ
   `~/.config/pjp/hub.toml` の `default_machine` (同じ値)、それも無ければ自動で選ぶ。WSL でしか動かない作業 (Claude in
   Chrome を使う子・WSL の中を直す作業・Windows の WSL に依る作業) は `--on wsl` を付ける
   - `--on wsl` (`default_machine = "wsl"` も) は、`hc machine ls` の手元の WSL の machine (`--via` のコマンドが wsl.exe のもの) を
     名前によらず選ぶ (WSL の machine の名前は PC ごとに違う。一時の machine (temporary) は選ばない)。1 つならそれ、2 つ
     以上なら名前が `wsl` のものを選び、無ければ候補を並べて止まる。選んだ machine が connected でなければ止まる。自動と違って
     空きは測らない。選んだ machine は出力の頭の `子のマシン: <名前> (手元の WSL。--on wsl)` と `マシン:` の行に出て、控えには
     その名前が入る (`restart`・`cleanup` はその machine を使う)。名指しと同じく 1 台に決まるので、`--checkout` にも使える
   - WSL の machine が無ければ、足し方を出して止まる (Windows のハブで足す。名前は自由。ディストリビューションの名前は
     `wsl.exe -l -v` で見る。`pjp hub hello` も、Windows のハブに WSL の machine が無ければ同じ形を !! で出す)。WSL の中の Linux の
     ハブ (このマシンが WSL) なら、足さずに `--on local` でこのマシンに立てる:

     ```text
     hc machine add --via 'wsl.exe -d <ディストリビューション> --cd ~ -e bash -lc' --name <名前>
     ```

     machine を足す・外す・作り直すときは、hc の machine のほかに直すもの (ssh の接続先・定期の一覧・ホストの宣言など) を
     `pjp-machine-add-remove` (skill の一覧にあれば) の表でなぞる

   - `local`・`wsl`・`auto` は、machine の名前より先に語として読む (hub.toml の `default_machine` も)。名前が `wsl` の SSH 先は
     `--on wsl` では選ばず、そのわけと名前の替え方 (`hc machine rename wsl <新しい名前>`。替えると、その machine の端末の住所も
     替わる) を出す。名前が `wsl` の手元の WSL の machine は、語と同じ machine を指すのでそのまま使える (一時の machine は除く。
     `--on wsl` は一時の machine を選ばず、語と同じ名前なので名指しもできないので、名前を替える)
   - 既にあるパスを渡す子 (`--checkout '~/h'`・checkout や前からある作業ディレクトリの `--dir`) も `--on <machine>` で名指しする。
     自動はパスを見ずに選ぶので、同じパスのほかのマシンの repo・ディレクトリを使いうる (SSH 先にも手元の WSL にも `~/h` がある)。
     `--checkout` は `--on` を省くと (`default_machine` が `auto` でも) 設定の誤りで止まる (自動でよければ `--on auto`)。新しく作る
     ディレクトリの `--dir` (新しい作業場所) は省いてよい
   - 自動: `hc machine ls` の machine を、`--via` の machine (`via` が true) で、そのコマンド (target) の最初の語 (引用符で囲んで
     いれば囲みの中) のパスの名前が `wsl.exe` か `wsl` なら手元の WSL、ほかを SSH 先とみる (`~/.ssh/config` の Host が `wsl` の SSH 先も
     SSH 先。temporary の machine はほかの作業の sandbox なので選ばない)。SSH 先 → WSL の順に、connected の machine を
     `hc exec` 1 回で測る (`uname -s`・`nproc`・`/proc/loadavg`・`/proc/meminfo` の MemAvailable)。Linux の machine を空きコア (コア数 -
     1 分の負荷。0.1 の桁で比べる) の多い順 (同じなら空きメモリの多い順) に並べ、2. の探りとアカウントの確かめが通った最初の machine を
     選ぶ (選ばない machine までは確かめない。`--repo` の子は、repo の checkout か ghq も要る)。SSH 先は空きコア 1・空きメモリ 4 GiB 以上の所だけを使い、使える SSH 先が無ければ WSL に
     落ちる (WSL は落ち先なので下限を効かせない)。WSL も使えなければ、machine ごとのわけ (アカウントで外した machine は用意の手も) を
     並べて、何も作らずに止まる。`--chrome` の子は WSL だけから選ぶ (Claude in Chrome は WSL の子で確かめた。`references/chrome.md`)
   - 1 分の負荷を使うのは、いま始まった・いま終わった仕事をすぐ映すため (5 分の負荷は、終わった仕事を数分のあいだ数え続ける。
     2026-11-21 16:25 の host-a は 1 分 1.30・5 分 5.66 で、仕事は終わっていた)
   - 出力の頭に「子のマシンを自動で選んだ: <machine> (<種類>・空きコア <空き> = <コア数> コア - 1 分の負荷 <負荷>・空きメモリ <GiB> GiB)」・
     自動にしたわけ・ほかの machine の行 (`外した`・`次点`・`見ていない` とわけ) が出る。`外した` のわけは止まったわけの最初の文だけで、
     用意の手まで見るなら `--on <その machine> --dry-run` で打つ (止まるときは手まで出る)。hub.toml の exclude に `hc machine ls` に無い
     名前があれば、その行も出る (綴りの誤りかもしれない)。`マシン:` の行に「(自動で選んだ)」、`note 用:` の
     行の末尾に「マシンは自動で <machine> (…)」が付く。`--dry-run` でも測って選ぶ (測る・探るのは読むだけ)
   - hub.toml で変えられる (無い鍵は既定。知らない鍵・形の違う値は、測る前に止まる):

     ```toml
     default_machine = "auto"   # 省いても自動。machine の名前・local・wsl なら、それに決める
     [auto]
     order = ["ssh", "wsl"]     # 見る順。ssh・wsl・local (このマシン。Linux のハブで手元を落ち先にするとき)
                                #   下限は SSH 先だけに効くので、WSL を先にすると WSL を負荷によらず毎回選ぶ
     exclude = ["host-a"]       # 選ばない machine の名前 (語は読まない。WSL を見ないなら order から wsl を外す)
     min_free_cores = 1         # SSH 先の空きコアの下限
     min_free_mem_gib = 4       # SSH 先の空きメモリの下限 (GiB)
     ```

   - `restart`・`cleanup` は控えのマシン (立てたときのマシン) を使い、選び直さない
2. 子のマシンを `hc exec` で 1 回だけ探り、HOME・claude の場所・ghq・claude-account の場所・repo の checkout を読む。claude が PATH に無ければ
   `~/.local/share/mise/installs/claude/latest/claude` を使う (再起動の後に core を素の login の env で立てたマシンでは、
   mise の shim が PATH に無い)。名前のアカウントで立てるなら、続けて launcher `claude-<名前>` の場所とアカウントの用意
   (子のマシンに `claude-account` があれば `claude-account check <名前>`) を確かめ、だめならここで止まる。素の claude で立てるなら、
   子のマシンに claude-account があれば `claude-account check default` を確かめる (下の「アカウント」)
3. worktree を作る: checkout (無ければ `ghq get`) で `git fetch origin` し、`origin/HEAD` から `worktree/<名前>` を切って
   `~/.herdr/worktrees/<repo>/<名前>` に置く。追跡先は外す (`branch --unset-upstream`。push や `gh pr create` が main を相手に
   取り違えないように)。名前・worktree・branch・端末の名前のどれかが重なれば、`-2`・`-3` を付ける
   - GitHub へ出る fetch と `ghq get` は gh の資格情報 (HTTPS) で打つ (ユーザーの決まり 2026-11-16)。`hc exec` の
     env には Claude の会話の `GIT_CONFIG_*` (gh の credential helper・SSH の URL の https への読み替え) が無く、素の git は
     private な https の repo で `could not read Username` で落ち、SSH の remote では 1Password の承認画面を出す。子のマシンに
     `git gh` (dotfiles の git-gh) があれば `git -C <checkout> gh fetch origin`、無ければ (Windows の `--on local` も) 同じ組を
     `git -c` で付ける (github.com の helper を空にする 1 組を先に足す)。`ghq get` は中で git を呼ぶので、同じ組を
     `GIT_CONFIG_COUNT`・`GIT_CONFIG_KEY_<n>`・`GIT_CONFIG_VALUE_<n>` の env (`hc exec --env`) で渡す
   - それでも落ちたら、どのマシンのどの操作かと回避を出して、何も作らずに止まる。子のマシンで `gh auth status` を確かめる。
     急ぐなら、子のマシンで worktree を手で切って `--dir` で立てる (片付けは `cleanup --repo <owner/repo> --branch <作業の branch>`)
4. herdr-app の space を作る (`herdr-app do space.new`。名前 `<英字> <label>`、子のマシンの worktree を開く)。返った space と
   tab の id から `<machine>/` を外して label にする。herdr-app が答えないときは作らずに進め、子は Agents 欄にだけ出る
   - herdr-app の無いマシン (SSH 先や WSL の Linux のハブ) では `space.new` を打てないので、herdr-app と同じ形の新しい id
     (`sp`・`tb` + uuid の 32 字の hex) を作って label にする。herdr-app (Windows) は知らない id の label を見ると、その id の
     space を作る (name は空。1 秒ほど)。`pjp child new` は子の状態の報告を待った (最長 30 秒) 後に、子のマシンの hc の doc
     `herdr-app` (`hc connect` の `doc.get`。別のマシンは `on` で指す) を 0.5 秒おきに最長 10 秒読み、子の端末がその space に
     入ったら、その space の name だけを `<英字> <label>` にする (`pjp mark name` と同じ書き方。版が合わなければ読み直す)
   - それでも space ができなければ (herdr-app が開いていない・遅い)、herdr-app が新しい space を書く形と同じ形 (1 つの tab に
     子の端末のペインだけ) の名前つきの space を doc の末尾に足す。herdr-app を開くと、その名前で子の space に出る (この場面は
     本物の herdr-app で確かめていない)。doc がまだ無い (版 0。herdr-app がそのマシンの space を置いたことが無い)・読めないときは
     書かずに `!!` を出す。label は付いているので、herdr-app を開くと label から space を作る (名前はフォルダ名)
   - 出力の `space:` の行の後ろと、状態の行の後ろの `space の名前:` の行に、どうなったか (付けた・足した・付けられない) が出る
   - ユーザーの画面は版で変わる。herdr-app 0.1.16 からは `herdr-app commands` の space.new に引数 `focus` が載るので
     `"focus": false` を渡し、表示中の space・tab と打ち込み先のペインはそのまま (子の space は一覧に増えるだけ)。
     0.1.15 までは focus を知らず (渡すと space.new が落ちる)、渡さないので、画面と打ち込み先が子の space へ移る。
     その間にユーザーが打っていたキーは子の space の端末に入りうる。渡せないときは `note: herdr-app の版が space.new の focus を
     知らない …` の 1 行が出る。`herdr-app commands` が落ちた・読めないときも渡さず、わけを添えた note を出して space は作る
5. 子の claude を立てる:

   ```text
   hc run --bg --json --on <m> --cwd <worktree> --name <名前> --outlive-parent \
     --label herdr.space=<id> --label herdr.tab=<id> --label pjp.role=child --label pjp.letter=<英字> -- \
     env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u HERDR_SOCKET_PATH -u HERDR_BIN_PATH \
       -u CLAUDE_CONFIG_DIR -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_AUTH_TOKEN \
     <claude か claude-<名前>> <claude-args.toml の args> --effort <effort> --no-chrome [--settings <pack の JSON>] <依頼>
   ```

   - `--parent` は渡さない。hc は env の `HC_TERMINAL_ID` の端末 (この会話) を親にする。`--parent` は `--on` のマシンの中で
     読まれるので、Windows のハブから `--on <machine> --parent t8` と渡すと、そのマシンの別の端末 t8 が親になる (指揮役が Windows で見た)。
     立てた後に `hc get` の `parent` がこの会話の端末かを確かめ、違えば `!!` を出して終了コード 1 で終わる
   - `claude-args.toml` (dotfiles の `nix/pkgs/pjp-tools/crates/pjp-hc-child/assets/claude-args.toml`。道具に埋め込む) は、ユーザーの
     `c` から `--remote-control` と `--effort` を除いたもの。`c` が変わったら合わせる (Linux は dotfiles の `nix/home/modules/fish.nix` の
     abbr、Windows は dotfiles.ps1)
   - **ユーザーの指示 (2026-10-20):** 子は Remote Control を off で立てる (`--remote-control` を付けない)
   - **ユーザーの決まり (2026-11-15):** 子は基本 `--no-chrome` で立て、Claude in Chrome を使わせる作業の子だけ `--chrome`
     (`pjp child new --chrome`)。新しい claude は起動直後に「Claude in Chrome extension detected」の選択画面で止まることがあり
     (Windows で見た)、選ぶとユーザーの設定になりうる
   - `env -u HERDR_*` は、手元の WSL の core に漏れていた旧 herdr の env を子に渡さないため (子の道具と hook が旧 herdr を呼ばない)
   - `-u CLAUDE_CONFIG_DIR` と token の env (`ANTHROPIC_API_KEY`・`CLAUDE_CODE_OAUTH_TOKEN`・`ANTHROPIC_AUTH_TOKEN`) も外す。hc の子は
     core の env で起き、core の env は core を立てたシェルの写しなので、claude-work の会話から core を立て直すと紛れ込む。外して
     おけば、既定の子はいつも `~/.claude` の /login で起きる (名前のアカウントの子は launcher が付け直す。下の「アカウント」)
   - 依頼は起動の引数で渡す (hc の勧め。起動したばかりの agent に send すると落ちうる)。shell を通らないので、改行・引用符・
     backquote はそのまま届く。Windows のコマンドライン (約 32,767 字) に収まるよう、hc に渡す引数の合計が 30,000 字 (UTF-16)
     を超えたら、何も作らずに断る。そのときはまず依頼を短くする (長い資料は子の worktree から読める所を指す)。どうしても
     分けるなら、前半の最後に「続きを送るまで待つ」と書いて立て、子が状態を報告した (`pjp child ls` が working でなく idle) のを
     見てから、後半を `pjp child send --file` で送る (`send` も 30,000 字まで)
6. 立った子を確かめる (次の「起動直後の画面」)
7. 出力: 英字・子の端末 (`<machine>/t13` の形)・アカウントとそのわけ・worktree と branch・space・effort・pack・状態と、記録に
   そのまま貼れる子の 1 行 (`note 用:` の行)

- `--agent` は 1〜32 字の a-z・0-9・`-`・`_` (hc の端末の名前。worktree と branch の名前にもなる)。何の子か分かる名前にする
  (`dotfiles-ssh` など)。切る元を既定の branch から替えるなら `--base <branch>` (open の PR の branch に積むなど)
- `--dry-run` は、書き換えるもの (ghq get・fetch・worktree・space・hc run・控え) を打たずに、打つ形を出す。依頼に書く worktree の
  パス (名前が重なると `-2` が付く) と英字は、先に `--dry-run` で見る。space.new の行には、focus を渡すか (`focus: false。画面は
  移さない` か `focus を渡さない (…)。画面は子の space に移る`) も出る (読むだけの `herdr-app commands` は打つ)。herdr-app の
  無いマシンでは、space.new の行の代わりに、label で作らせて doc で名前を付けると出る (doc は読まない)
- `hc run` が落ちたら、名前で子の端末を探し (2 秒おきに 3 回。host-a の hc は「registry persistence timed out; the operation may
  already have completed」を返すことがあり、そのときも端末は立っていた)、見つかれば進める。見つからなければ、作った space・
  worktree・branch を戻し、英字は欠番にする (控えに failed)。label で作らせる space は、子が立たなければ herdr-app も作らない
- 子はハブと同じ Claude のアカウントで立つ (下の「アカウント」)
- Remote Control は `--remote-control` を付けたときだけ有効になる。`/config` の「Enable Remote Control for all sessions」
  (設定 `remoteControlAtStartup`) が true なら付けなくても有効になるので、そうと分かったら子をどう立てるかをユーザーに聞く

### アカウント

子は、ハブ (`pjp child new` を打った会話) と同じ Claude のアカウントで立てる。

**ユーザーの使い方の決まり (2026-11-19):** `~/.claude` が既定のアカウント。ほかのアカウントのハブは、herdr-app で worktree を
切った後に、その端末で `claude-work`・`claude-personal` などを手で打って起こす (herdr-app の新規の menu・mod pjp-prefix で
worktree と一緒に Claude Code を起こすキー・`c` は素の claude のまま。複数のアカウントを同時に使うため)。そのハブから立てた子が、ハブと同じアカウントになる。

| ハブ | 子 (子のマシンで起こすもの) |
| --- | --- |
| `--account <名前>` | `claude-<名前>` |
| `--account default` | 素の claude (`~/.claude`) |
| `CLAUDE_CONFIG_DIR` が空・家の下の `.claude` | 素の claude (今までどおり) |
| `CLAUDE_CONFIG_DIR` が家の下の `.claude-<名前>` (Windows の `%USERPROFILE%\.claude-work` も) | `claude-<名前>` |
| `CLAUDE_CONFIG_DIR` がそれ以外 (家の外・名前が `[a-z0-9][a-z0-9_-]*` でない・`.claude-default`・`.claude-account`) | 何も打たずに止まる。`--account` で渡す |

- `--dry-run` と立てたときの出力の `アカウント:` の行に、選んだアカウントとわけ (`ハブの CLAUDE_CONFIG_DIR … から`・`--account から`)
  が出る。家はハブの USERPROFILE か HOME
- 名前のアカウントは、立てる前に子のマシンで launcher とアカウントの用意を確かめ、だめなら worktree・space を作る前に止まる
  (素の claude に黙って落とさない。`--dry-run` も同じわけで止まる)
  - `claude-<名前>` が子のマシンの core の PATH に無い: 子のマシンの dotfiles を新しくして用意するか、`--account default`。
    `~/.nix-profile/bin` (home-manager) か `~/.local/bin` (`claude-account add` の link) にあるのに PATH に無いときは、core の env が
    足りない (launcher も claude を見つけられない) ので使わず、herdr の外の対話シェルで `hc server restart --fresh` を打ってもらう
    (下の「罠」の「子のマシンの PATH」と同じ)
  - 用意は、子のマシンに `claude-account` (dotfiles のアカウントのコマンド。PATH か `~/.nix-profile/bin`) があれば、
    `claude-account check <名前>` の答えで見る (dotfiles の claude-account と合わせた約束)。claude-account は値を出さず、
    1Password (op) も呼ばない作り
    - 終了コード 0: 使える。出した 1 行を `アカウント:` の行に出して立てる。使えると答えたのに `claude-<名前>` が core の PATH に
      無ければ、core の env が古いとみて、上と同じ `hc server restart --fresh` の手を出して止まる
    - 1 (用意が無い)・2 (知らない名前か使い方の誤り): claude-account の出した文 (ユーザーの手) を字のまま出して止まる。token の
      手もその文に任せる
    - ほかの終了コード・時間切れ (60 秒)・打てない: 何が起きたかを出して止まる (下のファイルの見分けには戻らない)
  - claude-account の無いマシン (dotfiles が古い) は、用意のファイルの有る無しだけを見て、中身は読まない。どれも無ければ、
    次のどれかをしてから打ち直す
    - /login のアカウント (`~/.claude-<名前>/.credentials.json`): 子のマシンの端末で `claude-<名前>` を起こして `/login` する
      (ユーザーの手。ハブの会話からはしない)
    - token のアカウント (`~/.config/claude-accounts/<名前>.env`): 子のマシンの端末で `claude-<名前>` を一度起こし、出る案内
      どおりに token を置く (ユーザーの手)。launcher は dotfiles が用意し、このファイルの token を渡す。中身の形 (token の値
      そのもの・1Password の参照) と置き方は launcher の案内に任せる
    - `--account default` で素の claude で立てる
  - ファイルの見分け方の違う種類を足すときは、dotfiles の `nix/pkgs/pjp-tools/crates/pjp-hc-child/src/child/account.rs` の `KINDS` に 1 つ足す (子のマシンで見るファイルと止まったときの手)
- 素の claude の子も、子のマシンに `claude-account` (2. の探りで見つけたもの) があれば、立てる前に `claude-account check default` で
  用意を確かめる (dotfiles-private の ADR 123 §2 H。名前のアカウントと同じ約束)。claude-account は、`dotfiles.claude.tokens.default` を
  宣言したホスト (ブラウザの無い SSH 先の Linux など) では token のファイルと素の claude の wrapper を、宣言の無いホストでは
  `~/.claude/.credentials.json` (/login) を見る (macOS は確かめずに 0)
  - 終了コード 0: 立てる。出した 1 行を `アカウント:` の行に出す
  - 1: claude-account の出した文 (ユーザーの手。例: /login していない・token を set-token で入れる) を字のまま出し、worktree・space を
    作る前に止まる (`--dry-run` も)。立っても動かない子なので止める。手をするか、`--account <名前>` で用意のできた名前のアカウントで立てる
  - 2: default を知らない古い claude-account (dotfiles が宣言の入る前の版)。今までどおり確かめずに立て、`アカウント:` の行に
    「default を知らない版なので、素の claude の用意は確かめていない」と添える
  - ほかの終了コード・時間切れ (60 秒)・打てない: 名前のアカウントと同じく、何が起きたかを出して止まる
  - claude-account の無いマシン: 今までどおり確かめずに立てる
  - 自動で選ぶとき (`--on` なし) は、1 で止まる machine を外して次の machine を見る (外したわけは `外した` の行に出る)
- 控えにアカウントを残し、`restart` は立てたときのアカウントで起こす (ハブの今の `CLAUDE_CONFIG_DIR` は見ない。替えるなら
  `--account`)。アカウントの列の無い前の控えの子は素の claude のまま。`pjp child ls` は、名前のアカウントの子だけ行の末尾に
  `アカウント claude-<名前>` を出す
- launcher (Linux は dotfiles の claude.nix) は、/login の資格情報より優先される env を外し (token のアカウントの launcher は
  token を env で渡す)、`CLAUDE_CONFIG_DIR` を `~/.claude-<名前>` にして claude を exec する。子の端末の前面のプロセスは claude の
  ままで、状態の報告 (OSC 7501・`hc get` の `reported`・`status`)・`<hc from=…>` の報告・`pjp child read`・pjp-spaces の印は
  今までどおり (2026-11-19 に WSL の claude-work を自分専用の core で立てて見た)
- `hc run` は hc を打った側 (ハブ) の env を子に渡さず、子は core の env で起きる。core の env に紛れたアカウントの env (core を
  claude-work の会話から立て直したときの `CLAUDE_CONFIG_DIR` など) は、`pjp child` が `env -u` で外す (上の 5.)
- ログイン以外 (settings.json・CLAUDE.md・skill・projects (会話の記録)) は `~/.claude` と共有なので、`--continue`・`--resume`・
  `--session` はアカウントをまたいで前の会話を引く。信頼の確認の記録 (`.claude.json`) はアカウントごとなので、そのアカウントで
  repo を信頼していないと、新しい worktree で信頼の確認が出る (WSL の `~/.claude-work` の記録は 0 件だった。今作った worktree の
  信頼の確認は承認してよい。下の「起動直後の画面」の 2)
- token のアカウントの子は、claude.ai の connector と Remote Control を使えない (token の認証は推論だけ)

## 起動直後の画面

`pjp child new` (と `restart`) は、子が状態 (OSC 7501) を報告するのを最長 30 秒待つ (`hc get` の `reported`)。ふつうは
`状態: working` と出て終わる。確認の画面で止まった・30 秒たっても報告が無い・claude が終わった、のどれかなら、画面を出して
`!!` の行で知らせる。

1. 出た画面を読む (出力は画面の終わりの 30 行。足りなければ `pjp child read <英字> --lines 0` で画面の全部)
2. 今作った worktree の信頼の確認 (bypass permissions の警告と一緒に出るものも) なら承認してよい。選ぶのは
   `hc keys <子の端末> <キー>…` で、並びは画面で確かめる (前に出た画面は承認が 2 番目で `down` → `enter`)
3. `--chrome` の子の「Claude in Chrome」の案内 (末尾が「Enter to confirm · Esc to cancel」) は、ユーザーが Claude in Chrome を
   使うよう頼んだ子なら `hc keys <子の端末> enter` で確定してよい (`references/chrome.md`)
4. それ以外の画面はユーザーに聞く
5. 答えたら `pjp child ls` で状態を見る (working になっていれば動き出した。`hc wait <子の端末>` は働き終わるまで待つので、
   ここでは使わない)

- WSL で `--dangerously-skip-permissions` を付けて `~/.herdr/worktrees` の新しい worktree に立てた子 (W1-1・W2-1・W2-2) は、
  信頼の確認でも bypass の警告でも止まらず、起動の引数の依頼から動き出した (2026-11-16。user の settings の
  `skipDangerousModePermissionPrompt` が true)。`--no-chrome` の Linux の子は Chrome の案内も出さなかった

## 依頼を送る (起動の後)

- 答え・続きの依頼は Write でファイルに書き、`pjp child send <英字> --file <ファイル>` で送る (`hc send`。PowerShell でも
  引用で崩れない)
- 子には `<hc from="<この端末>">…</hc>` の札で包まれて届く。子は親からの文として読む。`/effort`・`/exit` のような command は
  文として届くだけで効かない (下の「effort を上げる」・「片付け」)
- hc は、人が子の入力欄に書きかけていると最後のキーから 60 秒まで待つ。子が確認の画面で止まっていれば断る (`pjp child send`
  がそう出す)。`--force` は使わない
- **送る前の守り:** `pjp child send` は送る前に `hc get <子の端末> --json` を読み、子の端末で Claude が動いているかを
  確かめる。動いていない・確かめられないなら送らずに終了コード 1 で止まり、何が見えたかとどうすればよいかを 2 行で出す。
  Claude が落ちる・core が止まって立て直す (Windows・WSL の起こし直しなど) と、hc の keep が端末の中身を shell に替え、子の
  英字・端末の住所・名前・label は残る。そこへ送った文は札が付かず、shell が 1 行ずつコマンドとして打つ (2026-11-18・19 に 3 回
  起き、`>` で始まる引用の行が子の worktree に空のファイルを作った)
  - 動いているとみる: 状態の報告 (OSC 7501 の `status`。idle・working・done・blocked・error のどれか) がある、または前面の
    プロセス (`foreground`) が claude (報告しない立てられ方・立てた直後)。blocked の子は今までどおり hc が断る
  - 動いていないとみる: 端末が終わっている、または状態の報告が無く、前面が claude でない。hc が shell に替えた端末は `argv` と
    `foreground` が shell、`status` が null、`reported` が false になる (hc 0.1.21 で、本物の子の端末と、自分専用の core で落とした
    偽の claude の両方で見た)。claude が終わって root の shell に戻った端末も、状態の報告が消えて前面が shell になる
  - 確かめられない: 状態の報告も前面のプロセスも無い。落ちた直後の 1 秒ほど (hc が shell に替える前。`reason: signaled`) と、
    foreground を返さない hc
  - 画面の字 (prompt・status line) では見分けない。hc の手引きが画面の字から状態を推さないよう言い、`restore_screen` の core は
    前の program の画面を新しい shell の上に出し、prompt と status line の形は人の設定で変わる
  - 止まったら: `pjp child read <英字> --lines 0` で画面を見て、shell なら `pjp child restart <英字>` (前の会話の続きから) で
    立て直してから送る (前の作業の文脈を持ち越さないなら `--fresh --brief`)。わざと shell に送るときだけ `--no-agent-check`
    (この確かめを飛ばす)。`pjp child ls` はそういう子の状態を「Claude が動いていない (前面 bash)」と出す
  - `pjp child new`・`restart` の `--brief` は claude の起動の引数で渡し、端末に打たないので、この守りは要らない。`pjp child report`
    (子 → 親) は、親の端末に同じ確かめをする。Windows の core は pwsh の中で動く claude でも前面に pwsh.exe を出し、claude が
    終わって pwsh に戻っても状態の報告を消さない (hc 0.1.21 の手引き) ので、ハブの Claude を終えて pwsh に戻った端末は見分け
    られない (hc の keep が pwsh に替えた端末は、状態の報告が消えるので見分ける)

## 前の作業の子に次を頼むとき

前に作業をした子に次の依頼を送る前に、立て直すか・compact してから続けるか・そのまま続けるかを、`references/common.md` の
「前の作業の子に次を頼むか」で決める。hc 版の打ち方は次のとおり。

- 文脈の残りを読む: `pjp child read <英字> --lines 0` の画面の最後の方の status line
  (`📄top · <model> · <dir> · <branch> · NN% left`) の「NN% left」
- 立て直す (別の作業):
  - 新しい worktree で: `pjp child new` で新しい子を立てる (英字も新しくなる)。前の子は PR が merge されたら、ふだんどおり
    「片付け」で片付ける
  - 同じ worktree で: `pjp child restart <英字> --fresh --brief <依頼>`。前の端末を終えて消し、`--continue` を付けずに新しい
    会話で立てる (effort・pack・chrome は前の値を引き継ぎ、替えるなら渡す)。`--brief` が要る。子のチケットの印 (`pjp.ticket`。チケットのある子
    だけ) は引き継がないので、チケットのある子には依頼で `pjp mark name` を打たせる (足し分の雛形の行。前のチケットを続ける運用の子
    なら、その ID で)。
    長く使う運用の子 (`--checkout`・`--dir` で立てた子) を日をまたいで立て直すのもこれ。前の端末が立てた端末が残っていると
    `!!` で知らせる (下の「effort を上げる」)。新しい会話はその端末を知らないので、依頼にどうするかを書く
- compact してから続ける: 子が idle か done (`pjp child ls`) のときに、2 つ続けて打つ

  ```text
  hc keys <子の端末> / c o m p a c t space
  pjp child send <英字> --file <残すものを 1 段落で書いたファイル>
  ```

  - `hc send` の文は `<hc from=…>` の札で包まれうる (下の「罠」)。`/compact ` までを `hc keys` で 1 字ずつ打っておけば、送った文は
    札ごと `/compact` の後ろの指示に入り、command として効く。2026-11-17 に、自分専用の HC_SESSION で立てた claude へ、hc の端末
    (bash) から打って確かめた (この形では `hc send "/compact …"` にも札が付かず効いたが、ハブの claude から送る形は確かめていない
    ので、2 つに分けて打つ)。`hc keys` で打った字は人の書きかけに数えられず、`hc send` は待たずに貼った
  - 要約の間は working になる。`pjp child ls` で working でなくなったら、`pjp child read <英字> --lines 20` で
    `❯ /compact …` の下に「⎿ Compacted (ctrl+o to see full summary)」が出たのを見てから、次の依頼を `pjp child send` で送る。
    「Not enough messages to compact.」なら要約するものが無い (そのまま送ってよい)
- 再起動の後: `pjp child restart <英字>` (`--continue`) で立てた直後の画面に、前の会話の「NN% left」が出る。50% 未満なら、上の
  compact を挟んでから続きの依頼を送る

## 待つ・読む

- 子の報告は、この会話の入力に `<hc from="<machine>/t13">子 A: …</hc>` の形で届き、次のターンになる。子が blocked・error・
  終わったとき (子が報告できないとき) も、hc が知らせる。待たなくても取りこぼさない
- ほかにすることが無ければ、`hc wait --children any --timeout 3600` を裏で流して待ってよい (`reason: message` は届いた文が
  次の入力に入ったということ。`timeout` は失敗でなく、待ち直す)
- 子の状態は `pjp child ls` (`working`・`idle`・`blocked`・`報告なし`・`Claude が動いていない (前面 bash)`。
  子にチケットがあれば、子の label `pjp.ticket` も出る)。`Claude が動いていない` の子は、Claude が終わって hc が shell に替えた端末 (上の「送る前の
  守り」)。英字と端末の住所は前のままなので、この欄で見分ける
- 画面は `pjp child read <英字> --lines 120` (`--lines` は画面の上の履歴の行数)。子が working・blocked の間は履歴を読めず、
  画面だけが返る (そう添えて出す)
- 子の最後の発言の最初の行が「作業中」なら終わっていない (裏の subagent や CI を待っている)
- 終わったかは最後の見出し「## 報告 …」で見分ける。PR の URL では見分けない (途中の「作業中: PR #… の CI を待っている」にも
  出る)。報告が長くて見出しが範囲の外に出たら `--lines` を増やす

## 子の質問と確認の画面

- 質問 (書いてターンを終えたもの): ユーザーに聞き、答えを `pjp child send <英字> --file <答え>` で送る
- 確認の画面 (blocked): `pjp child read <英字> --lines 0` で画面を読み、`references/common.md` の「答えてよい範囲」に当たれば
  `hc keys <子の端末> <キー>…` で答え、当たらなければユーザーに聞く。`hc send --force` で確認を飛ばさない

## effort を上げる

**ユーザーの指示 (2026-11-10):** 子の作業が途中で難しくなったら、effort を上げる手も上げる先も指揮役 (親) が選ぶ。上げる先は、
既定の `high` の子なら `max`、`medium` の子なら `high` か `max` (`references/common.md` の「effort を選ぶ」の表を引き直す。迷ったときの
決め方も同じ)。

`hc send` で `/effort` を送っても command にならないので、hc 版の手は 2 つ。

| 上げる手 | 向く場面 (目安) | 打つもの |
| --- | --- | --- |
| 立て直す (同じ worktree で続きから) | 今の文脈 (読んだもの・試したこと・決めたこと) のまま続けさせたい | `pjp child restart <英字> --effort <max か high> --brief <続きの依頼>` |
| 新しい子に引き継がせる | やり方を組み直したい・間違った前提や散らかった文脈を引きずらせたくない | `pjp child new` (新しい名前。依頼に branch・PR・残っていること・詰まった所 (チケットがあればチケットも) を書く) |

- `restart` は前の端末を終えて消し (working なら `--force` が要る)、同じ worktree・名前・英字・space・label で
  `claude --continue` (その worktree の前の会話の続き) を立てる。effort・pack・chrome は、控えにある前の起動の値を引き継ぐ。
  替えるものだけを渡す (`--effort`・`--pack`・`--synced`・`--chrome`・`--no-chrome`)。`--pack` か `--synced` を 1 つでも渡すと、
  pack は渡したものだけになる
- 前の端末の見ていない解説動画の印 (`🎬✅`。label `pjp.video.<id>`) は、新しい端末へ同じ label で引き継ぐ (同じ space の行に
  出たまま。`--fresh` でも)。作りかけの印 (`🎬⏳`) があり、前の端末の Claude が動いている (か分からない) 間は止まる (前の端末を
  終えると作るのが止まる)。作り終えるのを待つか、止まっているなら `--force` (作りかけの印は引き継がない)。前の端末の Claude が
  終わっていれば、作りかけの印は引き継がずに進む
- `restart` は前の端末を終える前に、子のマシンの `hc ls` で、その端末が立てた端末 (孫) を探し、見つけた端末を `hc get` で読む
  (`hc ls --json` には label も `die_with_parent` も載らない)。2026-11-19 の朝、再起動の後の `restart` が、前の子が
  `hc run --outlive-parent` で立てた常駐の bot の端末 (live と monitor) を何も言わずに残し、立て直した子の下に枝が出なかったので足した
  - 前の端末を終えても残る孫 (`--outlive-parent` で立てた端末) は、`!! 前の端末 <住所> が立てた端末が N つ生きている` の下に、
    住所・名前・space と tab (label の where。無ければ space と tab の id) を並べて進む。前の端末を消すと、その孫の親は消えた
    住所のまま残り、herdr-app の Agents 欄の木で立て直した子の下に出ない (hc には親を付け替えるコマンドが無い)。そのまま使っても
    動くが、木には出ない
  - 知らせが出たら、立て直した子への続きの依頼に、残った端末をどうするかを書く。使わせるなら、子にその端末を閉じさせ、子の
    端末から `hc run --outlive-parent` で立て直させる (木で子の下に出る)。要らなければ子に閉じさせる (`hc kill` → `hc rm`。
    片付けるのは立てた側なので、指揮役は閉じない)。中で動いている program (live など) を止めてよいかが分からなければ、
    ユーザーに聞いてから依頼に書く
  - 前の端末と一緒に終わる孫 (`--outlive-parent` なしで立てた手伝い。`die_with_parent` が true) がいれば、前の端末を終える前に
    止まって並べる (子が working なら、それも同じ断りに出す)。終わってよければ `--force` で進む (一緒に終わる端末を `!!` で並べて
    から終える)。終わらせたくなければ、子がその端末を使い終えるのを待ってから立て直す
  - 孫を探せなかった (子のマシンの `hc ls` が落ちた) ときは、`!!` を 1 行出して立て直す (再起動の後の立て直しを止めない)。
    `hc get` で読めなかった孫は止めずに、行に「--outlive-parent で立てていなければ、前の端末と一緒に終わる」を添える
  - 前の端末がもう無いとき (前の `restart` が `hc run` で落ちたなど) も、残った孫を「(もう無い)」と添えて知らせる。控えの住所に
    別の端末がいる (`!! 控えの端末は別の端末になっている`) ときは、その端末の子は前の子の孫でないので探さない
- herdr-app の無いマシンの子 (label から herdr-app に作らせた space) は、space の最後の端末が子なので、先に前の端末を消すと
  herdr-app が space を消し、同じ id で名前の空の space を作り直す。そこで `restart` は、前の端末を
  `hc kill` で終えてから新しい端末を立て (hc の名前は生きた端末の中で一意なので、終えただけの端末と同じ名前で立てられる)、
  herdr-app が新しい端末をその space に置いたのを doc で見てから (置かなければ最長 10 秒待ってから) 前の端末を `hc rm` で消す。
  space の名前は前と同じ (前の端末を終える前の doc の名前、無ければ控えの space_name) にそろえる。作り直された space なら付け
  直し、space が無くなっていれば `new` と同じく足す
  - herdr-app が、終えただけの端末のペインもすぐ外すなら、space は一度空になって作り直され、一覧の末尾に移る (名前は付け直す。
    本物の herdr-app で確かめていない)
  - 立てられなかったときは、前の端末を終えたまま消さずに残す (space・名前・並びが残る)。もう一度 `restart` すれば同じ道で通る。
    hc run が落ちた後に名前で探すとき、終えただけの前の端末は立った子とみない
- 子のチケットの印 (`pjp.ticket`。チケットのある子だけ) は前の端末から引き継ぐ。前の端末が消えていると (再起動の後) 引き継げないので、続きの依頼に
  「pjp mark name '<子のチケットの ID> <一言>' を打ち直す」と書く
- `--fresh` は、前の会話を続けずに新しい会話で立てる (作業が替わるとき。上の「前の作業の子に次を頼むとき」)。effort を上げる
  だけなら付けない
- 再起動で claude が終わった子も、ふつうは `pjp child restart <英字>` (`--continue`) で前の会話の続きから立つ。その worktree で
  別の会話を後から立てていて、続けたいのがそれより前の会話のときだけ、`--session <会話の ID>` (`claude --resume <ID>`) を付ける。
  ID は子のマシンの `~/.claude/projects/<worktree のパスの / と . を - にした名前>/` の `<ID>.jsonl` の名前
  (`hc exec --on <子のマシン> -- ls -t <その絶対パス>` で新しい順。子のマシンは `pjp child ls` の子の端末の住所の頭 (`<machine>/t13` の
  `<machine>`)。`hc exec` は shell を通さないので `~` は使えない)
- 続きの依頼の頭に「この子は effort <level> で立て直した (<理由>)」と書く。引き継がせる新しい子には、
  前の子の branch・PR を使わせる (チケットがあれば、新しく切らせずに前の子のチケットを使わせる)
- どの手でも、上げたことと理由をユーザーへの報告で伝える (Dev Tracker のチケットに残す手は足し分の skill)

## 罠

| 罠 | 症状 | 対処 |
| --- | --- | --- |
| hc send の札 | `/exit`・`/effort` を送っても `<hc from=…>/exit</hc>` の文として届き、command として効かない | 終えるのは `pjp child cleanup` (hc kill → hc rm)、effort は `pjp child restart`、compact は `hc keys` で `/compact ` まで打ってから `pjp child send` (「前の作業の子に次を頼むとき」) |
| 子の親の取り違え | 子の親がこの会話でなく子のマシンの別の端末になり、子の報告がその端末にコマンドとして打たれ、Agents 欄でもこの会話の下に出ない (`hc run --on <machine> --parent t8` の `--parent` はそのマシンの中で読まれる) | `hc run` に `--parent` を渡さない (`pjp child` は渡さない。`HC_TERMINAL_ID` の端末が親になる)。`pjp child new`・`restart` が `!!` を出したら、その子を `hc kill`・`hc rm` で終えて立て直す |
| 前の子が立てた端末の親 | `restart` の後、前の子が `hc run --outlive-parent` で立てた端末が、Agents 欄の木で立て直した子の下に出ない (親が消えた端末のまま。hc には親を付け替える手が無い。2026-11-19 に常駐の bot の端末 (live と monitor) で起きた) | `restart` の `!! 前の端末 … が立てた端末が N つ生きている` を見て、続きの依頼で、子の端末から立て直させるか閉じさせる (「effort を上げる」) |
| Claude が終わった子の端末 | Claude が落ちる・core が止まって立て直すと、hc の keep が端末の中身を shell に替え、英字・端末の住所・名前・label は残る (`pjp child ls` だけでは気づきにくかった)。そこへ送った文は札が付かず、shell が 1 行ずつコマンドとして打つ (2026-11-19 に `>` で始まる引用の行が空のファイルを作り、`kill …`・`yes` で始まる行ならそのまま動いていた)。claude を終えて shell に戻った端末では、一度 OSC 7501 を報告していれば札が付いてコマンドにならないこともある (W2-1 の Windows で指揮役が見た) が、頼らない | `pjp child send` が送る前に止める (「依頼を送る」の「送る前の守り」)。`pjp child ls` は「Claude が動いていない (前面 bash)」と出す。立て直すのは `pjp child restart` (前の端末を消し、新しい端末を `hc run` で立てる)。その端末に `claude --resume …` などを打たない |
| herdr-app の無いマシンの space | label から herdr-app に作らせた space は、最後の端末を消すと herdr-app が消す。既に space に入った端末の label を付け替えても、別の space へは動かない | 子の端末を手で消して立て直さない (`pjp child restart` は前の端末を消すのを立てた後にする)。片付けは `pjp child cleanup` |
| PowerShell の `~` | 引用符の無い `~/x` は Windows のホームに替わり、子のマシンのパスでなくなる (`pjp child` が断る) | `'~/x'` と引用符で囲む |
| 長い依頼 | Windows のコマンドラインの上限 (約 32,767 字) を超える | 30,000 字で `pjp child new` が断る。分けて、後半を `pjp child send` で送る |
| 子のマシンの PATH | core を素の login の env で立て直すと、mise の claude が PATH に無い | `pjp child new` は mise の置き場所も探す。それでも見つからなければ、herdr の外の対話シェルで `hc server restart --fresh` をユーザーに頼む |
| HERDR_* の漏れ | herdr の pane から core を立て直すと、hc の子に旧 herdr の env が付く | `pjp child` は `env -u` で外して立てる (足し分のあるホストでは `pjp doctor` も漏れを出す)。core は herdr の外から立て直す |
| 状態を報告しない相手 | `hc send` の `started` が分からない。前面のプロセスが claude なら `pjp child send` は送り、「started: 不明」と出す (前面も claude でなければ送らない) | 届いたかは `pjp child read` で画面を見る |
| 人の書きかけ | ハブの入力欄に書きかけがあると、子の報告は最後のキーから 60 秒待ってから貼られ、書きかけに混ざりうる | 子の報告は 1 行に保ち、中身は画面で読む |
| 並行の PR の衝突 | 同じファイル (README の表・Cargo.lock など) を触る PR 同士がぶつかる。1 時間前に衝突なしと確かめても、その間に main に別の PR が入る | merge の直前に fetch し、`git merge-tree --write-tree --name-only <A> <B>` で組ごとに確かめ直す |
| ADR の番号 | 並行の PR が同じ番号を取る | 子は ADR を書く前に指揮役に番号を聞き、指揮役が順に割り当てる。文書を別の repo に置く repo は、置き場の repo の番号 |
| 手が空いた子の要約 | 「Compacted while idle」で自動で要約され、その間は working に見える | 要約が終わってから送る。要約の後も依頼は通る |

## 片付け

片付けるのは、worktree の子なら PR が merge され、worktree に commit していない変更が無くなってから。PR の無い子 (ブラウザだけの
作業。`references/chrome.md`) は、merge を待たず、子の作業が済んでから (チケットのある子は Done になってから)。

merge の後、片付ける前に、子の報告の「merge の後にすること」を済ませる。

- 子がするもの (この子が worktree でする): merge したことを伝えて子に頼み (`pjp child send`)、済んだと「## 報告」が来てから
  片付ける。流した結果を commit する PR が要れば出してよいこと、済んだら最初の依頼と同じ形の「## 報告 子 <英字>」で
  止まることを添える。済まなかったと返ったら、片付けずにユーザーに聞く
- ユーザーがするもの (pull・`~/dotfiles/setup --update` など): 指揮役は打たず、ユーザーへの報告で伝える。打ち終わるのは待たない
- 流した結果を commit する PR が出たら、その PR が merge されるまで片付けない。ユーザーの CLAUDE.md などが、出したらすぐ merge すると
  決めた PR (依頼の雛形の「しないこと」の merge の例外) は子が merge するので、報告に merge したとあればそのまま進む。
  ユーザーに merge してよいかを聞かない

それから `pjp child cleanup <英字>` を打つ (打つ前に見るなら `--dry-run`)。

1. 確かめる。どれかが外れたら何もせずに理由を出し、終了コード 1
   - PR が merge 済みか (worktree の今の branch で `gh pr list --repo <owner/repo> --head <branch>`。ハブの gh を使うので、ハブで
     `gh auth login` してある)。open の PR があれば止まる。merge の後の作業で子が `git switch --detach origin/main` した worktree は、
     reflog の直前の branch (`checkout: moving from <branch> to …`) を作業の branch とみる。見つからなければ `--branch <作業の branch>`
     で渡す。PR の無い子 (作業の branch を切っていない・`--checkout`・`--dir` の子) は `--no-pr` を付ける (子の作業が済んだのを
     確かめてから。チケットのある子は Done なのを)。控えに repo の無い子 (`--checkout`・`--dir` で立てた子) が PR を出したなら、`--repo <owner/repo>
     --branch <作業の branch>` で渡すと PR を確かめる (worktree と branch は `pjp child new` が作ったものでないので消さない)
   - worktree に commit していない変更が無いか (`git status --short`)
   - herdr-app の無いマシンでは、子の space に子のほかの端末 (ユーザーが開いた shell など) がいないか (子のマシンの doc の
     ペインを `hc get` で確かめる。確かめられない端末もいるとみる)。いれば herdr-app の画面で閉じてもらってから片付ける。
     `--force` なら、その端末と space を残して進む (その端末は消えた worktree に残る)
   - 子に生きている子 (孫) がいないか (子のマシンの `hc ls` の parent)。いれば、先に子に孫を片付けさせる (依頼には、孫を
     片付けるのは「この worktree の外を触る」の例外で、子自身は片付けない (指揮役がする) と書く)
   - 子が working でないか (止めてよいなら `--force`。孫を確かめられないときも `--force` で進める)
   - 子が解説動画を作っていないか (子の端末に作りかけの印 `🎬⏳` があり、子の Claude が動いている)。作り終えるのを待つか、
     止まっているなら子に `pjp mark video stop` を打たせる。`--force` なら作りかけの印を捨てて片付ける (子の Claude が終わって
     いれば、作るのはもう止まっているので止めずに捨てる)
   - 子の見ていない解説動画の印 (`🎬✅`) の移す先があるか (この会話の端末。hc の端末の外で `--ticket` を付けて打つなら子の
     hc の親)。無ければ `--force` で片付ける (印は子と一緒に消える)
2. 子の見ていない解説動画の印を、移す先の端末へ同じ label で移す (`from` に子の英字と端末を足す。キーが重なれば `-2`…)。
   ユーザーが見るまで、この会話の行の 3 行目から `🎬✅:<名前>` が出る。移せなければ (hc が落ちた) 何も片付けずに止まる
3. 子の端末を終えて消す: `hc kill` → `hc wait` → `hc rm`。`/exit` は送らない (札で包まれて効かない。指揮役が確かめた。hc の
   手引きの片付けも kill → rm)
4. space を閉じる (`herdr-app do space.close` に `{"id": "<machine>/<space>", "confirmed": true}`)。space の中の端末 (space を
   作ったときの shell) も終わる。herdr-app が断ったときは、herdr-app の画面で閉じる
   - herdr-app の無いマシン (Linux のハブ) では `space.close` を打てない。space の最後の端末を消すと herdr-app がその space を
     doc から消すので、3. の後に子のマシンの hc の doc `herdr-app` を 0.5 秒おきに最長 5 秒読み、消えるのを待つ
     (`space … は … に無い (herdr-app が消した)`)。残っていて、中に子のほかの生きた端末が無ければ (herdr-app が開いていない・遅い)、doc から
     その space を消す (doc から消しても中の端末は終わらない)
   - `--force` で進めて、子の space にほかの生きた端末がいれば、その端末も space も残し、`!! space … に、子のほかの端末 (…) が
     残っているので閉じない` と出す (自分が立てた端末ではない。doc から消しても、label のある端末は herdr-app が space に置き
     直す)。要らなければ herdr-app の画面で閉じる (`space.close` は中の端末も終わらせる)。確かめられない端末は生きているとみる。
     doc を読めないときは `note:` を出して進める (一時に読めないときは、待つ間は読み直す)
5. worktree を消し (`git worktree remove`)、作業の branch を `-d` で消す。squash で merge した branch は `-d` が通らないので、
   PR が merge 済みと確かめたときだけ `-D`。`worktree/<名前>` は切った元 (`origin/main` など) の祖先 (commit が無い) なら `-D`。
   消せなかった branch は、そう出して残す (`pjp-git-worktree-cleanup` で片付ける)
6. 控えに cleaned を書く (英字は使い回さない)

- 打ち直してよい (片付けた子には「もう片付けてある」と出す)
- ハブの worktree (`%USERPROFILE%\.herdr\worktrees\h\…`) は、ユーザーが herdr-app の「Remove worktree」で消す。
  `pjp.finished` の付いた会話の worktree が、消してよいもの
- 親の会話が先に終わったあと、ユーザーに頼まれて子を片付ける会話は、`--ticket <親のチケット>` (チケットの無い親なら `t-<親の端末の住所>`) を付けて同じに打つ
