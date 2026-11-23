// pjp-hub-panel: ハブの Claude がユーザーに見せる panel。質問 (選んで送る) と、チケット・進み具合・PR の木 (work。チケットの下に
// 進み具合の段と PR を 1 段下げて並べる。answer のある段は押してハブへ送れる)・ユーザーの問いへの答え (qa。問いごとに開け閉めする)・
// 今の状況の説明 (markdown)・進み具合 (flow)・チケットと PR の一覧 (tickets・prs)・図 (SVG などの画像に、点滅や動く点を重ねる) を、端末の横の
// ペインに出す。図はペインの幅に合わせて縮め・大きくし、クリックすると大きく見る小窓で開く (下の「図の大きさと、大きく見る小窓」)。
// props: { file: "<panel.json の絶対パス>", terminal: "<答えを送る端末。例 t1m>", role: "summary" | "questions" (省いてよい) }
//   role で、1 つの panel.json を「まとめ」と「問い」の 2 つのペインに分けて出せる (ハブはまとめのペインをハブの端末の左に開いて
//   おき、問いを出すときだけ、ハブの端末を右に分けて問いのペインを開く。並べ方は win/README.md の「herdr-app の mod」)。
//   - 無い: 問いと状況の節を 1 つのペインに出す (role を足す前の形)
//   - "summary" (まとめ): title・updated・sections だけを出す。questions は出さない (問いの送信の UI も、Enter で送ることもしない。
//     チケットの木の段の answer は、下の「段の answer」の確かめの「送る」で送る)
//   - "questions" (問い): questions だけを出す (見出し「問い (件数)」・問いと選択肢・送信。Enter でも送る)。title・updated・
//     sections は出さない。questions が空なら「問いはありません」と出す (問いのペインを閉じるのはハブ)
//   - ほかの値: わけを出し、無いときと同じに出す
//   どの role のペインも、開いたときに自分からキーボードを取らない (handle に focus するのは、pane.go で来た "focus" (nextCommand) と、
//   ユーザーが選択肢をクリックしたときだけ。図を大きく見る小窓は別で、開いたときに focus する)。
//   問いのペインは、「送信」(このペインで Enter も) で送れたら自分を閉じ、キーボードを terminal へ戻す。mod は自分のペインの ID を
//   知る手段が無い (props にも、panes() の mod のペインの行にも無い) ので、送信の頭で、この panel の handle がキーボードを持つ
//   (is_focused) ときだけ focused() の pane (キーボードのあるペイン) を控え、その panes() の行が端末を持たず (terminal が null)、
//   mod がこの mod (pjp-hub-panel か、写しの pjp-hub-panel-<何か>) のときだけ、Enter まで済んだ後にその ID で pane.close を打つ
//   (同じ mod のまとめのペインがキーボードを持つときに、まとめを閉じない)。確かめられなければ閉じず「送った (閉じるのはハブ)」と
//   出す。pane.close を pane なしで打たない (キーボードのあるペインを閉じる。それが端末なら、その端末が終わる)。「入力欄に入れる」
//   では閉じない (端末で直に答えたときと同じく、閉じるのはハブ)。
// props.image (ハブは渡さない): 図の節 (panel.json の sections の type "image" の 1 つ) がオブジェクトで来たら、その図だけを出す
//   小窓になる (panel の図のクリックで、この mod が自分を開くときに渡す。下の「図の大きさと、大きく見る小窓」)。
//
// リンク: markdown の文 (markdown の節の text と、問いの body) の [字](URL)・<URL>・素の URL は、TextView がリンクにする (色・下線・
//   ポインタの形は TextView が theme から決める)。押すと http と https の URL (host のあるもの。user@host の形は除く) だけを既定のブラウザで
//   開き (cx.open_url)、ほかの scheme (file:・mailto: など) やパスは開かずに、下の行にわけを出す (開けたら、そのわけは消す)。TextView の既定の
//   開き方は scheme を確かめないので、on_link_click で替える。図の説明 (caption) の TextView はこの扱いの外 (既定の開き方のまま)。
//
// ミニ絵: markdown の節の text に、絵だけの行 ![<説明>](<図のパス>) を 1 行書くと、その行で text を切り、前の文・小さな絵 (ミニ絵)・後ろの文の
//   順に縦に並べる (文はそれぞれ TextView で出し、リンクの扱いは上の「リンク」のまま)。絵だけの行は、前の空白はいくつでもよく、後ろに字を
//   続けない (後ろの空白はよい。``` や ~~~ で囲んだコードの中の行は絵にしない)。図のパスは image の節の src と同じ決まり (下の「図の置き場所」の
//   pjp-hub-panel-media/ からのパス。"mods/" で始まれば home から)。ハブは、絵を付ける項目の詳細の最後の行のすぐ後ろ (次の見出しの項目の前) に置く。
//   - 大きさは 1 つ: 幅 200・高さ 80 (この mod を書いたときの px。100% で 240×96) を panel の文字の % で変え、ペインの幅には合わせない。ペインが
//     狭くて入らないときだけ、縦横の比を保って縮める (0.1 倍まで)。動き (marks) は付けない。
//   - 横の位置は、すぐ上の行 (空の行は飛ばす) の字の頭にそろえる。絵の行の前の空白の数は見ない。箇条書きなら記号の後ろの字の頭で、
//     herdr-app の TextView (gpui-base 0.7.3〜0.10.0) は入れ子の箇条書きを 1 段ごとに 1 段の幅 (字の大きさの 1.4 倍) ずつ下げ、項目の記号
//     (1 段目から "•"・"◦"・"▪"・"‣"・"⁃"。番号は 1 段目が "1."、2 段目が "A."、3 段目からは "a." で、並びの最初の番号から数える) を記号の欄
//     (幅は 1 段の幅より狭くならず、記号の右に 1 段の幅の 0.3 倍の空き) に置いて、欄の後ろに字を置くので、1 段の幅 × (段 - 1) + 記号の欄の幅に
//     する。記号の欄の幅は、節の中の見えない物差し (記号の欄と同じ作りの要素) の on_size_change で測る (測る前の最初の 1 回は 1 段の幅)。
//     段は、切った文の塊ごとに頭から字下げで数える。すぐ上も絵なら、その絵と同じ位置。
//   - 押すと、image の節の図と同じ小窓で大きく見る (題は節の題、説明は小窓の図の説明)。ポインタを載せると、説明と図と同じヒント
//     「クリックで大きく見る (Esc で閉じる)」を出す。説明はミニ絵の下には出さない。
//   - 出せないとき (パスが空・絶対パス・.. を含む・URL・図が無い・SVG を読めない) は、その場所に薄い字 (dim) で 1 行「ミニ絵を出せない: <わけ>」と
//     出す。図があるかは、panel.json を読み直すたびに readTextFile で確かめる (SVG は中身に <svg があるかも見る。SVG でない図は、有るかだけ)。
//   - 絵の行で切った後ろの文は、別の TextView で出す。後ろの文が箇条書きの項目の行で始まるときは、絵の行の前で開いていた項目のうち、その項目を
//     入れる項目と同じ並びの 1 つ前の項目を、中身の無い項目の行 (元の字下げと記号。番号はその項目の番号) にして頭に足し、元の段・記号・番号の
//     まま出す (TextView は、中身の無い項目と、入れ子の並びから始まる項目に、記号も行も出さない)。後ろの文が項目でない行 (続きの文) で始まると、
//     左の端からの別の文として出る (4 つ以上の空白で始まるとコード)。mod では直さない (置く場所の決まりで避ける)。問いの body と図の説明
//     (caption) では、絵だけの行も今までどおり TextView に渡す (ミニ絵にしない)。
//
// チケットと PR の一覧 (type "tickets"・"prs"): ハブが panel.json に書いた行を、そのまま 1 行ずつ出す (mod から gh や Notion を引かない)。
//   行の形: tickets は { id: "TKT-n", title, url: "https://app.notion.com/p/…", status: "In Progress", note }、
//   prs は { id: "dotfiles#251", title, url: "https://github.com/pollenjp/dotfiles/pull/251", state: "open", ci: "pass", note }。
//   上の段に ID・状態の札・題を並べ (入らなければ札や題が次の段へ回り、長い ID と題は縮んで折り返す)、note (一言) はその下に小さく出す。
//   ID (accent の色) と題は下線つきで、押すと url を開く (リンクと同じく http と https だけ。ダブルクリックの 2 回目は数えない。url が無い・
//   ほかの scheme なら下線の無い押せない字で出す)。
//   status の札: Todo は muted・In Progress は working・In Review は accent・Done は ok (緑)・Canceled は dim・Blocked は blocked (赤)。
//   state の札: open は ok (緑)・draft は muted・merged は ansi5 (紫)・closed は blocked (赤)。ci の札: pass は「CI ✓」(緑)・fail は
//   「CI ✗」(赤)・pending は「CI …」(working)。どれも大文字小文字を問わず、知らない値は muted の札に字のまま (ci は「CI <値>」) 出し、
//   無い・空なら札を出さない。rows が空なら「(行はありません)」と出す。
//
// チケット・進み具合・PR の木 (type "work"): チケットの下に、そのチケットの進み具合 (段) と PR・子のチケットを 1 段下げて並べる木。
//   ハブはまとめのペインの一番上に置く (mod は節を並べ替えず、panel.json の順のまま出す)。行はハブが panel.json に書いたものを、そのまま
//   出す (mod から gh や Notion を引かない)。行の形:
//     { kind, id, title, url, status, state, ci, who, note, steps: [{ label, state, answer }], children: [<行>…], related }
//   - kind: "ticket" | "pr" | "item"。無い・空なら "ticket"。大文字小文字を問わず、知らない値は "item" と同じに出す。id は ticket が
//     "TKT-n"・"WRK-TKT-n"、pr が "<repo>#<番号>" で、item は無くてよい。ticket の id は開け閉めを覚える鍵にもなる。
//   - 上の段に、開け閉めの印の欄 (▸・▾)・ID・状態の札・題・who の札 (誰が・どこで。例 "子 C · example-wsl/t6v"。ハブの行は "ハブ") を並べ、
//     入らなければ札や題が次の段へ回る (長い ID・題・who は縮んで折り返す)。その下に steps の段 (flow の段と同じ札と ›。active は点滅。
//     answer のある段は押せる札で、押すと answer をハブへ送れる。下の「段の answer」)、その下に note (一言。小さく)、その下に children を
//     1 段下げて出す。ID と題は url を開く (一覧の行と同じく http と https だけ。
//     ダブルクリックの 2 回目は数えない)。ID の無い行 (item など) は題を太字にする。
//   - 札: ticket は status (色は tickets の行と同じ)、pr は state と ci (prs の行と同じ)。item には状態の札を出さない。who は枠だけの muted
//     の札。id・url・status・state・ci・who が無い・空なら、そのリンク・札を出さない (子がチケットを切る前の行など)。
//   - 字下げ: 根の行から 1 段ずつ下げ、3 段まで (4 段目からは 3 段目と同じ字下げで、線も引かない)。字下げには、親の印の欄のまん中に
//     縦の線を引き、子の行の印の欄へ短い横の線を出す (最後の子で縦の線を止める。色は theme の border)。
//   - 開け閉め: steps か children を持つ ticket の行の印の欄に ▸ (畳んである)・▾ (開いている) を出し、押すと開け閉めする (ダブルクリック
//     の 2 回目は数えない)。初めは、status が Done か Canceled (大文字小文字を問わない。Cancelled も) で、下 (自分の steps と、深さを
//     問わず children) に動いているもの (state が active か blocked の段・state が open か draft の PR) が無い行を畳み、ほかは開く。
//     段の state は段の札と同じく字のまま比べる ("Active" は動いているとみない)。畳んだ行は上の段だけを出し、その後ろに、下 (深さを
//     問わず) の PR の数を state ごとに足す (例「PR 3 本 merged」「PR 2 本 merged・1 本 closed」。open・draft・merged・closed の順で、
//     知らない state は出てきた順に字のまま、state の無い PR は数だけ。大文字小文字の違う同じ state は 1 つに数え、初めに出てきた字で
//     出す。PR が無ければ足さない)。手で開け閉めした行は、節の畳みと同じくペインの中で覚え (鍵は節の id と行の id。id の無い行は木の
//     中の位置。同じ id の行が木に 2 つあれば一緒に開け閉めする)、panel.json を書き直しても残し、version が変わると初めの形に戻す。
//   - related が true の根の行は関連の行 (束ねていないチケット・親の無い PR)。ほかの根の行 (ふつうは 1 つ目がハブのチケットで、子の
//     チケットはその children) を上から順に出した下に点線を引き、その下に「関連」の字と並べて出す (ほかの根の行が無ければ点線は
//     引かない)。根でない行の related は見ない (その場に出す)。
//   - rows が空・配列でないなら「(行はありません)」と出す。行・段・子が形の違うもの (null など) でも落ちず、中身の無い行として出す。
//
// Q&A (type "qa"): ユーザーの問いと、ハブの答えを 1 つの項目にして、問いごとに開け閉めする (アコーディオン)。答えがほかの子の返答に
//   紛れないように、ハブはユーザーに問われたら答えをこの節の項目に書く。節の形は { type: "qa", id, title, items: [<項目>…], collapsed }、
//   項目の形は { id, q, at, a, open }:
//   - id: 項目の名前 (空でない文字列)。開け閉めを覚える鍵と、消す印の鍵 (下の「節を消す印」)。ハブは、panel の節の id ともほかの項目の id
//     とも重ならない値を付ける (例 "qa-1123-1412")。
//   - q: ユーザーの問い (素の字。長ければ折り返す)。頭に「Q.」を付け、太字で出す。
//   - at: 時刻の字 (例 "11/23 14:12")。項目の頭の行の右に、小さく薄く出す。無い・空なら出さない。
//   - a: 答え (markdown)。markdown の節の text と同じに出す (上の「リンク」と「ミニ絵」・入れ子の箇条書き。ミニ絵を大きく見る小窓の題は
//     「Q. <問い>」)。無い・空 (空白だけも) なら、薄い字で「(まだ答えていない)」と出す。
//   - open: 初めに開くか。boolean でなければ、items の 1 つ目だけを開き、ほかは畳む (ハブは新しい問いを items の頭に足す)。
//   ほかの節と同じカード (節の頭の ▸・▾ と節の ×) の中に、items を panel.json の順に縦に並べ、節の題の後ろに、出している項目の数を
//   「(N)」で足す (消す印で隠した項目は数えない)。項目は枠のついた小さなカードで、頭の行に開け閉めの印 (▸・▾)・「Q. <q>」・時刻・
//   項目の × を並べる。頭の行を押すと開け閉めする (ダブルクリックの 2 回目は数えない。× と「戻す」を押しても開け閉めしない)。開いた
//   項目は、頭の行の下に答えを 1 段 (印の欄と間の幅) 下げて出す。手で開け閉めした形は、work の行と同じくペインの中で覚え (鍵は節の id と
//   項目の id。id の無い項目は items の中の位置)、panel.json を書き直しても残し、version が変わると初めの形に戻す。items が空・配列で
//   ないなら「(項目はありません)」と出す。形の違う項目 (null・数など) でも落ちず、中身の無い項目として出す。
//
// 節を消す印: まとめのペイン (role が summary か無い) の、id (空でない文字列) のある節の右上に「×」を出す。押すと印が付き (枠が warn の
//   点線になり、題に取り消し線が引かれ、中身が薄くなって「次の更新で消える」と出る)、「戻す」を押すと外れる (ダブルクリックの 2 回目は
//   数えない)。問いのペインには出さない。Q&A の節の項目 (id のあるもの) にも、項目の頭の行の右に同じ「×」を 1 つずつ出す。押すと項目の
//   枠が warn の点線になり、問いに取り消し線が引かれ、答えが薄くなって「次の更新で消える」と出る (「戻す」で外れる)。
//   印は mod が panel.json の隣のファイルに書く。名前は panel.json の名前の .json を .dismiss.json に替えたもの (panel.json → panel.dismiss.json):
//     { "file": "panel.json", "dismissed": [{ "id": "<節の id>", "title": "<印を付けたときの題>", "at": "<印を付けた時刻 (ISO 8601 の UTC)>",
//       "base": "<印を付けたときの panel.json の指紋>" }] }
//   項目の印も同じ dismissed に、項目の id で書く。形は節の印に、どの節の項目かの section (節の id。節に id が無ければ空の字) を足したもの:
//     { "id": "<項目の id>", "title": "<印を付けたときの q>", "at": "…", "base": "…", "section": "<節の id>" }
//   panel.json はハブだけが書き、印のファイルは mod だけが書く (ハブは読むだけ)。写しのペインどうしの書き違いは writeTextFile の expected
//   (読んだときの中身と今の中身が合うときだけ書く) で防ぎ、合わずに断られたら読み直してやり直す。
//   印を付けた後に panel.json の中身が変わったら、その節 (項目の印なら、その項目) を出さない。変わったかは、キーの順と空白によらない指紋
//   (base) で比べる (印のファイルの書き込みや、同じ中身での書き直しは変わったと数えない。ConvertTo-Json の @{} はキーの順が書くたびに
//   替わりうる)。ハブが外さずに同じ id で書き続けても、印がある間は出さない。panel.json の節の id にも Q&A の節の項目の id にも無くなった
//   id の印は、mod が panel.json を読めた読み直しのたびに印のファイルから外す (panel.json が無い・読めない間は外さない)。印はファイルに
//   残るので、まとめのペインを開き直しても (herdr-app を上げ直しても) 同じに出す (印の後に panel.json が変わっていれば出さず、変わって
//   いなければ印つきで出す)。印は id だけで引く (節の印と項目の印を分けない) ので、節と項目の id を重ねない。
//   ハブがすること: panel.json を書く前に印のファイルを読み (無ければ印は無い)、dismissed の id を、節の id と Q&A の節の項目の id の両方に
//   当てて外して書く。同じ話を続けて出すなら別の id (next-2 など) にする (印の付いた id を使う間は出ない)。印のファイルは書き換えない
//   (要らなくなった印は、節や項目を外せば mod が消す)。
//
// 段の answer: チケット・進み具合・PR の木 (type "work") の行の段に answer があれば、その段を押せる札にし、押すとハブの端末へ answer を
//   送れる (ユーザーの番の段。解説動画の「見る」・ユーザーが手で確かめる段など。ユーザーが panel から「見た」「済んだ」をハブへ伝える)。段の形は
//   { label, state, answer } で、answer はそれだけで読める 1 行の字 (問いの answer と同じ。例 "TKT-n 解説動画 (短尺 2:41) -> 見た")。空白だけで
//   なく、改行と制御文字を含まない字のときだけ押せる札にし、ほかの値 (無い・空・字でない・改行を含む) の段は今までどおり押せない。flow の節の
//   段の answer は見ない。問いのペインは木を出さないので、押せる札も、押した印のファイルの読み書きも無い。
//   - 札: 押せる段に、ポインタの形・hover (地を raised に)・ヒントを付ける。色・印 (✓・●・■)・点滅は今までの札のまま。
//   - 押す (①): 押した印 (下) を書き、その行の段の並びのすぐ下に、枠のついた小さな確かめ「「<answer>」を送る?」と「送る」「やめる」を出す (②)。
//     押した段が 2 つあれば、段の順に 1 つずつ出す。もう一度その段を押すと「やめる」と同じ。ダブルクリックの 2 回目は数えない。
//   - 「送る」: 問いの「送信」と同じ手 (下の「答えの送り方」。クリップボード → props.terminal の端末に terminal.paste → hc keys で Enter を
//     1 回) で answer を送る。Enter まで押せたら印の sent を true にし、確かめの代わりに「「<answer>」を送った」と出して、段を押せない札に戻す
//     (印が外れるまで。下)。送れなかったら (クリップボードに入れられない・props.terminal が無い・端末が無い・端末が確かめの画面で止まっている・
//     Enter を押せない)、確かめの中にわけを出し、印は sent が false のまま残す (もう一度「送る」か「やめる」)。送っている間は、同じペインのどの段の
//     「送る」も問いの「送信」も押せず、送っている段は押しても閉じない。ほかの写しのペイン (問いのペインなど) が送っている間に押すと、送らずに
//     わけを出す (1 つずつ送る。下の「答えの送り方」)。
//   - 「やめる」: 何も送らず、印を外して確かめを閉じる。
//   押した印は mod が panel.json の隣のファイルに書く。名前は panel.json の名前の .json を .steps.json に替えたもの (panel.json →
//   panel.steps.json)。押したときに書くので、確かめの「送る」を押さずに置いた印もハブが読める:
//     { "file": "panel.json", "pressed": [{ "section": "<work の節の id>", "row": "<行の名前>", "label": "<段の label>",
//       "answer": "<押したときの answer>", "at": "<押した時刻 (ISO 8601 の UTC)>", "sent": false }] }
//   - section は work の節の id (id の無い節は空の字)。row は行の id (数なら字にしたもの)。id の無い・空の行は、木の中の位置を "@" の後ろに
//     書いた字 (rows の何番目から children の何番目へ、0 から数えて . でつなぐ。例 rows[0].children[2] は "@0.2")。label は段の label (無い段は
//     空の字)。印は section・row・label・answer の組で引く (同じ組の段が 2 つあれば、一緒に押される)。
//   - 書き方は消す印と同じ: 印のファイルは mod だけが書き、ハブは読むだけ。写しのペインどうしの書き違いは writeTextFile の expected で防ぎ、
//     断られたら読み直してやり直す。押した見た目はすぐ変え、書けなければファイルの中身に戻してわけを出す。印はファイルに残るので、まとめの
//     ペインを開き直しても、写しのペインでも同じに出る。
//   - panel.json の work の節に、同じ section・row・label で answer の同じ段が無くなった印は、mod が panel.json を読めた読み直しのたびに外す
//     (段や行が消えた・answer が外れた・替わった・id の無い行の位置が動いた。sent が true の印も同じ。panel.json が無い・読めない間は外さない)。
//   ハブがすること: panel.json を書く前に (消す印を読むのと同じ時に) 押した印のファイルを読み (無ければ印は無い)、sent が false の印を
//   「ユーザーがその answer を送った」とみなして、端末で answer が届いたときと同じに扱う。sent が true の印は端末に届いているので数えない (届いた
//   発言の方で扱う)。数えるのは、今の panel.json の、印の section と同じ id の work の節の木 (深さを問わず) に、label と answer の同じ段がある
//   印だけ (row は見なくてよい。無い印は、もう扱って answer を外した段のもので、まとめのペインが閉じている間は mod が外せずに残る)。扱ったら、
//   その段の answer を外し、state を done にして書く (mod がその印を外す)。印のファイルは書き換えない。この「段の answer:」の字の無い mod は
//   answer を読まず、段を押せないだけ (answer を書いても害は無い)。
//
// 文字の大きさ: どの role のペインも、上の行 (題・更新の時刻の行) の「− <今の %> +」で、panel (この mod) の文字だけを上げ下げする。
//   1 回で 10% ずつ、70%〜200%。% を押すと既定 (100%) に戻す (既定のときは押せない)。100% は、ここに書いた字の大きさの値
//   (本文 13・題 15・問いの題 14・節の題 13・markdown の本文 12・段の札 11・札 10・ボタン 12 など。この mod を書いたときの px) の
//   1.2 倍。字 (図の説明 caption も) と、字を囲む札・段の札・ボタンの高さ・余白・角が同じ倍率で変わる。変えないもの: カードと一覧の
//   余白・間、図そのもの (image の節の絵と marks。ペインの幅に合わせ、marks の label の字も図の倍率のまま)、「− % +」の
//   組 (いつも 100% の大きさ。押しても組の幅が変わらず、ボタンがポインタの下から動かないように)。markdown の中の見出し (#) の大きさは
//   TextView が決める (倍率に従うかは試していない。本文と箇条書きは親の字の大きさに従う)。
//   値は shared の "pjp-hub-panel.textPercent" (整数の %。名前は MOD から作るので、MOD を書き換えずに写した写しは本物と同じ値を、
//   MOD を写しの名前に書き換えた pjp-hub-panel-try などは写しの値を使う) に置く。どの space の panel も、後から開いた問いのペインも同じ
//   大きさで出て、herdr-app を上げ直しても残る (localStorage はペインの写しごとで、問いのペインは開くたびに新しい写しになるので
//   使わない)。数でない値は既定、範囲の外は端に寄せ、整数に丸めて出す。
//   アプリの zoom (settings.json の zoom・app.zoom_in) は端末もほかの mod も大きくするので使わない (panel の px もアプリの zoom には従う)。
//   キーでは変えない (Ctrl+= などはアプリの zoom のキー)。上の行の組は折り返さずに右上に留まり、ペインが狭いときは、左の欄の中で
//   更新の時刻が次の行へ回り、題は縮んで折り返す。下の行の「入力欄に入れる」「送信」は、わけの字の横に入らなければ次の行へ回り、
//   2 つが並ばない幅では「送信」がさらに次の行へ回る (どちらも右寄せで、ボタンは縮めない)。
//
// 図の大きさと、大きく見る小窓:
//   panel のペインの図は、ペインの幅から一覧と節のカードの余白 (50 px) を引いた幅に合わせて縮め・大きくする (0.1〜2 倍。width と height の
//   比は保ち、marks も同じ倍率で置く)。ペインの境を動かすと追う。root の on_size_change の幅は、アプリの zoom (settings.json の zoom) を
//   掛けた後の logical px で、w()・h() に渡す px は zoom を掛ける前の px (描くと zoom 倍になる) なので、幅を settings().zoom で割って
//   から合わせる (herdr-app の release notes の図も width / settings().zoom。割らないと、zoom 1.4 で図が 1.4 倍に描かれ、ペインの端で
//   切れる)。図は panel の文字の % に従わない。2 倍で止めるのは、広いペイン (pane.zoom など) で図が縦に長くなり、ほかの節を押し出さないため。
//   図には pointer の形・hover・tooltip と、下の「クリックで拡大」の字を付ける。flow の marks の輪 (ring.svg) は、倍率を 2 の 1/4 乗の
//   刻みに丸めた大きさで描く (svg() は描く大きさごとに絵を作って持つので、ペインの境を動かしても作る絵の数を抑える。輪は矢印の中点を
//   通るように置くので、丸めても点は矢印に沿う)。
//   図をクリックすると、この mod を dialog の小窓 (窓の幅の 92%・高さの 90%) で開き、props.image に図の節を渡す。小窓は panel.json を
//   読まず見張らず、図の題・図 (marks も)・図の説明だけを出し、図を小窓の図の欄に縦横とも収める (0.1〜4 倍。欄の大きさも zoom で割る)。
//   地は theme の popover (herdr-app の dialog の mod と同じ)。閉じるのは Esc・「閉じる」・図の欄のクリック (ダブルクリックの 2 回目は
//   数えない。図をダブルクリックしても、開いた小窓がすぐ閉じない。外のクリックと Esc では herdr-app も閉じる)。開いたときに小窓の
//   handle に focus する (Esc を受けるため)。開く mod の名前は MOD から取るので、写しを試すときは MOD を写しの名前に書き換える (書き
//   換えないと写しの図から本物の pjp-hub-panel の小窓が開く。shared の名前と ring.svg のパスも写しのものになる)。SVG の図を大きく
//   したときの細かさは herdr-app の画像の読み込み次第 (GPUI 本家の img() は、SVG を SVG の width・height の 2 倍で 1 回だけ絵にして、
//   引き伸ばして描く。それより大きく描くとにじむ)。
//
// panel.json の形:
//   { version, title, updated,
//     questions: [{ id, short, title, body (markdown), options: [{ label, desc, recommended, answer }] }],
//     sections: [
//       { type: "work", id, title, rows: [...], collapsed },   (チケット・進み具合・PR の木。行の形は上の「チケット・進み具合・PR の木」、
//                                                              段の answer は上の「段の answer」)
//       { type: "qa", id, title, items: [{ id, q, at, a (markdown), open }], collapsed },   (ユーザーの問いと答え。上の「Q&A」)
//       { type: "markdown", id, title, text (リンクは上の「リンク」、絵だけの行は上の「ミニ絵」), collapsed },
//       { type: "flow", id, title, rows: [{ label, sub, steps: [{ label, state: "done"|"active"|"todo"|"blocked" }] }] },
//       { type: "tickets", id, title, rows: [{ id, title, url, status, note }] },   (チケットの一覧。上の「チケットと PR の一覧」)
//       { type: "prs", id, title, rows: [{ id, title, url, state, ci, note }] },    (PR の一覧)
//       { type: "image", id, title, src (下の「図の置き場所」の下のパス。例 "TKT-n/x.svg"), width, height, caption,
//         marks: [{ kind: "flow", x1, y1, x2, y2, speed, color }      (x1,y1 から x2,y2 へ一方向に流れる点。speed は px/s)
//                 | { kind: "pulse", x, y, w, h, radius, period, color } (点滅する枠)
//                 | { kind: "dot", x1, y1, x2, y2, period, size, color }  (行って戻る点)
//                 | { kind: "label", x, y, text, size, color }] } ] }
//   marks の座標は画像の px (width・height と同じ空間) で、図と同じ倍率で置く。color は "#rrggbb" か
//   theme の名前 (accent・ok・warn・blocked・muted など)。width・height が数でない・0 以下なら 520×300 とみる。
//   図の置き場所: herdr-app の home の pjp-hub-panel-media/ (Windows は %USERPROFILE%\.config\herdr-app\pjp-hub-panel-media)。ミニ絵の図も同じ。
//   会話ごとにフォルダを切る (例 TKT-n/)。image() は home の外 (scratchpad など) を読めない。mod のフォルダには置かない
//   (dotfiles が配るフォルダで、書き換えると mod も読み直す)。src が "mods/" で始まれば home からのパスとして読む。
//   同じ名前で書き換えた図は描き直らない (herdr-app がパスで覚えている)。図を変えるときは名前を変える (例 x-2.svg)。
//   SVG の font-family は名前を引用符で囲む ('Yu Gothic UI', 'Meiryo UI', Meiryo, sans-serif)。囲まないと日本語を
//   混ぜた行が BIZ UDGothic などに落ち、~ が ‾ に、\ が ¥ に化ける。色は暗い theme 向きに描く (SVG は theme に従わない)。
//
// 答えの送り方: 問いの答えは問いの順に 1 つ 1 行にし、改行 (LF) でつないでクリップボードに入れてから、端末に 1 回で貼る (terminal.paste)。
// 「送信」(このペインで Enter も) は、貼ったあと hc keys で Enter を 1 回押す。段の answer (上の「段の answer」) の「送る」も同じ手で、1 行を
// 貼って Enter を 1 回押す。改行を含む文が Claude Code の入力欄に 1 つの入力として入るのは、terminal.paste が bracketed paste で渡すことを
// 当てにしている (herdr-app の文書には書かれていない。渡らなければ、Claude Code は 1 行目で送ってしまう)。panel の下の行にも、答えを 1 行ずつ
// 出す。hc send は使わない (エージェントの端末への hc send は <hc from=…> の札が付き、ユーザーの発言と見分けられなくなる)。
//   - 貼る前に hc get --json で端末を見て、エージェントが人を待っている (status が blocked。許可・問いの画面) なら、クリップボードにも入れずに
//     止めてわけを出す (貼った字は画面に無視されるか選択肢を選び、Enter は選ばれている選択肢を確定しうる。hc send も blocked の端末には送らない。
//     「入力欄に入れる」も同じ)。貼った後の hc get で blocked になっていれば、Enter を押さない。hc get を読めなければ止めない (今までどおり)。
//   - 写しのペイン (まとめと問いのペインなど) が同時に送ると、クリップボード・貼り付け・Enter が入り混じる。送っている間は shared の
//     "pjp-hub-panel.sendingUntil" (名前は MOD から作る) にこの時刻 (Date.now() の ms) までは送らないという値を置き、ほかの写しはその時刻まで
//     送らずにわけを出す。送り終えたら 0 に戻す (herdr-app が送る途中で落ちても、30 秒で送れるようになる)。
// ファイルのフォルダを見張り、書き換わったら読み直す (version が変わったら、選んだものと段の確かめのわけの字を消す。押した印は段が同じなら残す)。

import { View, div, image, svg } from "gpui-kit";
import { writeTextFile } from "herdr"; // 節を消す印・段の押した印のファイル (panel.json の隣) を書く
import { v_flex, h_flex, TextView } from "gpui-base";
import { exec, hc, run, props, theme, readTextFile, watchFolder, nextCommand, focused, panes, shared, setShared, settings, openOverlay, closeOverlay, appHome } from "herdr";

const MOD = "mods/pjp-hub-panel";
const NAME = MOD.slice(MOD.lastIndexOf("/") + 1); // この mod の名前
// この mod のペインか。写し (試しに置く pjp-hub-panel-try・mod.clone の pjp-hub-panel-copy など) は名前の後ろに -<何か> が付く
const isOwnMod = (name) => typeof name === "string" && (name === NAME || name.startsWith(`${NAME}-`));
const ROLES = ["summary", "questions"];
const MEDIA = "pjp-hub-panel-media"; // 図の置き場所。herdr-app の home の下で、mod のフォルダの外
const dirOf = (p) => p.replace(/[\\/][^\\/]*$/, "");
// #rrggbb に不透明度 (16 進の 2 桁) を足す。ほかの形 (#rgb・#rrggbbaa) は足すと色にならないので null (塗らない)
const withAlpha = (color, aa) => (/^#[0-9a-fA-F]{6}$/.test(color ?? "") ? `${color}${aa}` : null);
// panel の文字の大きさ (上の行の -・%・+)。shared に整数の % で置き、どの写しも同じ大きさで出す
const ZOOM_KEY = `${NAME}.textPercent`;
const ZOOM = { def: 100, min: 70, max: 200, step: 10 };
const TEXT_BASE = 1.2; // 100% の倍率。字の大きさの値 (本文 13 など。この mod を書いたときの px) の 1.2 倍で出す
// shared の値を % にする。数でない (無い・文字・NaN・Infinity) は既定、範囲の外は端へ寄せ、整数に丸める
const zoomOf = (v) => (typeof v === "number" && Number.isFinite(v) ? Math.min(ZOOM.max, Math.max(ZOOM.min, Math.round(v))) : ZOOM.def);
// 1 刻み上げた (dir が 1)・下げた (-1) %。刻みの途中の値 (105 など) からは次の刻み (110・100) へ
const zoomStep = (z, dir) =>
  dir > 0 ? Math.min(ZOOM.max, (Math.floor(z / ZOOM.step) + 1) * ZOOM.step) : Math.max(ZOOM.min, (Math.ceil(z / ZOOM.step) - 1) * ZOOM.step);
// 既定の倍率だけを掛けた大きさ (panel の % に従わない)。「− % +」の組に使い、押しても組の幅と高さが変わらず、ボタンがポインタの下から動かない
const atBase = (n) => Math.round(n * TEXT_BASE * 10) / 10;
const BAR_H = atBase(22) + 4; // 「− % +」の組の高さ (区切りの高さに、内の余白と枠の上下 1 px ずつを足したもの)
// 図の倍率。panel のペインの図は、ペインの幅から pad (一覧の p(12) の左右と、節のカードの p(12) の左右・枠 1 px の左右) を引いた幅に
// 合わせる。大きくするのは max 倍まで (広いペインで図が縦に長くなり、ほかの節を押し出さないように。もっと大きく見るのは小窓)。
// min は、とても狭いペインでも 0 や負の大きさを渡さないための下限
const PIC = { min: 0.1, max: 2, pad: 24 + 26 };
// 図を大きく見る小窓。窓に対する割合の dialog で開き、図は小窓の図の欄に縦横とも収める (max 倍まで)
const BIG = { kind: "dialog", width: 0.92, height: 0.9, max: 4 };
const BIG_FAIL = "図を大きく見られない"; // 小窓を開けなかったときのわけの頭
const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));
// 図の幅・高さ。数でない・0 以下は既定 (520×300)
const sizeOr = (v, d) => (typeof v === "number" && Number.isFinite(v) && v > 0 ? v : d);
// アプリの zoom (settings.json の zoom)。読めない・数でない・0 以下は 1。on_size_change の大きさは zoom を掛けた後の logical px で、
// w()・h() に渡す px は zoom を掛ける前の px (描くと zoom 倍になる) なので、大きさを zoom で割ってから図の倍率を決める
const appZoom = () => {
  let z;
  try {
    z = settings()?.zoom;
  } catch {
    z = undefined;
  }
  return typeof z === "number" && Number.isFinite(z) && z > 0 ? z : 1;
};
// 大きく見る小窓に渡された図 (props.image)。オブジェクトでなければ null (ふつうの panel)
const bigOf = (p) => (p?.image && typeof p.image === "object" && !Array.isArray(p.image) ? p.image : null);

// ---- 節を消す印・リンク・チケットと PR の一覧 (頭のコメントの「節を消す印」「リンク」「チケットと PR の一覧」) ----
// 印のファイル: panel.json の隣に、名前の末尾の .json を .dismiss.json に替えて置く (.json で終わらなければ足す)
const dismissPathOf = (file) => file.replace(/(\.json)?$/i, ".dismiss.json");
const baseName = (p) => p.replace(/^.*[\\/]/, "");
// 消す印を付けられる節の名前。id が空でない文字列の節だけ (印のファイルの dismissed の行も同じ形で読む)
const markKey = (s) => (typeof s?.id === "string" && s.id !== "" ? s.id : null);
// 値を字にする (無い・null は空の字)
const str = (v) => (v == null ? "" : typeof v === "string" ? v : String(v));
// キーを並べ替えた JSON の字。キーの順と空白によらず panel.json の中身を比べるため (ConvertTo-Json の @{} はキーの順が書くたびに替わりうる)
const canon = (v) =>
  Array.isArray(v)
    ? `[${v.map(canon).join(",")}]`
    : v !== null && typeof v === "object"
      ? `{${Object.keys(v)
          .sort()
          .map((k) => `${JSON.stringify(k)}:${canon(v[k])}`)
          .join(",")}}`
      : (JSON.stringify(v) ?? "null");
// panel.json の中身の指紋 (canon の字の cyrb53。53 bit を 16 進で)。印を付けたときと今とで、中身が変わったかを比べるだけに使う
const fingerprint = (data) => {
  const s = canon(data);
  let h1 = 0xdeadbeef;
  let h2 = 0x41c6ce57;
  for (let i = 0; i < s.length; i++) {
    const ch = s.charCodeAt(i);
    h1 = Math.imul(h1 ^ ch, 2654435761);
    h2 = Math.imul(h2 ^ ch, 1597334677);
  }
  h1 = Math.imul(h1 ^ (h1 >>> 16), 2246822507);
  h1 ^= Math.imul(h2 ^ (h2 >>> 13), 3266489909);
  h2 = Math.imul(h2 ^ (h2 >>> 16), 2246822507);
  h2 ^= Math.imul(h1 ^ (h1 >>> 13), 3266489909);
  return (4294967296 * (2097151 & h2) + (h1 >>> 0)).toString(16);
};
// 印のファイルの中身 (id → 印)。無い・読めない・形の違うものは印の無いものとみる (次に書くときに正しい形で書き直る)
const parseMarks = (text) => {
  const marks = new Map();
  let o = null;
  try {
    o = text == null ? null : JSON.parse(text);
  } catch {
    o = null;
  }
  for (const e of Array.isArray(o?.dismissed) ? o.dismissed : []) {
    const id = markKey(e);
    if (id == null || marks.has(id)) continue;
    // 項目の印 (Q&A の節の項目) は、どの節の項目かの section を持つ。節の印は持たない (持たないまま書き戻す)
    const m = { id, title: str(e.title), at: str(e.at), base: str(e.base) };
    if (typeof e.section === "string") m.section = e.section;
    marks.set(id, m);
  }
  return marks;
};
const marksJson = (file, marks) => `${JSON.stringify({ file: baseName(file), dismissed: [...marks.values()] }, null, 2)}\n`;
// http・https の URL (host のあるもの) ならその字 (前後の空白を除く)、ほかは null。user@host の形・空白や制御文字を含むものも null。
// リンクと一覧の行の url は、これを通ったものだけを開く
const webUrl = (v) => {
  if (typeof v !== "string") return null;
  const u = v.trim();
  return /^https?:\/\/[^\s/?#@\\]+(?:[/?#]\S*)?$/i.test(u) && !/[\u0000-\u001f\u007f]/.test(u) ? u : null;
};
// 状態の札の色 (colors() か theme() の名前)。知らない値は muted
const TICKET_COLOR = { todo: "muted", "in progress": "working", "in review": "accent", done: "ok", canceled: "dim", cancelled: "dim", blocked: "blocked" };
const PR_COLOR = { open: "ok", draft: "muted", merged: "ansi5", closed: "blocked" };
const CI_CHIP = { pass: ["ok", "CI ✓"], fail: ["blocked", "CI ✗"], pending: ["working", "CI …"] };

// ---- チケット・進み具合・PR の木 (頭のコメントの「チケット・進み具合・PR の木」) ----
// indent: 線を引いて字下げする段の数 (それより深い行は、その段と同じ字下げ)。gap: 兄弟の行の間 (px。一覧の行の間と同じく % に従わない)
const TREE = { indent: 3, gap: 8 };
const CLOSED_STATUS = new Set(["done", "canceled", "cancelled"]); // 初めに畳んでよい status (小文字にして比べる)
const PR_ORDER = ["open", "draft", "merged", "closed"]; // 畳んだ行に足す PR の数の並び (知らない state はこの後ろ)
// 形の違う行・段 (null・数・文字・配列) は中身の無いものとみる
const objOr = (v) => (v !== null && typeof v === "object" && !Array.isArray(v) ? v : {});
const listOf = (v) => (Array.isArray(v) ? v : []);
// 段の answer (頭のコメントの「段の answer」)。空白だけでない 1 行の字 (改行・制御文字を含まない) ならその字のまま、ほかは null (押せない段)
const answerOf = (v) => (typeof v === "string" && v.trim() !== "" && !/[\u0000-\u001f\u007f\u0085\u2028\u2029]/.test(v) ? v : null);
// 段の札 (step) に渡す形。label は字にする (形の違う段でも落ちない)。answer は押せる字か null
const stepOf = (v) => {
  const o = objOr(v);
  return { label: o.label == null ? "" : str(o.label), state: o.state, answer: answerOf(o.answer) };
};
// 木の行の名前 (開け閉めを覚える鍵と、押した印の row)。行の id (数なら字にしたもの)。id の無い・空の行は木の中の位置 (path。rows の何番目から
// children の何番目へ、0 から数えて . でつないだ字) の頭に "@" を付けたもの
const rowName = (r, path) => {
  const rid = str(r.id);
  return rid !== "" ? rid : `@${path}`;
};
// 行の種類。無い・空は ticket、知らない値は item (大文字小文字を問わない)
const kindOf = (r) => {
  const k = str(r.kind).trim().toLowerCase();
  return k === "" ? "ticket" : k === "ticket" || k === "pr" ? k : "item";
};
const prStateOf = (r) => str(r.state).trim();
// 下 (自分の steps と、深さを問わず children) に動いているもの (active か blocked の段・open か draft の PR) があるか。
// 段の state は段の札 (step) と同じく字のまま比べ、PR の state は札の色と同じく大文字小文字を問わない
const isMoving = (r) =>
  listOf(r.steps).some((st) => {
    const s = objOr(st).state;
    return s === "active" || s === "blocked";
  }) ||
  listOf(r.children).some((ch) => {
    const o = objOr(ch);
    return (kindOf(o) === "pr" && ["open", "draft"].includes(prStateOf(o).toLowerCase())) || isMoving(o);
  });
// 下 (深さを問わず) の PR を state ごとに数える。鍵は小文字にした state で、字は初めに出てきたもの。出てきた順に並ぶ
const tallyPrs = (r, out = new Map()) => {
  for (const ch of listOf(r.children)) {
    const o = objOr(ch);
    if (kindOf(o) === "pr") {
      const st = prStateOf(o);
      const k = st.toLowerCase();
      const e = out.get(k);
      if (e) e.n++;
      else out.set(k, { label: st, n: 1 });
    }
    tallyPrs(o, out);
  }
  return out;
};
// 畳んだ行に足す字 (「PR 2 本 merged・1 本 closed」)。PR が無ければ空の字
const prSummary = (r) => {
  const t = tallyPrs(r);
  if (t.size === 0) return "";
  const keys = [...PR_ORDER.filter((k) => t.has(k)), ...[...t.keys()].filter((k) => k !== "" && !PR_ORDER.includes(k)), ...(t.has("") ? [""] : [])];
  return `PR ${keys.map((k) => (k === "" ? `${t.get(k).n} 本` : `${t.get(k).n} 本 ${t.get(k).label}`)).join("・")}`;
};

// ---- 段の押した印 (頭のコメントの「段の answer」) ----
// 押した印のファイル: panel.json の隣に、名前の末尾の .json を .steps.json に替えて置く (.json で終わらなければ足す)
const stepsPathOf = (file) => file.replace(/(\.json)?$/i, ".steps.json");
// 押した印の鍵 (work の節の id・行の名前・段の label・answer の組)
const pressKey = (section, row, label, answer) => [section, row, label, answer].join("\u0000");
// 押した印のファイルの中身 (鍵 → 印)。無い・読めない・形の違うもの (section・row・label が字でない・answer が押せる字でない) は印の無いものと
// みる (次に書くときに正しい形で書き直る)。sent は true のときだけ true。同じ鍵の印が 2 つあれば前のもの
const parsePresses = (text) => {
  const marks = new Map();
  let o = null;
  try {
    o = text == null ? null : JSON.parse(text);
  } catch {
    o = null;
  }
  for (const v of Array.isArray(o?.pressed) ? o.pressed : []) {
    const e = objOr(v);
    const { section, row, label, answer } = e;
    if (typeof section !== "string" || typeof row !== "string" || typeof label !== "string" || answerOf(answer) == null) continue;
    const k = pressKey(section, row, label, answer);
    if (!marks.has(k)) marks.set(k, { section, row, label, answer, at: str(e.at), sent: e.sent === true });
  }
  return marks;
};
const pressJson = (file, marks) => `${JSON.stringify({ file: baseName(file), pressed: [...marks.values()] }, null, 2)}\n`;
// 押した印を外すかを決めるときの、panel.json にある押せる段の鍵 (work の節の木を深さを問わずたどる。行の名前は木を描くときと同じ)
const liveSteps = (secs) => {
  const keys = new Set();
  const walk = (sec, rows, path) =>
    listOf(rows).forEach((v, i) => {
      const r = objOr(v);
      const p = path === "" ? String(i) : `${path}.${i}`;
      const row = rowName(r, p);
      for (const st of listOf(r.steps)) {
        const { label, answer } = stepOf(st);
        if (answer != null) keys.add(pressKey(sec, row, label, answer));
      }
      walk(sec, r.children, p);
    });
  for (const s of secs) if (s?.type === "work") walk(markKey(s) ?? "", s.rows, "");
  return keys;
};

// 印のファイルの種類 (節を消す印と、段の押した印)。what はわけの頭に出す名前、pathOf は panel.json のパスから印のファイルのパス、parse は中身の
// 字 (無ければ null) から印 (鍵 → 印)、json は印から書く字
const DISMISS = { what: "消す印", pathOf: dismissPathOf, parse: parseMarks, json: marksJson };
const PRESS = { what: "押した印", pathOf: stepsPathOf, parse: parsePresses, json: pressJson };

// ---- 答えの送り方 (頭のコメントの「答えの送り方」) ----
// 送っている印: shared に、この時刻 (Date.now() の ms) まで、ほかの写しのペインは送らない、という値を置く (送り終えたら 0)。写しのペイン (まとめと
// 問いのペインなど) が同時に送ると、クリップボード・貼り付け・Enter が入り混じる。herdr-app が送る途中で落ちても、時刻を過ぎれば送れる
const SEND_KEY = `${NAME}.sendingUntil`;
const SEND_LOCK_MS = 30000;
// hc get --json の出力から、端末のエージェントが人を待っている (status が blocked。許可・問いの画面) かを読む。status は平らな字でも
// { state, … } の形でも読む (pjp-spaces と同じ)。読めなければ false
const blockedOf = (out) => {
  try {
    const j = JSON.parse(out);
    return (typeof j?.status === "string" ? j.status : j?.status?.state) === "blocked";
  } catch {
    return false;
  }
};

// ---- Q&A (頭のコメントの「Q&A」) ----
// Q&A の節の項目。形の違う項目 (null・数など) は中身の無い項目とみる。i は items の中の位置 (id の無い項目の鍵と、初めの開け閉めに使う)
const qaItemsOf = (s) => listOf(s?.type === "qa" ? s.items : null).map((v, i) => ({ it: objOr(v), i }));
// 印を外すかを決めるときの、panel.json にある id (節の id と、Q&A の節の項目の id)
const liveIds = (secs) => {
  const ids = new Set();
  for (const s of secs) {
    const k = markKey(s);
    if (k != null) ids.add(k);
    for (const { it } of qaItemsOf(s)) {
      const ik = markKey(it);
      if (ik != null) ids.add(ik);
    }
  }
  return ids;
};
// markdown として出す文 (markdown の節の text と、Q&A の節の項目の a)。ミニ絵の図を確かめるのに使う
const markdownTexts = (secs) => {
  const out = [];
  for (const s of secs) {
    if (s?.type === "markdown" && typeof s.text === "string") out.push(s.text);
    for (const { it } of qaItemsOf(s)) if (typeof it.a === "string") out.push(it.a);
  }
  return out;
};

// ---- ミニ絵 (頭のコメントの「ミニ絵」) ----
// 大きさ (この mod を書いたときの px。fs() で panel の % に従う) と、文とミニ絵の間 (px。% に従わない)
const MINI = { w: 200, h: 80, gap: 4 };
// 絵だけの行: 前の空白はいくつでもよく、後ろは空白だけ。説明に ] と改行を、パスに空白と括弧を含めない
const MINI_LINE = /^[ \t]*!\[([^\]\r\n]*)\]\(([^()\s]*)\)[ \t]*$/;
// コードの囲みの行 (``` か ~~~。前の空白は 3 つまで)。囲みの中の行は絵にしない
const FENCE = /^ {0,3}(`{3,}|~{3,})/;
// herdr-app の TextView (gpui-base 0.7.3〜0.10.0 の text/node.rs の render_list_item) の箇条書きの寸法: 1 段の幅は字の大きさの indent 倍で、
// 入れ子の並びを 1 段の幅ずつ下げる。項目の記号は、幅が 1 段の幅より狭くならない記号の欄に右寄せで置き (記号の右に 1 段の幅の gap 倍の空き)、
// 欄の後ろに字を置く
const LIST = { indent: 1.4, gap: 0.3 };
// 箇条書きの項目の行 (記号か番号の後ろに空白か行の終わり。番号は 9 桁まで)
const LIST_ITEM = /^( *)([-*+]|(\d{1,9})([.)]))( +|$)/;
// herdr-app の TextView (gpui-base 0.7.3〜0.10.0 の text/utils.rs の list_item_prefix) が箇条書きの記号の欄に置く記号。段 (1 から) で選び、
// 5 段目からは最後のもの
const BULLETS = ["•", "◦", "▪", "‣", "⁃"];
// 項目の記号の欄の字 (TextView と同じもの。後ろの空白は付けない)。番号は、並びの最初の番号 (start) から数えた番号 (start + 何番目) を、
// 1 段目は数、2 段目は A.、3 段目からは a. にする (Z. の次は AA.)。0 から始まる並びは、どの段も数
const prefixOf = (depth, item) => {
  if (item.kind === "." || item.kind === ")") {
    const n = item.start + item.ix;
    if (depth === 1 || item.start === 0) return `${n}.`;
    let label = "";
    for (let r = n; r > 0; r = Math.floor((r - 1) / 26)) label = String.fromCharCode((depth === 2 ? 65 : 97) + ((r - 1) % 26)) + label;
    return `${label}.`;
  }
  return BULLETS[Math.min(depth, BULLETS.length) - 1];
};
// 文の塊 (TextView に渡す行の並び) を、TextView と同じく頭から読んだ形: 最後の行 (空の行は飛ばす) の字の頭 (align: 箇条書きの段 (0 は
// 箇条書きの外) と、その項目の記号の欄の字) と、最後に開いている項目の並び (open)。字下げで入れ子と項目の終わりを決め、怠けた続きの行
// (字下げの無い続き) は見ない
const shapeOf = (lines) => {
  // 開いている項目: { ci: 字の頭の位置, mi: 記号の位置, kind: 記号か番号の区切り, num: 書いた番号の字, start: 並びの最初の番号,
  // ix: その並びの何番目 (0 から) }
  const stack = [];
  let fence = null;
  let res = { depth: 0, prefix: "" };
  for (const raw of lines) {
    const line = raw.replace(/\t/g, "    ");
    if (line.trim() === "") continue;
    const f = FENCE.exec(line);
    if (fence) {
      if (f && f[1][0] === fence[0] && f[1].length >= fence.length) fence = null;
    } else {
      const m = f ? null : LIST_ITEM.exec(line);
      if (m) {
        const mi = m[1].length;
        let prev = null;
        while (stack.length > 0 && mi < stack[stack.length - 1].ci) prev = stack.pop();
        const kind = m[3] ? m[4] : m[2];
        const same = prev && prev.kind === kind;
        const ci = m[5] === "" ? m[0].length + 1 : m[0].length;
        stack.push({ ci, mi, kind, num: m[3] ?? "", start: same ? prev.start : m[3] ? Number(m[3]) : 1, ix: same ? prev.ix + 1 : 0 });
      } else {
        const ind = line.length - line.trimStart().length;
        while (stack.length > 0 && ind < stack[stack.length - 1].ci) stack.pop();
        if (f) fence = f[1];
      }
    }
    const top = stack[stack.length - 1];
    res = { depth: stack.length, prefix: top ? prefixOf(stack.length, top) : "" };
  }
  return { align: res, open: stack };
};
// 中身の無い項目の行 (contextOf)。元の記号の位置と記号で書き、番号は、その項目の番号 (start + 何番目) を書いた番号の桁にそろえる (0 で
// 埋める)。桁が増えるなら書いた番号のまま (中身の無い項目は、記号の後ろ 1 つの位置が字の頭になり、桁が変わると中に入る字下げが変わる)
const emptyItem = (it) => {
  if (it.kind !== "." && it.kind !== ")") return `${" ".repeat(it.mi)}${it.kind}`;
  const n = String(it.start + it.ix);
  return `${" ".repeat(it.mi)}${n.length <= it.num.length ? n.padStart(it.num.length, "0") : it.num}${it.kind}`;
};
// 絵の行の後ろの文の頭に足す行 (頭のコメントの「ミニ絵」)。後ろの文の最初の行 (first) が項目の行なら、前の文の終わりで開いていた項目
// (open) のうち、その項目を入れる項目 (字の頭の位置がその項目の記号の位置より深くないもの) と、同じ並びの 1 つ前の項目 (記号か区切りが
// 同じとき) を、中身の無い項目の行にする。TextView は、中身の無い項目と、入れ子の並びから始まる項目に、記号も行も出さない
const contextOf = (open, first) => {
  const m = LIST_ITEM.exec(first.replace(/\t/g, "    "));
  if (!m) return [];
  const kind = m[3] ? m[4] : m[2];
  const keep = open.filter((it) => it.ci <= m[1].length);
  const next = open[keep.length];
  return [...keep, ...(next && next.kind === kind ? [next] : [])].map(emptyItem);
};
// ミニ絵の図のパスが決まりの外なら、そのわけ (中なら null)。決まりは image の節の src と同じ (pjp-hub-panel-media/ からのパス。"mods/" は home から)
const miniPathWhy = (p) => {
  if (p === "") return "図のパスが空";
  if (/^[a-zA-Z]:/.test(p) || /^[\\/]/.test(p)) return `絶対パスは使えない (pjp-hub-panel-media からのパスにする): ${p}`;
  if (/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(p)) return `URL は使えない (pjp-hub-panel-media に置いた図のパスにする): ${p}`;
  if (p.split(/[\\/]/).includes("..")) return `パスに .. は使えない: ${p}`;
  return null;
};
// markdown の節の text を、絵だけの行で切る。返すのは、文 { kind: "text", text, align } とミニ絵 { kind: "mini", alt, path, why, align } の
// 並び (中身が空白だけの文は除く)。文の text は TextView に渡す字で、頭の空の行を除き、絵の行の後ろなら contextOf の行を頭に足す。
// ミニ絵の align は、すぐ上の文の最後の行の字の頭 (すぐ上が絵なら、その絵と同じ。上に何も無ければ 0 段)
const splitMinis = (text) => {
  const parts = [];
  let buf = [];
  let fence = null;
  let shape = { align: { depth: 0, prefix: "" }, open: [] }; // すぐ上の文の形 (shapeOf)
  const flush = () => {
    const at = buf.findIndex((l) => l.trim() !== "");
    if (at >= 0) {
      const lines = [...contextOf(shape.open, buf[at]), ...buf.slice(at)];
      shape = shapeOf(lines);
      parts.push({ kind: "text", text: lines.join("\n"), align: shape.align });
    }
    buf = [];
  };
  for (const line of text.split(/\r?\n/)) {
    const f = FENCE.exec(line);
    const m = fence || f ? null : MINI_LINE.exec(line);
    if (fence) {
      if (f && f[1][0] === fence[0] && f[1].length >= fence.length) fence = null;
    } else if (f) {
      fence = f[1];
    }
    if (!m) {
      buf.push(line);
      continue;
    }
    flush();
    parts.push({ kind: "mini", alt: m[1], path: m[2], why: miniPathWhy(m[2]), align: shape.align });
  }
  flush();
  return parts;
};

export default class HubPanel extends View {
  init(_props, cx) {
    this.data = null;
    this.error = null;
    this.picked = {};
    this.collapsed = {};
    this.rowOpen = {}; // 木の行を手で開け閉めした形 (鍵は rowKey。無い行は初めの形)
    this.qaOpen = {}; // Q&A の項目を手で開け閉めした形 (鍵は qaKey。無い項目は初めの形)
    this.miniCheck = new Map(); // ミニ絵の図を確かめた結果 (図のパス → { why } か { ok })。panel.json を読み直すたびに作り直す
    this.probe = {}; // ミニ絵の物差しで測った記号の欄の幅 ("c:<記号の欄の字>" → zoom を掛けた後の logical px)
    this.status = "";
    this.busy = false;
    this.width = null;
    this.k = TEXT_BASE; // 字の倍率。render の頭で shared の % から決め直す
    // 印のファイルの控え: 節を消す印 (dm) と段の押した印 (sp)。cur は印 (鍵 → 印。印のファイルの中身に、まだ書いていない押下を当てたもの)、
    // pending はまだ書いていない押下 (op の並び)、error は読み書きできなかったわけ。markTail は 2 つのファイルの読み書きを 1 つずつ流す鎖、
    // hash は今の panel.json の指紋。linkMsg はリンクを開かなかったわけ (下の行に出したもの)
    this.dm = { kind: DISMISS, cur: new Map(), pending: [], error: null };
    this.sp = { kind: PRESS, cur: new Map(), pending: [], error: null };
    this.markTail = Promise.resolve();
    this.hash = null;
    this.linkMsg = null;
    // 段の answer: 押した段の確かめに出すわけ (押した印の鍵 → 字。「送っています…」と送れなかったわけ) と、送っている段の印の鍵
    this.stepMsg = {};
    this.sending = null;
    this.handle = cx.focus_handle();
    // 図を大きく見る小窓 (panel の図のクリックで、この mod が自分を開いたもの)。panel.json は読まず見張らず、渡された図だけを出す
    this.big = bigOf(props());
    if (this.big) {
      this.bigBox = null; // 図の欄の大きさ (on_size_change の logical px)
      this.bigClosed = false;
      // キーボードを取り、Esc を on_key_down でも受ける (dialog は herdr-app も Esc で閉じる)。開いた直後に focus が元のペインへ戻る
      // ことがあるので、少し後にもう一度取る (pjp-prefix の小窓・herdr-app の picker と同じ。端末に残ると Esc がその端末へ行く)
      this.handle.focus();
      cx.timer.after(50, () => {
        if (!this.bigClosed) this.handle.focus();
      });
      return;
    }
    const file = props()?.file;
    cx.spawn(async (cx) => {
      await this.reload(cx);
      if (!file) return;
      for (;;) {
        try {
          await watchFolder(dirOf(file));
        } catch (e) {
          this.error = `見張れない: ${e}`;
          cx.notify();
          return;
        }
        await this.reload(cx);
      }
    });
    cx.spawn(async () => {
      for (;;) {
        const cmd = await nextCommand();
        if (cmd === "focus") this.handle.focus();
      }
    });
  }

  async reload(cx) {
    const file = props()?.file;
    if (!file) {
      this.error = "props.file がありません";
      cx.notify();
      return;
    }
    // panel.json と印のファイルを読み終えてから、まとめて入れる (読む間に描き直されても、印で隠す節が一瞬出たり、印の見た目が
    // 戻ったりしない)。fresh はこの読み直しで読めた panel.json (無い・読めなければ null。印を外すのは読めたときだけ)
    let next = { data: this.data, hash: this.hash, error: null };
    let fresh = null;
    try {
      const text = await readTextFile(file);
      if (text == null) {
        next = { data: null, hash: null, error: `ファイルが無い: ${file}` };
      } else {
        fresh = JSON.parse(text);
        next = { data: fresh, hash: fingerprint(fresh), error: null };
      }
    } catch (e) {
      next.error = `読めない: ${e}`;
    }
    // ミニ絵の図を確かめる (読めた panel.json の markdown の節と Q&A の節の答えの分。問いのペインは節を出さないので見ない)
    const minis = fresh && this.role() !== "questions" ? await this.checkMinis(fresh) : null;
    // 印のファイル (消す印・押した印) も読み直し、panel.json から消えた節・項目・段の印を外して、panel.json の中身とまとめて入れる (印のファイル
    // の書き込みでも、ここへ来る)。読んでから入れるまでを、印のファイルの読み書きの鎖 (serial) の中でする。鎖の外で入れると、読んだ後に押下の
    // 書き込みが済んで、まだ書いていない押下から外れた印を古い中身で上書きし、押した見た目が戻る
    await this.serial(async () => {
      const marks = await this.syncMarks(this.dm, fresh, liveIds);
      const presses = await this.syncMarks(this.sp, fresh, liveSteps);
      if (fresh && this.data?.version !== fresh.version) {
        this.picked = {};
        this.status = "";
        this.collapsed = {};
        this.rowOpen = {};
        this.qaOpen = {};
        // 確かめのわけの字は消す (送っている段の「送っています…」は残す)
        const keep = this.sending != null && this.sending in this.stepMsg ? { [this.sending]: this.stepMsg[this.sending] } : {};
        this.stepMsg = keep;
        for (const s of fresh.sections ?? []) if (s.collapsed) this.collapsed[s.id] = true;
      }
      this.data = next.data;
      this.hash = next.hash;
      this.error = next.error;
      if (marks) this.takeMarks(this.dm, marks);
      if (presses) {
        this.takeMarks(this.sp, presses);
        // 外れた印の確かめのわけは消す (送っている段のものは残す)
        for (const k of Object.keys(this.stepMsg)) if (!this.sp.cur.has(k) && k !== this.sending) delete this.stepMsg[k];
      }
      if (minis) this.miniCheck = minis;
    });
    cx.notify();
  }

  // ミニ絵の図が有り、読めるかを確かめる (パスが決まりの外の絵は読まない)。SVG は readTextFile で読み、中身に <svg があるかも見る。
  // SVG でない図 (PNG など) は UTF-8 で読めないことがあるので、無い (null) ときだけ出せないとする
  async checkMinis(data) {
    const out = new Map();
    let base = null;
    try {
      base = appHome();
    } catch {
      base = null;
    }
    if (typeof base !== "string" || base === "") return out;
    for (const text of markdownTexts(Array.isArray(data?.sections) ? data.sections : [])) {
      for (const p of splitMinis(text)) {
        if (p.kind !== "mini" || p.why || out.has(p.path)) continue;
        const rel = this.imagePath(p.path);
        const svg = /\.svg$/i.test(p.path);
        let res;
        try {
          const t = await readTextFile(`${base.replace(/[\\/]+$/, "")}/${rel}`);
          if (t == null) res = { why: `図が無い: ${rel}` };
          else if (svg && !/<svg[\s>]/i.test(t)) res = { why: `SVG として読めない: ${rel}` };
          else res = { ok: true };
        } catch (e) {
          res = svg ? { why: `図を読めない: ${rel} (${e})` } : { ok: true };
        }
        out.set(p.path, res);
      }
    }
    return out;
  }

  // props.role。無い・空は null (1 つのペインに両方を出す)。知らない値はそのまま返す (render がわけを出す)
  role() {
    const r = props()?.role;
    return r == null || r === "" ? null : r;
  }

  // panel の文字の大きさ (%)。render のたびに shared から読む (どの写しが書いても、herdr-app がすべての mod を描き直す)
  zoom() {
    return zoomOf(shared(ZOOM_KEY));
  }

  // 字の大きさと、字を囲む札・ボタンの高さ・余白・角を、panel の倍率で引く。n はこの mod を書いたときの px (100% の 1/1.2)
  fs(n) {
    return Math.round(n * this.k * 10) / 10;
  }

  setZoom(z, cx) {
    setShared(ZOOM_KEY, z);
    cx.notify();
  }

  // この panel (root に track_focus した handle) が今キーボードを持つか。確かめられなければ false (送信は止めない)
  holdsKeyboard() {
    try {
      return this.handle.is_focused() === true;
    } catch {
      return false;
    }
  }

  // id のペインが、端末を持たない (terminal が null) この mod のペインなら、その id。確かめられなければ null
  ownPane(id) {
    if (!id) return null;
    const p = panes().find((x) => x.pane === id);
    return p && p.terminal == null && isOwnMod(p.mod) ? id : null;
  }

  // 選んだ答え。問いの順に 1 つ 1 行で、改行でつなぐ (貼ると、Claude Code の入力欄に複数行の 1 つの入力として入る)
  answerText() {
    const parts = [];
    for (const [qi, q] of (this.data?.questions ?? []).entries()) {
      const oi = this.picked[q.id];
      if (oi === undefined) continue;
      const o = (q.options ?? [])[oi];
      if (!o) continue;
      // short・title・label が無くても undefined を字にしない。問いはカードの札 (Q1…)、選択肢は何番目かで呼ぶ
      const name = q.short ?? q.title ?? `Q${qi + 1}`;
      const label = o.label ?? `${oi + 1} 番目`;
      parts.push(o.answer ?? `${name} -> ${label}`);
    }
    return parts.join("\n");
  }

  // 改行で区切った字を、1 行ずつの要素にする (答えは 1 つ 1 行。送った後のわけの字も。stderr の CRLF も 1 つの改行とみる)
  lines(text) {
    return v_flex()
      .min_w(0)
      .children(String(text).split(/\r?\n/).map((t) => div().min_w(0).child(t)));
  }

  // 字をクリップボードに入れて props.terminal の端末に 1 回で貼り (terminal.paste)、submit なら hc keys で Enter を 1 回押す (頭のコメントの
  // 「答えの送り方」。問いの送信と段の answer の「送る」で使う)。返すのは { ok: 貼れた (submit なら Enter まで押せた) か, term: 端末, msg: 止まった
  // わけ }。cx は使わない (await をまたぐので、呼ぶ側が cx.spawn の中で待つ)。exec などが投げたら、呼ぶ側が受ける
  async pasteToTerminal(text, submit) {
    // ほかの写しのペインが送っている間は送らない (クリップボードと端末への貼り付けは 1 つずつ)
    const until = shared(SEND_KEY);
    if (typeof until === "number" && until > Date.now()) return { ok: false, msg: "ほかの panel のペインが送っている。少し待ってから送る" };
    const lock = Date.now() + SEND_LOCK_MS;
    setShared(SEND_KEY, lock);
    try {
      const term = props()?.terminal;
      // 端末のエージェントが人を待っている (許可・問いの画面。hc の status が blocked) 間は、クリップボードにも入れずに止める。貼った字は画面に
      // 無視されるか選択肢を選び、Enter は選ばれている選択肢を確定しうる (hc send も blocked の端末には送らない)。確かめられなければ止めない
      if (term) {
        const g0 = await hc(["get", term, "--json"]);
        if (g0.code === 0 && blockedOf(g0.stdout)) return { ok: false, term, msg: `端末 ${term} が確かめの画面で止まっている (blocked)。端末で答えてから送る` };
      }
      // 字を code point の並びで渡す (改行・引用符・日本語を PowerShell の引用の外に置く)。改行は LF のまま入れる
      const codes = Array.from(text).map((ch) => ch.codePointAt(0));
      const ps = `Set-Clipboard -Value (-join (@(${codes.join(",")}) | ForEach-Object { [char]::ConvertFromUtf32($_) }))`;
      const r = await exec("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", ps], { timeout: 15000 });
      if (r.code !== 0) return { ok: false, msg: `クリップボードに入れられない: ${r.stderr.trim()}` };
      if (!term) return { ok: false, msg: "クリップボードに入れた (props.terminal が無い)" };
      run("pane.focus", { terminal: term });
      run("terminal.paste");
      if (!submit) return { ok: true, term };
      // 貼った文が届いてから Enter を押す。端末がいるかの確かめを兼ねて hc get を 1 回挟んで間を置く。その間に確かめの画面になったら押さない
      const g = await hc(["get", term, "--json"]);
      if (g.code !== 0) return { ok: false, term, msg: `端末 ${term} が見つからない。入力欄に入れたところで止めた` };
      if (blockedOf(g.stdout)) return { ok: false, term, msg: `端末 ${term} が確かめの画面で止まったので、Enter を押さなかった` };
      const k = await hc(["keys", term, "enter"]);
      if (k.code !== 0) return { ok: false, term, msg: `Enter を押せなかった: ${k.stderr.trim()}。入力欄で Enter を押して送る` };
      return { ok: true, term };
    } finally {
      // 送っている印を戻す (ほかの写しが後から置いた印は消さない)
      if (shared(SEND_KEY) === lock) setShared(SEND_KEY, 0);
    }
  }

  deliver(cx, submit) {
    const text = this.answerText();
    if (!text || this.busy) return;
    // 問いのペインは、送ったら自分を閉じる。閉じるのは、送信の頭でこの panel の handle がキーボードを持つときの、キーボードのある
    // ペイン (この後の pane.focus で端末へ移る前に控える)。この panel のペインかは、Enter まで済んだ後に ownPane で確かめる
    const closing = submit && this.role() === "questions";
    const self = closing && this.holdsKeyboard() ? (focused()?.pane ?? null) : null;
    this.busy = true;
    this.status = submit ? "送っています…" : "入れています…";
    // await をまたぐ仕事は cx.spawn の cx でする (クリックやキーの cx は、await の後には使えない)
    cx.spawn(async (cx) => {
      let closed = false;
      try {
        const res = await this.pasteToTerminal(text, submit);
        if (!res.ok) {
          this.status = res.msg;
          return;
        }
        const term = res.term;
        if (!submit) {
          this.status = `${term} の入力欄に入れた。Enter で送る`;
          return;
        }
        this.status = `${term} に送った:\n${text}`;
        this.picked = {};
        if (closing) {
          const pane = this.ownPane(self);
          if (!pane) {
            this.status = `${term} に送った (閉じるのはハブ):\n${text}`;
            return;
          }
          run("pane.close", { pane });
          closed = true;
          run("pane.focus", { terminal: term });
        }
      } catch (e) {
        this.status = `止まった: ${e}`;
      } finally {
        this.busy = false;
        // 自分のペインを閉じた後は cx を使わない (このコピーはもう無い)
        if (!closed) cx.notify();
      }
    });
    cx.notify();
  }

  colors() {
    const t = theme();
    const col = (k, d) => t[k] ?? d;
    // いまの段 (active) の色。herdr-app の Agents 欄が動いているエージェントの印に使う色。無い theme では ansi3 (黄)
    const working = col("working", col("ansi3", "#e5c07b"));
    return {
      t,
      fg: col("foreground", "#dddddd"),
      muted: col("muted", "#aaaaaa"),
      dim: col("dim", "#888888"),
      border: col("border", "#444444"),
      accent: col("accent", "#6aa0ff"),
      surface: col("surface", col("background", "#1e1e1e")),
      raised: col("raised", "#2a2a2a"),
      solid: col("solid", col("accent", "#6aa0ff")),
      solidFg: col("solid_foreground", "#ffffff"),
      blocked: col("blocked", col("ansi1", "#e06c75")),
      working,
      workingBg: withAlpha(working, "26"), // working を薄く (Agents 欄の「Needs you」の札と同じ 0x26)。#rrggbb でなければ null
      ok: col("ansi2", "#98c379"),
      warn: col("ansi3", "#e5c07b"),
    };
  }

  paint(c, name, fallback) {
    if (!name) return fallback;
    if (name.startsWith("#")) return name;
    return c[name] ?? c.t[name] ?? fallback;
  }

  // ---- 質問 ----
  questionCard(q, qi, c) {
    const picked = this.picked[q.id];
    const opts = (q.options ?? []).map((o, oi) => {
      const on = picked === oi;
      return v_flex()
        .id(`hp-${q.id}-${oi}`)
        .p(10)
        .gap(4)
        .rounded(8)
        .border_1()
        .border_color(on ? c.accent : c.border)
        .bg(on ? c.raised : c.surface)
        .cursor_pointer()
        .hover((s) => s.opacity(0.88))
        .on_click((_, cx) => {
          this.picked[q.id] = on ? undefined : oi;
          this.status = "";
          this.handle.focus();
          cx.notify();
        })
        .child(
          h_flex()
            .gap(6)
            .items_center()
            .child(div().flex_none().text_color(on ? c.accent : c.dim).child(on ? "●" : "○"))
            // min_w(0): 長い選択肢は縮んで折り返す (付けないと字が 1 行ぶんの幅より縮まず、カードからはみ出す)
            .child(div().min_w(0).font_semibold().text_color(c.fg).child(o.label ?? ""))
            .when(!!o.recommended, (el) => el.child(this.badge("推奨", c.solid, c.solidFg))),
        )
        .when(!!o.desc, (el) => el.child(div().text_size(this.fs(12)).text_color(c.muted).child(o.desc)));
    });
    return v_flex()
      .id(`hp-q-${q.id}`)
      .p(12)
      .gap(10)
      .rounded(10)
      .border_1()
      .border_color(c.accent)
      .child(
        h_flex()
          .gap(8)
          .items_center()
          .child(this.badge(`Q${qi + 1}`, c.solid, c.solidFg))
          .child(div().flex_1().min_w(0).text_size(this.fs(14)).font_semibold().text_color(c.fg).child(q.title ?? "")),
      )
      .when(!!q.body, (el) => el.child(div().text_color(c.fg).child(this.md(`hp-qb-${q.id}`, q.body))))
      .children(opts);
  }

  badge(text, bg, fg) {
    return div()
      .flex_none()
      .px(this.fs(6))
      .py(this.fs(1))
      .rounded(this.fs(4))
      .bg(bg)
      .text_color(fg)
      .text_size(this.fs(10))
      .font_semibold()
      .child(text);
  }

  // ---- 状況の節 ----
  section(s, i, c) {
    const id = s.id ?? `s${i}`;
    const closed = !!this.collapsed[id];
    // 消す印 (頭のコメントの「節を消す印」)。ボタンを出すのは、まとめのペインの id のある節だけ
    const key = this.marksOn() ? markKey(s) : null;
    const marked = this.markState(s) === "marked";
    const head = h_flex()
      .id(`hp-sh-${id}`)
      .flex_1()
      .min_w(0)
      .gap(6)
      .items_center()
      .cursor_pointer()
      .on_click((_, cx) => {
        this.collapsed[id] = !closed;
        cx.notify();
      })
      .child(div().flex_none().w(this.fs(12)).text_color(c.dim).child(closed ? "▸" : "▾"))
      .child(
        div()
          .flex_1()
          .min_w(0)
          .text_size(this.fs(13))
          .font_semibold()
          .text_color(marked ? c.muted : c.fg)
          .when(marked, (el) => el.line_through())
          .child(s.type === "qa" ? this.qaTitle(s) : (s.title ?? "")),
      );
    let body = null;
    if (!closed) {
      if (s.type === "markdown") body = this.markdownBody(s, id, c);
      else if (s.type === "qa") body = this.qaBody(s, id, c);
      else if (s.type === "flow") body = this.flow(s, id, c);
      else if (s.type === "image") body = this.picture(s, id, c);
      else if (s.type === "tickets") body = this.ticketList(s, id, c);
      else if (s.type === "prs") body = this.prList(s, id, c);
      else if (s.type === "work") body = this.workTree(s, id, c);
      else body = div().text_color(c.dim).child(`知らない節: ${s.type ?? "(type が無い)"}`);
    }
    return v_flex()
      .id(`hp-s-${id}`)
      .p(12)
      .gap(8)
      .rounded(10)
      .border_1()
      .when(marked, (el) => el.border_dashed())
      .border_color(marked ? c.warn : c.border)
      .bg(c.surface)
      // 題の行と、その右の印のボタン (題の行の外に置き、押しても節は開け閉めしない)
      .child(
        h_flex()
          .gap(6)
          .items_center()
          .child(head)
          .when(key != null, (el) =>
            el.child(
              this.markButton(`hp-dm-${key}`, marked, c, ["印を外す (この節を残す)", "次の更新でこの節を消す (もう一度押すと戻せる)"], (cx) =>
                this.toggleMark(key, { title: str(s.title) }, cx),
              ),
            ),
          ),
      )
      .when(marked, (el) => el.child(div().text_size(this.fs(11)).text_color(c.warn).child("次の更新で消える (「戻す」で残す)")))
      .when(!!body, (el) => el.child(marked ? div().opacity(0.45).child(body) : body));
  }

  // ---- 節を消す印 (頭のコメントの「節を消す印」) と、印のファイルの読み書き (段の押した印も同じ手。頭のコメントの「段の answer」) ----

  // 印を扱うペインか。問いのペインは節を出さないので、印のファイル (消す印・押した印) を読みも書きもしない
  marksOn() {
    return this.role() !== "questions" && !!props()?.file;
  }

  // 節の印の状態。null: 印なし (印を付けられない節も)。"marked": 印あり・panel.json は印を付けたときの中身のまま (印つきで出す)。
  // "hidden": 印あり・印の後に panel.json の中身が変わった (出さない)
  markState(s) {
    const key = markKey(s);
    const m = key != null && this.marksOn() ? this.dm.cur.get(key) : undefined;
    if (!m) return null;
    return m.base === this.hash ? "marked" : "hidden";
  }

  // 出す節 (印で隠す節を除く)。i は panel.json の sections の何番目か (id の無い節の名前に使う)
  shownSections(secs) {
    return (Array.isArray(secs) ? secs : []).map((s, i) => ({ s, i })).filter(({ s }) => this.markState(s) !== "hidden");
  }

  // 印のファイルの読み書きを、この写しの中で 1 つずつ流す (2 つの印のファイルとも同じ鎖。前の書き換えが済んでから次を読む。続けて押したら、
  // 後に押した方が残る)
  async serial(fn) {
    const prev = this.markTail;
    let release;
    this.markTail = new Promise((r) => {
      release = r;
    });
    try {
      await prev;
      return await fn();
    } finally {
      release();
    }
  }

  // 印のファイル (kind は DISMISS か PRESS) を読み、op (今の印 → 新しい印。変えないなら null) で書き換える。読んでから書くまでにほかの写しが
  // 書いていたら (writeTextFile の expected が合わずに断られたら) 読み直してやり直す。返すのは { marks: 書いた (か読んだ) 印 } か、読み書き
  // できなければ { error: わけ }。this には入れない (入れるのは takeMarks。reload は panel.json とまとめて入れる)
  async editMarks(op, kind) {
    const file = props().file;
    const path = kind.pathOf(file);
    let err = null;
    for (let i = 0; i < 4; i++) {
      let text;
      try {
        text = await readTextFile(path);
      } catch (e) {
        err = e;
        break;
      }
      const cur = kind.parse(text);
      const next = op(cur);
      if (next == null) return { marks: cur };
      try {
        await writeTextFile(path, kind.json(file, next), text ?? null);
        return { marks: next };
      } catch (e) {
        err = e;
      }
    }
    return { error: `${kind.what}のファイル (${baseName(path)}) を読み書きできない: ${err}` };
  }

  // editMarks の結果を book (印のファイルの控え。this.dm か this.sp) に入れる。まだ書いていない押下 (pending) を当て直すので、ほかの読み書きが
  // 先に済んでも、押した見た目が戻らない (op は「付ける」「外す」「送った」の形なので、2 度当てても同じ)
  takeMarks(book, res) {
    if (res.marks) {
      book.cur = book.pending.reduce((m, op) => op(m) ?? m, res.marks);
      book.error = null;
    } else {
      book.error = res.error;
    }
  }

  // 読み直したとき: book の印のファイルを読み、この読み直しで読めた panel.json (fresh) にもう無い鍵の印を外す (liveOf は sections から、
  // 印を残す鍵の Set を作る。消す印は節と Q&A の項目の id、押した印は押せる段の鍵)。fresh が無い (panel.json が無い・読めない) ときは外さない
  // (前の中身から外すと、ほかの写しが新しい中身に付けた印を消しうる)。問いのペインは null。reload が serial の中で呼ぶ (ここでは鎖に並ばない)
  syncMarks(book, fresh, liveOf) {
    if (!this.marksOn()) return Promise.resolve(null);
    const keys = fresh ? liveOf(Array.isArray(fresh.sections) ? fresh.sections : []) : null;
    return this.editMarks((m) => {
      if (!keys) return null;
      const next = new Map([...m].filter(([k]) => keys.has(k)));
      return next.size === m.size ? null : next;
    }, book.kind);
  }

  // 押下の op を book の見た目にすぐ当て、まだ書いていない押下に積む (印のファイルへ書くのは writeMarks)
  stageMarks(book, op) {
    book.pending.push(op);
    book.cur = op(book.cur) ?? book.cur;
  }

  // stageMarks で積んだ op を印のファイルへ書く (cx.spawn の中で待つ)。書けなければわけを残し、見た目をファイルの中身 (に、ほかのまだ書いて
  // いない押下を当てたもの) へ戻す。書けたら true
  async writeMarks(book, op) {
    const res = await this.serial(() => this.editMarks(op, book.kind));
    book.pending = book.pending.filter((o) => o !== op);
    if (res.marks) {
      this.takeMarks(book, res);
      return true;
    }
    book.error = res.error;
    const back = await this.serial(() => this.editMarks(() => null, book.kind));
    if (back.marks) book.cur = book.pending.reduce((m, o) => o(m) ?? m, back.marks);
    return false;
  }

  // 押下 (クリック) の op を印のファイルに当てる。見た目はすぐに変え、ファイルへは後で書く (書けなければファイルの中身に戻し、わけを出す)
  commitMarks(book, op, cx) {
    this.stageMarks(book, op);
    cx.notify();
    cx.spawn(async (cx) => {
      await this.writeMarks(book, op);
      cx.notify();
    });
  }

  // 節 (か Q&A の項目) の印を付け外しする。印は今の panel.json の指紋 (base) と組で残し、panel.json の中身がこれと違えば出さない。info は
  // 印に書く title と、項目なら section (節の id)
  toggleMark(key, info, cx) {
    const on = !this.dm.cur.has(key);
    const entry = { id: key, title: info.title, at: new Date().toISOString(), base: this.hash ?? "" };
    if (info.section != null) entry.section = info.section;
    this.commitMarks(
      this.dm,
      (m) => {
        if (on === m.has(key)) return null;
        const next = new Map(m);
        if (on) next.set(key, entry);
        else next.delete(key);
        return next;
      },
      cx,
    );
  }

  // 印のボタン (節の右上と、Q&A の項目の頭の行の右)。「×」で次の更新で消す印を付け、「戻す」で外す。tips は [印があるとき, 無いとき] の
  // ヒント、onToggle は押したときにすること (cx を受ける)
  markButton(eid, marked, c, tips, onToggle) {
    return h_flex()
      .id(eid)
      .flex_none()
      .h(this.fs(20))
      .min_w(this.fs(20))
      .px(this.fs(6))
      .justify_center()
      .items_center()
      .rounded(this.fs(5))
      .border_1()
      .border_color(marked ? c.warn : c.border)
      .text_size(this.fs(11))
      .text_color(marked ? c.warn : c.dim)
      .cursor_pointer()
      .hover((st) => st.bg(c.raised))
      .tooltip(marked ? tips[0] : tips[1])
      .on_click((e, cx) => {
        cx.stop_propagation();
        // ダブルクリックの 2 回目は数えない (付けてすぐ外さない)
        if ((e?.click_count ?? 1) > 1) return;
        onToggle(cx);
      })
      .child(marked ? "戻す" : "×");
  }

  // ---- リンク (頭のコメントの「リンク」) ----

  // markdown の文 (TextView)。リンクを押すと openLink で開く (TextView の既定の開き方は scheme を確かめないので使わない)
  md(id, text) {
    return TextView.markdown(id, str(text))
      .selectable(true)
      .on_link_click((url, cx) => this.openLink(url, cx));
  }

  // url を既定のブラウザで開く。http と https (webUrl) だけで、ほかは開かずに下の行にわけを出す。開けたら、前に出した開かなかった
  // わけを消す (ほかのわけは残す)
  openLink(url, cx) {
    const u = webUrl(url);
    if (!u) {
      this.linkNote(`開かない (http と https の URL だけを開く): ${str(url)}`, cx);
      return;
    }
    try {
      cx.open_url(u);
    } catch (e) {
      this.linkNote(`開けない: ${u} (${e})`, cx);
      return;
    }
    if (this.status !== "" && this.status === this.linkMsg) {
      this.status = "";
      cx.notify();
    }
  }

  linkNote(msg, cx) {
    this.status = msg;
    this.linkMsg = msg;
    cx.notify();
  }

  // ---- ミニ絵 (頭のコメントの「ミニ絵」) ----

  // markdown の節の中身。絵だけの行があれば、文・ミニ絵・文の順に縦に並べる (文はそれぞれ md() の TextView)。無ければ今までどおり 1 つの TextView
  markdownBody(s, id, c) {
    const parts = typeof s.text === "string" ? splitMinis(s.text) : [];
    if (!parts.some((p) => p.kind === "mini")) return div().text_size(this.fs(12)).text_color(c.fg).child(this.md(`hp-md-${id}`, s.text));
    // 物差しで測る記号の欄の字 (箇条書きの中のミニ絵の分だけ)
    const prefixes = [...new Set(parts.filter((p) => p.kind === "mini" && p.align.depth > 0).map((p) => p.align.prefix))];
    return v_flex()
      .relative()
      .gap(MINI.gap)
      .text_size(this.fs(12))
      .text_color(c.fg)
      .children(parts.map((p, k) => (p.kind === "text" ? this.md(k === 0 ? `hp-md-${id}` : `hp-md-${id}-${k}`, p.text) : this.mini(p, s, id, k, c))))
      .when(prefixes.length > 0, (el) => el.child(this.miniRulers(id, prefixes)));
  }

  // ミニ絵 (か、出せないわけの 1 行)。左は、すぐ上の行の字の頭 (miniX) まで空ける。大きさは fs(MINI.w)×fs(MINI.h) で、ペインの幅には
  // 合わせず、ペインが狭くて入らないときだけ比を保って縮める (PIC.min 倍まで)。押すと image の節の図と同じ小窓で大きく見る
  mini(p, s, id, k, c) {
    const x = this.miniX(p.align);
    const why = p.why ?? this.miniCheck.get(p.path)?.why ?? null;
    if (why) return div().pl(x).text_size(this.fs(11)).text_color(c.dim).child(`ミニ絵を出せない: ${why}`);
    const W = this.fs(MINI.w);
    const H = this.fs(MINI.h);
    // ペインの幅 (zoom で割った px) から一覧と節のカードの余白 (PIC.pad)・節の中の箱の余白 (s.inset。Q&A の項目のカードと答えの字下げ)・
    // 左の空きを引いた幅。幅を知るまで (最初の描画) は等倍
    const avail = this.width == null ? null : this.width / appZoom() - PIC.pad - (s.inset ?? 0) - x;
    const r = avail == null ? 1 : clamp(avail / W, PIC.min, 1);
    const fig = { title: s.title, src: p.path, width: MINI.w, height: MINI.h, caption: p.alt };
    const hint = "クリックで大きく見る (Esc で閉じる)";
    return div()
      .pl(x)
      .child(
        div()
          .id(`hp-mini-${id}-${k}`)
          .flex_none()
          .w(W * r)
          .h(H * r)
          .cursor_pointer()
          .hover((st) => st.opacity(0.9))
          .tooltip(p.alt === "" ? hint : `${p.alt} (${hint})`)
          .on_click((_, cx) => this.openBig(fig, cx))
          .child(image(this.imagePath(p.path)).w(W * r).h(H * r)),
      );
  }

  // TextView の箇条書きの 1 段の幅 (zoom を掛ける前の px)。TextView の字の大きさは、節の中身の字 (fs(12)) を継ぐ
  listIndent() {
    return this.fs(12) * LIST.indent;
  }

  // ミニ絵の左の空き (zoom を掛ける前の px)。TextView (LIST) は入れ子の箇条書きを 1 段の幅ずつ下げ、記号の欄の後ろに字を置くので、
  // 1 段の幅 × (段 - 1) + 記号の欄の幅。記号の欄の幅は物差し (miniRulers) で測った幅を zoom で割って使い、測る前は 1 段の幅とみる
  // (記号 1 つや短い番号は、1 段の幅の欄に収まる)
  miniX(a) {
    if (!a || a.depth === 0) return 0;
    const ind = this.listIndent();
    const w = this.probe[`c:${a.prefix}`];
    return ind * (a.depth - 1) + (w != null ? w / appZoom() : ind);
  }

  // 物差し: 見えない要素で記号の欄の幅を測る。TextView の記号の欄と同じ作り (幅は 1 段の幅より狭くならず、記号の右に 1 段の幅の
  // LIST.gap 倍の空き) にし、字は TextView と同じく節の中身の字を継ぐ (on_size_change は zoom を掛けた後の logical px)。流れの外
  // (absolute) に置き、並びを変えない。id は記号の欄の字で決める (節の中の記号の並びが替わっても、同じ字の物差しは同じ id)。
  // 測った幅が変わったら (panel の % や zoom を替えた) 描き直す
  miniRulers(id, prefixes) {
    const ind = this.listIndent();
    return div()
      .absolute()
      .left(0)
      .top(0)
      .opacity(0)
      .children(
        prefixes.map((pf) =>
          div()
            .id(`hp-mp-${id}-${[...pf].map((ch) => ch.codePointAt(0).toString(16)).join("-")}`)
            .absolute()
            .min_w(ind)
            .pr(ind * LIST.gap)
            .whitespace_nowrap()
            .on_size_change((size, cx) => this.takeRuler(`c:${pf}`, size.width, cx))
            .child(pf),
        ),
      );
  }

  takeRuler(key, w, cx) {
    if (typeof w !== "number" || !Number.isFinite(w)) return;
    if (this.probe[key] != null && Math.abs(this.probe[key] - w) < 0.25) return;
    this.probe[key] = w;
    cx.notify();
  }

  // ---- Q&A (頭のコメントの「Q&A」) ----

  // 出す項目 (消す印を付けた後に panel.json が変わった項目を除く)
  qaShown(s) {
    return qaItemsOf(s).filter(({ it }) => this.markState(it) !== "hidden");
  }

  // Q&A の節の題。後ろに、出している項目の数を「(N)」で足す
  qaTitle(s) {
    const t = str(s.title);
    const n = `(${this.qaShown(s).length})`;
    return t === "" ? n : `${t} ${n}`;
  }

  // 項目の開け閉めを覚える鍵 (節の id と項目の id。id の無い項目は items の中の位置)
  qaKey(id, it, i) {
    const k = markKey(it);
    return `${id}\u0000${k != null ? k : `@${i}`}`;
  }

  // 項目の初めの開け閉め: open が boolean ならそれ、ほかは items の 1 つ目だけを開く
  qaOpenByDefault(it, i) {
    return typeof it.open === "boolean" ? it.open : i === 0;
  }

  // Q&A の節の中身。項目を panel.json の順に縦に並べる
  qaBody(s, id, c) {
    const shown = this.qaShown(s);
    if (shown.length === 0) return div().text_color(c.muted).child("(項目はありません)");
    return v_flex()
      .gap(8)
      .children(shown.map(({ it, i }) => this.qaItem(s, it, i, id, c)));
  }

  // 項目: 枠のついた小さなカード。頭の行 (印・「Q. <q>」・時刻・×) と、開いていれば、その下に 1 段下げた答え
  qaItem(s, it, i, id, c) {
    const key = this.qaKey(id, it, i);
    const open = this.qaOpen[key] ?? this.qaOpenByDefault(it, i);
    const mkey = this.marksOn() ? markKey(it) : null; // × を出すのは、まとめのペインの id のある項目だけ
    const marked = this.markState(it) === "marked";
    const q = str(it.q);
    const at = str(it.at).trim();
    const S = this.fs(12); // 開け閉めの印の欄の幅 (節の題の行の ▸ の欄と同じ)
    const gap = 6;
    const head = h_flex()
      .id(`hp-qh-${id}-${i}`)
      .flex_1()
      .min_w(0)
      .gap(gap)
      .items_start()
      .cursor_pointer()
      .tooltip(open ? "畳む" : "開く")
      .on_click((e, cx) => {
        // ダブルクリックの 2 回目は数えない (開いてすぐ畳まない)
        if ((e?.click_count ?? 1) > 1) return;
        this.qaOpen[key] = !open;
        cx.notify();
      })
      .child(div().flex_none().w(S).text_color(c.dim).child(open ? "▾" : "▸"))
      .child(
        div()
          .flex_1()
          .min_w(0)
          .font_semibold()
          .text_color(marked ? c.muted : c.fg)
          .when(marked, (el) => el.line_through())
          .child(`Q. ${q}`),
      )
      .when(at !== "", (el) => el.child(div().flex_none().text_size(this.fs(10)).text_color(c.dim).child(at)));
    let answer = null;
    if (open) {
      const a = str(it.a);
      answer =
        a.trim() === ""
          ? div().text_size(this.fs(12)).text_color(c.dim).child("(まだ答えていない)")
          : // inset: 項目のカードの左右の余白と枠 (px(10)・border_1) と答えの字下げ。ミニ絵がカードからはみ出さない幅を決める
            this.markdownBody({ title: `Q. ${q}`, text: a, inset: 22 + S + gap }, `${id}-qa-${i}`, c);
    }
    return v_flex()
      .id(`hp-qa-${id}-${i}`)
      .px(10)
      .py(8)
      .gap(6)
      .rounded(8)
      .border_1()
      .when(marked, (el) => el.border_dashed())
      .border_color(marked ? c.warn : c.border)
      .text_size(this.fs(12))
      .child(
        h_flex()
          .gap(6)
          .items_start()
          .child(head)
          .when(mkey != null, (el) =>
            el.child(
              this.markButton(`hp-qm-${id}-${i}`, marked, c, ["印を外す (この項目を残す)", "次の更新でこの項目を消す (もう一度押すと戻せる)"], (cx) =>
                this.toggleMark(mkey, { title: q, section: markKey(s) ?? "" }, cx),
              ),
            ),
          ),
      )
      .when(marked, (el) => el.child(div().pl(S + gap).text_size(this.fs(11)).text_color(c.warn).child("次の更新で消える (「戻す」で残す)")))
      .when(!!answer, (el) => el.child(div().pl(S + gap).min_w(0).when(marked, (e) => e.opacity(0.45)).child(answer)));
  }

  // ---- チケットと PR の一覧 (頭のコメントの「チケットと PR の一覧」) ----

  // チケットの一覧の節 (type "tickets")。行: { id, title, url, status, note }
  ticketList(s, id, c) {
    return this.rowList(s, id, c, (r) => this.ticketChips(r, c));
  }

  // PR の一覧の節 (type "prs")。行: { id, title, url, state, ci, note }
  prList(s, id, c) {
    return this.rowList(s, id, c, (r) => this.prChips(r, c));
  }

  // チケットの行の札 (status)。一覧の tickets と木の ticket の行で使う
  ticketChips(r, c) {
    const st = str(r.status).trim();
    return st === "" ? [] : [this.chip(st, this.paint(c, TICKET_COLOR[st.toLowerCase()] ?? "muted", c.muted))];
  }

  // PR の行の札 (state と ci)。一覧の prs と木の pr の行で使う
  prChips(r, c) {
    const chips = [];
    const st = str(r.state).trim();
    if (st !== "") chips.push(this.chip(st, this.paint(c, PR_COLOR[st.toLowerCase()] ?? "muted", c.muted)));
    const ci = str(r.ci).trim();
    if (ci !== "") {
      const [color, label] = CI_CHIP[ci.toLowerCase()] ?? ["muted", `CI ${ci}`];
      chips.push(this.chip(label, this.paint(c, color, c.muted)));
    }
    return chips;
  }

  // 一覧の行を並べる。上の段に ID・状態の札 (chipsOf)・題 (入らなければ題が次の段へ回って折り返す)、下に note
  rowList(s, id, c, chipsOf) {
    const rows = Array.isArray(s.rows) ? s.rows : [];
    if (rows.length === 0) return div().text_color(c.muted).child("(行はありません)");
    return v_flex()
      .gap(8)
      .children(
        rows.map((r, ri) => {
          const row = r !== null && typeof r === "object" ? r : {};
          const key = `${id}-${ri}`;
          const url = webUrl(row.url);
          const rid = str(row.id);
          const title = str(row.title);
          const note = str(row.note);
          return v_flex()
            .id(`hp-row-${key}`)
            .gap(2)
            .child(
              h_flex()
                .flex_wrap()
                .gap_x(6)
                .gap_y(2)
                .items_center()
                .when(rid !== "", (el) => el.child(this.linkText(`hp-rid-${key}`, rid, url, c.accent, c).min_w(0).font_semibold()))
                .children(chipsOf(row))
                .when(title !== "", (el) => el.child(this.linkText(`hp-rt-${key}`, title, url, c.fg, c).min_w(0))),
            )
            .when(note !== "", (el) => el.child(div().min_w(0).text_size(this.fs(11)).text_color(c.muted).child(note)));
        }),
      );
  }

  // 押すと url を開く字。下線と指の形のポインタで押せると分かるようにし、上に来ると url を出す。url が無ければ押せない字 (fg の色・下線なし)
  linkText(eid, text, url, color, c) {
    const el = div().id(eid);
    if (!url) return el.text_color(c.fg).child(text);
    return el
      .text_color(color)
      .underline()
      .cursor_pointer()
      .hover((st) => st.opacity(0.8))
      .tooltip(url)
      .on_click((e, cx) => {
        // ダブルクリックの 2 回目は数えない (ブラウザのタブを 2 つ開かない)
        if ((e?.click_count ?? 1) > 1) return;
        this.openLink(url, cx);
      })
      .child(text);
  }

  // 状態の札。枠と字を color で、地を同じ色の薄い色で塗る (地は color が #rrggbb のときだけ)
  chip(text, color) {
    const bg = withAlpha(color, "26");
    return div()
      .flex_none()
      .px(this.fs(6))
      .py(this.fs(1))
      .rounded(this.fs(8))
      .border_1()
      .border_color(color)
      .when(!!bg, (el) => el.bg(bg))
      .text_color(color)
      .text_size(this.fs(10))
      .font_semibold()
      .child(text);
  }

  // 枠だけの札 (木の行の who)。地を塗らず、字は細いまま。入らなければ縮んで、札の中で折り返す
  outlineChip(text, color) {
    return div()
      .min_w(0)
      .px(this.fs(6))
      .py(this.fs(1))
      .rounded(this.fs(8))
      .border_1()
      .border_color(color)
      .text_color(color)
      .text_size(this.fs(10))
      .child(text);
  }

  // ---- チケット・進み具合・PR の木 (頭のコメントの「チケット・進み具合・PR の木」) ----

  // 木の寸法。S は開け閉めの印の欄の幅 (節の題の行の ▸ の欄と同じ fs(12) を整数に丸めたもの。1 段の字下げが整数になり、縦の線が段に
  // よって半端な px に来ない)、gap は欄と ID の間、I は 1 段の字下げ (欄 + 間。子の印の欄は親の ID の頭にそろう)、x0 は縦の線を引く所 (欄のまん中)
  treeGeom() {
    const S = Math.round(this.fs(12));
    const gap = 6;
    return { S, gap, I: S + gap, x0: Math.floor(S / 2) };
  }

  // 木の節 (type "work")。根の行 (related でないもの) を上から順に出し、related が true の根の行は、その下の点線の下に「関連」の字と
  // 並べて出す (ほかの根の行が無ければ点線は引かない)
  workTree(s, id, c) {
    const roots = listOf(s.rows).map((r, i) => ({ r: objOr(r), path: String(i) }));
    if (roots.length === 0) return div().text_color(c.muted).child("(行はありません)");
    const g = this.treeGeom();
    const sec = markKey(s) ?? ""; // 押した印の section (頭のコメントの「段の answer」。id の無い節は空の字)
    const stack = (list) =>
      v_flex()
        .min_w(0)
        .gap(TREE.gap)
        .children(
          list.map(({ r, path }) => {
            const { top, rest } = this.workRow(r, path, 0, id, g, c, null, sec);
            return v_flex().min_w(0).child(top).when(!!rest, (el) => el.child(rest));
          }),
        );
    const main = roots.filter(({ r }) => r.related !== true);
    const related = roots.filter(({ r }) => r.related === true);
    return v_flex()
      .gap(TREE.gap)
      .when(main.length > 0, (el) => el.child(stack(main)))
      .when(related.length > 0, (el) =>
        el
          .when(main.length > 0, (e) => e.child(div().border_t_1().border_dashed().border_color(c.border)))
          // 「関連」の字は行と同じ大きさにし、1 つ目の行の 1 行目とそろえる
          .child(h_flex().items_start().gap(8).child(div().flex_none().text_color(c.muted).child("関連")).child(stack(related).flex_1())),
      );
  }

  // 木の行。上の段 (top) と、その下 (rest: 段・一言・子。無ければ null) を分けて返す。親は子の top と rest の左に、それぞれ溝 (親の縦の
  // 線) を付ける。tick は親から来る横の線: null (根・線を引かない深さ)・"tee" (下に兄弟が続く)・"corner" (最後の子。親の縦の線をここで止める)。
  // sec は押した印の section (節の id か空の字)
  workRow(r, path, depth, id, g, c, tick, sec) {
    const kind = kindOf(r);
    const steps = listOf(r.steps);
    const kids = listOf(r.children).map((k, i) => ({ r: objOr(k), path: `${path}.${i}` }));
    const foldable = kind === "ticket" && (steps.length > 0 || kids.length > 0);
    const key = this.rowKey(id, r, path);
    const open = !foldable || (this.rowOpen[key] ?? this.openByDefault(r));
    // 子を出すか・子へ線を引いて字下げするか (TREE.indent 段まで。それより深い子は字下げも線もなしで、すぐ下に並べる)
    const showKids = open && kids.length > 0;
    const lined = showKids && depth < TREE.indent;
    const note = str(r.note);
    const rest = [];
    if (open && steps.length > 0) {
      const at = { section: sec, row: rowName(r, path) }; // 押した印の section と row (頭のコメントの「段の answer」)
      rest.push(this.treePiece(g, lined, 4, this.workSteps(steps.map(stepOf), `w-${id}-${path}`, at, c), c));
    }
    if (open && note !== "") rest.push(this.treePiece(g, lined, 2, div().min_w(0).text_size(this.fs(11)).text_color(c.muted).child(note), c));
    if (showKids) {
      kids.forEach(({ r: k, path: kp }, i) => {
        const last = i === kids.length - 1;
        const part = this.workRow(k, kp, depth + 1, id, g, c, lined ? (last ? "corner" : "tee") : null, sec);
        if (lined) {
          rest.push(this.treeSpacer(g, c));
          rest.push(this.treeWrap(g, !last, part.top, c));
          if (part.rest) rest.push(this.treeWrap(g, !last, part.rest, c));
        } else {
          rest.push(div().h(TREE.gap));
          rest.push(part.top);
          if (part.rest) rest.push(part.rest);
        }
      });
    }
    return {
      top: this.workTop(r, kind, path, id, g, c, { foldable, open, key, tick, tail: lined, summary: open ? "" : prSummary(r) }),
      rest: rest.length > 0 ? v_flex().min_w(0).children(rest) : null,
    };
  }

  // 木の行の初めの開け閉め: status が Done か Canceled で、下に動いているもの (isMoving) が無ければ畳む
  openByDefault(r) {
    return !(CLOSED_STATUS.has(str(r.status).trim().toLowerCase()) && !isMoving(r));
  }

  // 木の行の開け閉めを覚える鍵 (節の id と行の名前。行の id か、id の無い行は木の中の位置)
  rowKey(id, r, path) {
    return `${id}\u0000${rowName(r, path)}`;
  }

  // 行の上の段: 印の欄 | ID・札・題・who (・畳んだ行の PR の数)。入らなければ右の欄の中で折り返す (一覧の行と同じ)
  workTop(r, kind, path, id, g, c, o) {
    const url = webUrl(r.url);
    const rid = str(r.id);
    const title = str(r.title);
    const who = str(r.who).trim();
    const chips = kind === "ticket" ? this.ticketChips(r, c) : kind === "pr" ? this.prChips(r, c) : [];
    const head = h_flex()
      .flex_1()
      .min_w(0)
      .flex_wrap()
      .gap_x(6)
      .gap_y(2)
      .items_center()
      .when(rid !== "", (el) => el.child(this.linkText(`hp-wid-${id}-${path}`, rid, url, c.accent, c).min_w(0).font_semibold()))
      .children(chips)
      // ID の無い行 (item など) は、題を太字にして行の名前にする
      .when(title !== "", (el) => el.child(this.linkText(`hp-wtt-${id}-${path}`, title, url, c.fg, c).min_w(0).when(rid === "", (e) => e.font_semibold())))
      .when(who !== "", (el) => el.child(this.outlineChip(who, c.muted)))
      // 畳んだ行の PR の数は右に寄せ、狭ければ縮んで折り返す (カードの外へはみ出さない)
      .when(o.summary !== "", (el) => el.child(div().min_w(0).ml_auto().text_size(this.fs(11)).text_color(c.muted).child(o.summary)));
    return h_flex().items_start().gap(g.gap).child(this.treeSlot(path, id, g, c, o)).child(head);
  }

  // 印の欄: 上に印 (▸・▾。畳めない行は空き) を 1 行の高さで置き、その下は上の段の高さまで伸ばす。tail なら印の下に縦の線 (この行から
  // 子へ下りる線。上の段が折り返して高くなっても切れない)。親から来る横の線 (tick) は印の左に描く
  treeSlot(path, id, g, c, o) {
    const line = () => div().absolute().bg(c.border);
    const left = g.x0 - g.I; // 親の縦の線の所 (印の欄の左の端から見て)
    let mark = h_flex().relative().justify_center();
    if (o.foldable) {
      mark = mark
        .id(`hp-wt-${id}-${path}`)
        .cursor_pointer()
        .tooltip(o.open ? "畳む" : "開く")
        .on_click((e, cx) => {
          // ダブルクリックの 2 回目は数えない (開いてすぐ畳まない)
          if ((e?.click_count ?? 1) > 1) return;
          this.rowOpen[o.key] = !o.open;
          cx.notify();
        })
        .child(div().text_color(c.dim).child(o.open ? "▾" : "▸"));
    } else {
      mark = mark.child(" "); // 空きでも 1 行の高さを取る (横の線を上の段の 1 行目のまん中に引くため)
    }
    if (o.tick) {
      // 親の縦の線から印の欄の左の端まで (畳めない行は、空いた欄も通って ID の手前まで)。最後の子は、縦の線を欄の上からここまで引く
      mark = mark.child(line().left(left).top("50%").w(-left + (o.foldable ? 0 : g.S - 1)).h(1));
      if (o.tick === "corner") mark = mark.child(line().left(left).top(0).h("50%").w(1));
    }
    return v_flex()
      .flex_none()
      .w(g.S)
      .self_stretch()
      .child(mark)
      .child(div().flex_1().relative().when(o.tail, (el) => el.child(this.vline(g.x0, c))));
  }

  // 行の下の段 (steps・note) を、印の欄と間 (I) だけ下げて置く。pass なら左の溝に、この行から子へ下りる縦の線を通す
  treePiece(g, pass, padTop, content, c) {
    return h_flex()
      .items_start()
      .child(this.treeGutter(g, pass, c))
      .child(div().flex_1().min_w(0).pt(padTop).child(content));
  }

  // 子の行の段 (top か rest) の左に、親の溝を付ける。pass なら親の縦の線を通す (下に兄弟が続くとき)
  treeWrap(g, pass, piece, c) {
    return h_flex().items_start().child(this.treeGutter(g, pass, c)).child(piece.flex_1().min_w(0));
  }

  // 溝: 字下げの幅 (I) の空き。高さは並べた段に合わせ (self_stretch)、pass なら x0 に縦の線を上から下まで引く
  treeGutter(g, pass, c) {
    return div()
      .flex_none()
      .w(g.I)
      .self_stretch()
      .relative()
      .when(pass, (el) => el.child(this.vline(g.x0, c)));
  }

  // 兄弟の行の間 (と、親の上の段・段・一言と 1 つ目の子の間)。親の縦の線を通す
  treeSpacer(g, c) {
    return h_flex().child(div().flex_none().w(g.I).h(TREE.gap).relative().child(this.vline(g.x0, c)));
  }

  // 縦の線 (置いた箱の上から下まで)
  vline(x, c) {
    return div().absolute().left(x).top(0).bottom(0).w(1).bg(c.border);
  }

  flow(s, id, c) {
    const rows = (s.rows ?? []).map((r, ri) =>
      v_flex()
        .id(`hp-fr-${id}-${ri}`)
        .gap(4)
        .child(
          // 狭いときは sub が次の行へ回り、長い label は縮んで折り返す
          h_flex()
            .flex_wrap()
            .gap(6)
            .items_center()
            .child(div().min_w(0).font_semibold().text_size(this.fs(12)).text_color(c.fg).child(r.label ?? ""))
            .when(!!r.sub, (el) => el.child(div().min_w(0).text_size(this.fs(11)).text_color(c.muted).child(r.sub))),
        )
        .child(this.stepRow(r.steps ?? [], `${id}-${ri}`, c)),
    );
    return v_flex().gap(10).children(rows);
  }

  // 段の並び (flow の行と木の行)。段の札を › でつなぎ、入らなければ折り返す。key は段の札の id の頭 (hp-st-<key>-<何番目>)。at は木の行の
  // 押した印の { section, row } (flow の行は null。answer を見ない)
  stepRow(steps, key, c, at = null) {
    const items = [];
    steps.forEach((st, si) => {
      if (si > 0) items.push(div().text_color(c.dim).text_size(this.fs(11)).child("›"));
      items.push(this.step(st, `${key}-${si}`, c, at));
    });
    return h_flex().flex_wrap().gap(4).items_center().children(items);
  }

  step(st, key, c, at = null) {
    const state = st.state ?? "todo";
    const label = st.label ?? ""; // label の無い段は印だけにする (undefined・null を字にしない)
    const tail = label === "" ? "" : ` ${label}`; // 印の後ろに付ける字
    let base = h_flex()
      .id(`hp-st-${key}`)
      .px(this.fs(7))
      .py(this.fs(2))
      .rounded(this.fs(6))
      .border_1()
      .text_size(this.fs(11))
      .gap(this.fs(4))
      .items_center();
    // answer のある木の段は押せる札にする (頭のコメントの「段の answer」。色・印・点滅は下のまま)
    if (at && st.answer != null && this.marksOn()) base = this.pressable(base, st, at, c);
    if (state === "done") return base.border_color(c.ok).text_color(c.ok).child(`✓${tail}`);
    // いまの段: working の枠と字に、同じ色を薄く敷いて点滅させる
    if (state === "active")
      return base
        .border_color(c.working)
        .when(!!c.workingBg, (el) => el.bg(c.workingBg))
        .text_color(c.working)
        .loop("opacity", { from: 0.55, to: 1, period: 1400 })
        .child(`●${tail}`);
    if (state === "blocked") return base.border_color(c.blocked).text_color(c.blocked).child(`■${tail}`);
    return base.border_color(c.border).text_color(c.dim).child(label);
  }

  // ---- 段の answer (頭のコメントの「段の answer」) ----

  // 押した段の印 (無ければ undefined)。問いのペインは印を扱わない
  pressOf(pk) {
    return this.marksOn() ? this.sp.cur.get(pk) : undefined;
  }

  // 木の行の段の並びと、そのすぐ下に、押した段の確かめか「送った」の行 (段の順に、印ごとに 1 つ)。at は行の { section, row }
  workSteps(steps, key, at, c) {
    const line = this.stepRow(steps, key, c, at);
    const boxes = [];
    const seen = new Set(); // 同じ鍵の段 (label と answer の同じ段) が 2 つあっても、確かめは 1 つ
    steps.forEach((st, si) => {
      if (st.answer == null) return;
      const pk = pressKey(at.section, at.row, st.label, st.answer);
      const m = this.pressOf(pk);
      if (!m || seen.has(pk)) return;
      seen.add(pk);
      boxes.push(this.pressBox(pk, m, `${key}-${si}`, c));
    });
    return boxes.length === 0 ? line : v_flex().min_w(0).gap(4).child(line).children(boxes);
  }

  // 押せる段の札: ポインタの形・hover・ヒントと、押したときの振る舞い (押すと確かめを出し、もう一度押すと「やめる」と同じ)。送った段と
  // 送っている段は押せない (ヒントだけ)。el は段の札 (id を付けたもの)
  pressable(el, st, at, c) {
    const info = { section: at.section, row: at.row, label: st.label, answer: st.answer };
    const pk = pressKey(info.section, info.row, info.label, info.answer);
    const m = this.pressOf(pk);
    if (m?.sent) return el.tooltip("送った (ハブが段を進めるまで、下に「送った」と出す)");
    if (this.sending === pk) return el.tooltip("送っています…");
    return el
      .cursor_pointer()
      .hover((s) => s.bg(c.raised))
      .tooltip(m ? "もう一度押すと、送らずに閉じる" : `押すと「${info.answer}」をハブに送る (送る前に確かめる)`)
      .on_click((e, cx) => {
        // ダブルクリックの 2 回目は数えない (開いてすぐ閉じない)
        if ((e?.click_count ?? 1) > 1) return;
        this.pressStep(info, cx);
      });
  }

  // 押した段の確かめ (印の sent が false): 枠のついた小さな箱に「「<answer>」を送る?」と「送る」「やめる」、その下に送れなかったわけ。送った
  // (sent が true) なら「「<answer>」を送った」の 1 行。key は段の札の id の後ろ (確かめは hp-sp-<key>、ボタンは hp-sps-<key>・hp-spc-<key>)
  pressBox(pk, m, key, c) {
    if (m.sent) return div().min_w(0).text_size(this.fs(11)).text_color(c.ok).child(`✓ 「${m.answer}」を送った`);
    const sending = this.sending === pk;
    const msg = str(this.stepMsg[pk]);
    // ダブルクリックの 2 回目は数えない (2 度送らない)
    const once = (fn) => (e, cx) => {
      if ((e?.click_count ?? 1) > 1) return;
      fn(cx);
    };
    return v_flex()
      .id(`hp-sp-${key}`)
      .min_w(0)
      .gap(this.fs(4))
      .px(this.fs(8))
      .py(this.fs(5))
      .rounded(this.fs(6))
      .border_1()
      .border_color(c.accent)
      .text_size(this.fs(11))
      .child(
        // 狭いときはボタンの組が字の次の行へ回る (右寄せ。ボタンは縮めない。字は縮んで折り返す)
        h_flex()
          .flex_wrap()
          .gap_x(8)
          .gap_y(4)
          .items_center()
          .child(div().flex_auto().min_w(0).text_color(c.fg).child(`「${m.answer}」を送る?`))
          .child(
            h_flex()
              .flex_none()
              .ml_auto()
              .gap(6)
              .items_center()
              .child(this.button(`hp-sps-${key}`, "送る", true, !this.busy, c, once((cx) => this.sendStep(pk, cx)), true))
              .child(this.button(`hp-spc-${key}`, "やめる", false, !sending, c, once((cx) => this.cancelStep(pk, cx)), true)),
          ),
      )
      .when(msg !== "", (el) => el.child(div().min_w(0).text_color(sending ? c.dim : c.warn).child(this.lines(msg))));
  }

  // 段を押した (①): 押した印を書いて確かめを出す。もう一度押すと「やめる」と同じ。送った段・送っている段は何もしない
  pressStep(info, cx) {
    const pk = pressKey(info.section, info.row, info.label, info.answer);
    if (this.sending === pk) return;
    const cur = this.sp.cur.get(pk);
    if (cur?.sent) return;
    if (cur) {
      this.cancelStep(pk, cx);
      return;
    }
    const entry = { section: info.section, row: info.row, label: info.label, answer: info.answer, at: new Date().toISOString(), sent: false };
    this.commitMarks(this.sp, (m) => (m.has(pk) ? null : new Map(m).set(pk, entry)), cx);
  }

  // 「やめる」: 何も送らず、押した印を外して確かめを閉じる (送った印は外さない。送っている段は何もしない)
  cancelStep(pk, cx) {
    if (this.sending === pk) return;
    delete this.stepMsg[pk];
    this.commitMarks(
      this.sp,
      (m) => {
        const e = m.get(pk);
        if (!e || e.sent) return null;
        const next = new Map(m);
        next.delete(pk);
        return next;
      },
      cx,
    );
  }

  // 「送る」: 押した段の answer を、問いの「送信」と同じ手 (pasteToTerminal) で送り、Enter まで押せたら印の sent を true にする。送れなければ
  // 確かめの中にわけを出し、印は sent が false のまま残す。送るのは 1 つずつ (問いの送信とも。busy)
  sendStep(pk, cx) {
    const m = this.sp.cur.get(pk);
    if (!m || m.sent || this.busy) return;
    this.busy = true;
    this.sending = pk;
    this.stepMsg[pk] = "送っています…";
    // await をまたぐ仕事は cx.spawn の cx でする (クリックの cx は、await の後には使えない)
    cx.spawn(async (cx) => {
      try {
        const res = await this.pasteToTerminal(m.answer, true);
        if (!res.ok) {
          this.stepMsg[pk] = res.msg;
          return;
        }
        delete this.stepMsg[pk];
        const op = (cur) => {
          const e = cur.get(pk);
          return !e || e.sent ? null : new Map(cur).set(pk, { ...e, sent: true });
        };
        this.stageMarks(this.sp, op);
        cx.notify();
        // 送ったことを書けなければ、印は sent が false に戻る (ハブは押した印からも数える)。わけは上の行 (印のファイルのわけ) にも出る
        if (!(await this.writeMarks(this.sp, op))) this.stepMsg[pk] = `${res.term} に送ったが、押した印に送ったことを書けない`;
      } catch (e) {
        this.stepMsg[pk] = `止まった: ${e}`;
      } finally {
        this.busy = false;
        this.sending = null;
        cx.notify();
      }
    });
    cx.notify();
  }

  // 図の場所: "mods/" で始まるものはそのまま (herdr-app の home から)、ほかは MEDIA の下から。
  // image() は herdr-app の home の外 (scratchpad など) を読めない (絶対パスを渡すと何も出ない)
  imagePath(src) {
    return src.startsWith("mods/") ? src : `${MEDIA}/${src}`;
  }

  // 図 (絵と、その上に重ねる marks) を k 倍で描く。panel のペインと大きく見る小窓で同じものを使う。decorate は、子を足す前の箱に
  // id やクリックを付ける関数。縮めない (flex_none。小窓の図の欄で縦に縮められると、marks が絵からずれる)
  figure(s, id, W, H, k, c, decorate = (el) => el) {
    const src = this.imagePath(s.src ?? "");
    const marks = (s.marks ?? []).map((m, mi) => this.mark(m, `${id}-${mi}`, k, c)).filter(Boolean);
    return decorate(div())
      .relative()
      .flex_none()
      .w(W * k)
      .h(H * k)
      .child(image(src).w(W * k).h(H * k))
      .children(marks);
  }

  // panel のペインの図。ペインの幅に合わせて縮め・大きくし (PIC)、クリックで大きく見る小窓を開く
  picture(s, id, c) {
    const W = sizeOr(s.width, 520);
    const H = sizeOr(s.height, 300);
    // on_size_change の幅はアプリの zoom を掛けた後の logical px、w()・h() の px は zoom を掛ける前の px なので、zoom で割ってから
    // 比べる (herdr-app の release notes の図も width / settings().zoom)。幅を知るまで (最初の描画) は等倍
    const avail = this.width == null ? null : this.width / appZoom() - PIC.pad;
    const k = avail == null ? 1 : clamp(avail / W, PIC.min, PIC.max);
    return v_flex()
      .gap(6)
      .child(
        this.figure(s, id, W, H, k, c, (el) =>
          el
            .id(`hp-pic-${id}`)
            .cursor_pointer()
            .hover((st) => st.opacity(0.9))
            .tooltip("クリックで大きく見る (Esc で閉じる)")
            .on_click((_, cx) => this.openBig(s, cx)),
        ),
      )
      .child(
        // 図の説明と、押すと大きく見られるというヒント。狭いときは説明が縮んで折り返し、ヒントは右に残る
        h_flex()
          .gap(8)
          .items_start()
          .when(!!s.caption, (el) =>
            el.child(div().flex_1().min_w(0).text_size(this.fs(11)).text_color(c.muted).child(TextView.markdown(`hp-cap-${id}`, s.caption))),
          )
          .child(div().flex_none().ml_auto().text_size(this.fs(10)).text_color(c.dim).child("クリックで拡大")),
      );
  }

  // 図を大きく見る小窓を開く。開くのはこの mod (MOD の名前) で、props.image に図の節を渡す。写しを試すときは MOD を写しの名前に
  // 書き換える (書き換えないと、写しの図から本物の pjp-hub-panel の小窓が開く)
  openBig(s, cx) {
    try {
      openOverlay({ mod: NAME, kind: BIG.kind, width: BIG.width, height: BIG.height, props: { image: s } });
      // 前に開けなかったわけが残っていれば消す (ほかのわけは残す)
      if (this.status.startsWith(BIG_FAIL)) {
        this.status = "";
        cx.notify();
      }
    } catch (e) {
      this.status = `${BIG_FAIL}: ${e}`;
      cx.notify();
    }
  }

  // 大きく見る小窓を閉じる (1 回だけ)。herdr-app が閉じた後 (close が呼ばれた後) は何もしない
  closeBig() {
    if (this.bigClosed) return;
    this.bigClosed = true;
    const id = props()?.overlay;
    if (id != null) closeOverlay(id);
  }

  // herdr-app がこの写しを閉じるとき (ペインや小窓が閉じた。Esc や外のクリックで閉じた小窓も) に 1 回呼ばれる
  async close() {
    this.bigClosed = true;
  }

  // 大きく見る小窓。上の行に図の題・閉じ方・「閉じる」、まん中の欄に図 (欄に縦横とも収める)、下に図の説明
  renderBig(c) {
    const s = this.big;
    const W = sizeOr(s.width, 520);
    const H = sizeOr(s.height, 300);
    const z = appZoom();
    const box = this.bigBox;
    // 図の欄の大きさ (zoom で割った px) に縦横とも収める。欄の大きさを知るまで (最初の描画) は等倍
    const k = box ? clamp(Math.min(box.width / z / W, box.height / z / H), PIC.min, BIG.max) : 1;
    return v_flex()
      .id("hp-big")
      .track_focus(this.handle)
      .on_key_down((e, cx) => {
        if (e.key !== "escape") return;
        this.closeBig();
        cx.stop_propagation();
      })
      .size_full()
      .min_h(0)
      .p(12)
      .gap(8)
      .bg(c.t.popover ?? c.surface) // herdr-app の dialog の mod (confirm・worktree) と同じく、地を塗る
      .text_size(this.fs(13))
      .text_color(c.fg)
      .child(
        h_flex()
          .gap(8)
          .items_center()
          .child(div().flex_1().min_w(0).text_size(this.fs(15)).font_semibold().child(s.title ?? ""))
          .child(div().flex_none().text_size(this.fs(11)).text_color(c.dim).child("Esc・図のクリックで閉じる"))
          .child(this.button("hp-big-close", "閉じる", false, true, c, () => this.closeBig())),
      )
      .child(
        // 図の欄: 残りの高さを取り (flex_1・min_h(0))、図に押し広げられない (overflow_hidden)。図はまん中に置く
        v_flex()
          .id("hp-big-body")
          .flex_1()
          .min_h(0)
          .min_w(0)
          .overflow_hidden()
          .items_center()
          .justify_center()
          .cursor_pointer()
          // ダブルクリックの 2 回目は数えない (panel の図をダブルクリックすると、2 回目が開いたばかりの小窓に落ちる)
          .on_click((e) => {
            if ((e?.click_count ?? 1) > 1) return;
            this.closeBig();
          })
          .on_size_change((size, cx) => {
            const b = this.bigBox;
            if (!b || Math.abs(b.width - size.width) > 1 || Math.abs(b.height - size.height) > 1) {
              this.bigBox = { width: size.width, height: size.height };
              cx.notify();
            }
          })
          .child(this.figure(s, s.id ?? "big", W, H, k, c)),
      )
      .when(!!s.caption, (el) =>
        el.child(div().text_size(this.fs(12)).text_color(c.muted).child(TextView.markdown("hp-big-cap", s.caption).selectable(true))),
      );
  }

  mark(m, key, k, c) {
    const color = this.paint(c, m.color, c.accent);
    if (m.kind === "flow") {
      // 一方向に流れる点。loop は行って戻るので向きを出せない。点を並べた輪 (ring.svg) を spin で回し、矢印の外接矩形で
      // 切り抜く。輪の点の通り道が矢印の中点で矢印に接し、時計回りの向きが矢印の向きになるように輪の中心を置く。
      // 輪の倍率は 2 の 1/4 乗の刻みに丸める (svg() は描く大きさごとに絵を作って持つ。ペインの境を動かしても作る絵の数を抑える)
      const s = Math.max(2 ** (Math.round(Math.log2(Math.max(k, 0.6)) * 4) / 4), 0.6);
      const D = 600 * s; // ring.svg の大きさ
      const R0 = 292 * s; // 点の通り道の半径
      const pad = 4 * s + 1; // 点の半径 + 1
      const x1 = m.x1 * k, y1 = m.y1 * k, x2 = m.x2 * k, y2 = m.y2 * k;
      const len = Math.hypot(x2 - x1, y2 - y1) || 1;
      const ux = (x2 - x1) / len, uy = (y2 - y1) / len;
      const phi = Math.atan2(-ux, uy); // 時計回りの接線が (ux, uy) になる輪の上の角
      const cx = (x1 + x2) / 2 - R0 * Math.cos(phi);
      const cy = (y1 + y2) / 2 - R0 * Math.sin(phi);
      // 切り抜きは矢印の向きと直角の側にだけ広げる (縦の矢印なら左右だけ)。点は矢印の端で切れ、箱から出て箱へ入って見える
      const padX = pad * Math.abs(uy);
      const padY = pad * Math.abs(ux);
      const left = Math.min(x1, x2) - padX;
      const top = Math.min(y1, y2) - padY;
      const period = Math.max(100, Math.round(((2 * Math.PI * R0) / (m.speed ?? 40)) * 1000));
      return div()
        .id(`hp-mk-${key}`)
        .absolute()
        .left(left)
        .top(top)
        .w(Math.abs(x2 - x1) + 2 * padX)
        .h(Math.abs(y2 - y1) + 2 * padY)
        .overflow_hidden()
        .child(svg(`${MOD}/ring.svg`).absolute().left(cx - D / 2 - left).top(cy - D / 2 - top).size(D).text_color(color).spin(period));
    }
    if (m.kind === "pulse") {
      return div()
        .id(`hp-mk-${key}`)
        .absolute()
        .left(m.x * k)
        .top(m.y * k)
        .w(m.w * k)
        .h(m.h * k)
        .rounded((m.radius ?? 8) * k)
        .border_2()
        .border_color(color)
        .loop("opacity", { from: 0.15, to: 1, period: m.period ?? 1600 });
    }
    if (m.kind === "dot") {
      const size = (m.size ?? 9) * Math.max(k, 0.6);
      const half = size / 2;
      let el = div()
        .id(`hp-mk-${key}`)
        .absolute()
        .left(m.x1 * k - half)
        .top(m.y1 * k - half)
        .w(size)
        .h(size)
        .rounded(size)
        .bg(color);
      const period = m.period ?? 2200;
      if (m.x1 !== m.x2) el = el.loop("left", { from: m.x1 * k - half, to: m.x2 * k - half, period, easing: "linear" });
      if (m.y1 !== m.y2) el = el.loop("top", { from: m.y1 * k - half, to: m.y2 * k - half, period, easing: "linear" });
      return el;
    }
    if (m.kind === "label") {
      return div()
        .absolute()
        .left(m.x * k)
        .top(m.y * k)
        .text_size(Math.max(9, (m.size ?? 12) * k))
        .text_color(this.paint(c, m.color, c.fg))
        .child(m.text ?? "");
    }
    return null;
  }

  // ボタン。small は段の確かめの小さなボタン (高さ・余白・角・字を小さく)
  button(id, label, primary, enabled, c, onClick, small = false) {
    return h_flex()
      .id(id)
      .flex_none()
      .h(this.fs(small ? 22 : 30))
      .px(this.fs(small ? 8 : 12))
      .items_center()
      .rounded(this.fs(small ? 6 : 8))
      .border_1()
      .border_color(primary && enabled ? c.solid : c.border)
      .bg(primary && enabled ? c.solid : c.raised)
      .text_color(enabled ? (primary ? c.solidFg : c.fg) : c.dim)
      .text_size(this.fs(small ? 11 : 12))
      .when(enabled, (el) => el.cursor_pointer().hover((s) => s.opacity(0.88)).on_click(onClick))
      .child(label);
  }

  // 上の行の「− <今の %> +」。押すと panel の文字だけを 1 刻みずつ上げ下げし、% で既定に戻す (アプリの zoom は替えない)。
  // 組の大きさは panel の % に従わない (atBase)。% の札は「200%」が入る幅を初めから取る。どちらも、押しても組の幅が変わらず、
  // 右に寄せた組の「−」と「%」がポインタの下から動かないため
  zoomControls(z, c) {
    const seg = (id, label, tip, enabled, onClick, color, offColor = c.dim) =>
      h_flex()
        .id(id)
        .flex_none()
        .h(atBase(22))
        .min_w(atBase(22))
        .px(atBase(5))
        .justify_center()
        .items_center()
        .rounded(atBase(5))
        .text_size(atBase(12))
        .text_color(enabled ? color : offColor)
        .tooltip(tip)
        .when(enabled, (el) => el.cursor_pointer().hover((s) => s.bg(c.raised)).on_click(onClick))
        .child(label);
    const changed = z !== ZOOM.def;
    // 押したときの % は、描いたときの z でなく shared から読み直す (描き直す前に 2 回押しても 2 刻み進む)
    const step = (dir) => (_, cx) => this.setZoom(zoomStep(this.zoom(), dir), cx);
    return h_flex()
      .id("hp-zoom")
      .flex_none()
      .gap(atBase(2))
      .p(1)
      .items_center()
      .rounded(atBase(6))
      .border_1()
      .border_color(c.border)
      .child(seg("hp-zoom-out", "−", `panel の文字を小さく (${ZOOM.min}% まで)`, z > ZOOM.min, step(-1), c.fg))
      .child(
        seg(
          "hp-zoom-reset",
          `${z}%`,
          changed ? `既定 (${ZOOM.def}%) に戻す` : `panel の文字の大きさ (既定 ${ZOOM.def}%)`,
          changed,
          (_, cx) => this.setZoom(ZOOM.def, cx),
          c.accent, // 既定から変えているときは accent で出し、押すと戻せると分かるようにする
          c.muted,
        ).min_w(atBase(46)),
      )
      .child(seg("hp-zoom-in", "+", `panel の文字を大きく (${ZOOM.max}% まで)`, z < ZOOM.max, step(1), c.fg));
  }

  render(cx) {
    const c = this.colors();
    const z = this.zoom();
    this.k = (TEXT_BASE * z) / 100; // この描画の fs() の倍率
    if (this.big) return this.renderBig(c);
    const d = this.data;
    const role = this.role();
    const known = role === null || ROLES.includes(role);
    const r = known ? role : null; // 知らない値は、無いときと同じに出す
    const qs = r === "summary" ? [] : (d?.questions ?? []);
    const secs = r === "questions" ? [] : (d?.sections ?? []);
    const text = r === "summary" ? "" : this.answerText();
    const ready = !!text && !this.busy;

    const body = [];
    if (!known) body.push(div().text_color(c.blocked).child(`props.role が分からない: ${JSON.stringify(role)} (summary か questions。無ければ両方を出す)`));
    if (this.error) body.push(div().text_color(c.blocked).child(this.error));
    // 印のファイル (消す印・押した印) を読み書きできなかったわけ
    if (this.marksOn()) for (const b of [this.dm, this.sp]) if (b.error) body.push(div().text_color(c.blocked).child(b.error));
    if (r === "questions") {
      qs.forEach((q, qi) => body.push(this.questionCard(q, qi, c)));
      if (!this.error && d && qs.length === 0) body.push(div().text_color(c.muted).child("問いはありません"));
    } else {
      if (qs.length > 0) {
        body.push(div().text_size(this.fs(12)).font_semibold().text_color(c.accent).child(`質問 (${qs.length})`));
        qs.forEach((q, qi) => body.push(this.questionCard(q, qi, c)));
      }
      // 消す印を付けた後に panel.json が変わった節は出さない (頭のコメントの「節を消す印」)
      const shown = this.shownSections(secs);
      if (shown.length > 0) {
        if (qs.length > 0) body.push(div().h(4), div().text_size(this.fs(12)).font_semibold().text_color(c.muted).child("いまの状況"));
        shown.forEach(({ s, i }) => body.push(this.section(s, i, c)));
      }
      if (!this.error && d && qs.length === 0 && shown.length === 0) body.push(div().text_color(c.muted).child("出すものはありません"));
    }
    // 上の帯の題。問いのペインは見出しと件数 (updated も出さない)、ほかは panel.json の title
    const heading = r === "questions" ? (qs.length > 0 ? `問い (${qs.length})` : "問い") : (d?.title ?? "ハブ");

    const hint = this.status || (text ? "Enter (このペインで) か「送信」で送る" : "");
    const footer =
      qs.length === 0
        ? null
        : v_flex()
            .px(14)
            .py(10)
            .gap(8)
            .border_t_1()
            .border_color(c.border)
            // 答えは問いごとに 1 行 (貼る文と同じく改行で区切る)
            .child(div().text_size(this.fs(12)).text_color(text ? c.fg : c.dim).child(text ? this.lines(text) : "選択肢を選ぶと、ここに答えの文が出ます"))
            .child(
              // 狭いときはボタンの組がわけの字の次の行へ回り、組も入らなければ「送信」が次の行へ回る (どちらも右寄せ。ボタンは
              // 縮めない。わけの字は縮んで折り返す)
              h_flex()
                .flex_wrap()
                .gap(8)
                .items_center()
                .when(hint !== "", (el) => el.child(div().flex_auto().min_w(0).text_size(this.fs(11)).text_color(c.dim).child(this.lines(hint))))
                .child(
                  h_flex()
                    .min_w(0)
                    .ml_auto()
                    .flex_wrap()
                    .justify_end()
                    .gap(8)
                    .items_center()
                    .child(this.button("hp-paste", "入力欄に入れる", false, ready, c, (_, cx) => this.deliver(cx, false)))
                    .child(this.button("hp-send", "送信", true, ready, c, (_, cx) => this.deliver(cx, true))),
                ),
            );

    return v_flex()
      .id("hp")
      .track_focus(this.handle)
      .on_key_down((e, cx) => {
        // まとめのペインは送らない (Enter も素通し)
        if (e.key !== "enter" || r === "summary") return;
        if (ready) this.deliver(cx, true);
        cx.stop_propagation();
      })
      .on_size_change((size, cx) => {
        if (this.width === null || Math.abs(this.width - size.width) > 1) {
          this.width = size.width;
          cx.notify();
        }
      })
      .size_full()
      .min_h(0)
      .text_size(this.fs(13))
      .text_color(c.fg)
      .child(
        // 上の行: 題と更新の時刻の欄 | 文字の大きさの組。組は折り返さずに右上に留め (items_start)、押しても動かない。
        // 狭いときは欄の中で、更新の時刻が次の行へ回り、題は縮んで折り返す
        h_flex()
          .px(14)
          .py(10)
          .gap(8)
          .items_start()
          .border_b_1()
          .border_color(c.border)
          .child(
            h_flex()
              .flex_1()
              .min_w(0)
              .min_h(BAR_H) // 1 行の題を組と上下の中ほどにそろえる (題が組より高くなれば欄が伸び、組は上に留まる)
              .flex_wrap()
              .content_center()
              .gap_x(8)
              .gap_y(2)
              .items_center()
              .child(div().flex_auto().min_w(0).text_size(this.fs(15)).font_semibold().child(heading))
              .when(r !== "questions" && !!d?.updated, (el) =>
                el.child(div().flex_none().ml_auto().text_size(this.fs(11)).text_color(c.dim).child(d.updated)),
              ),
          )
          .child(this.zoomControls(z, c)),
      )
      .child(v_flex().id("hp-list").flex_1().min_h(0).overflow_y_scrollbar().p(12).gap(10).children(body))
      .when(!!footer, (el) => el.child(footer))
      .when(!footer && !!this.status, (el) =>
        el.child(div().px(14).py(6).border_t_1().border_color(c.border).text_size(this.fs(11)).text_color(c.dim).child(this.lines(this.status))),
      );
  }
}
