# ADR: 解説動画を答えを待たずに作り始めるかを host option で切り替え、既定は作る前に聞く

| 項目 | 内容 |
| --- | --- |
| ステータス | 承認 (Accepted) — 方針は 2026-10-18 にユーザーが承認 (同じ日に前提を訂正して承認し直した)。文面は PR でレビュー |
| 日付 | 2026-10-18 (JST) |
| 決定者 | pollenjp |
| チケット | [TKT-211](https://app.notion.com/p/flake-option-off-3fd79149a66f8188b335e672d60582dd) |
| 関連 ADR | [011_claude_notion_profile](../011_claude_notion_profile_20260929T155545JST/README.md)（dotfiles の option の値を `~/.local/state/dotfiles/` の JSON に置き、claude-skills が読む形。この ADR も同じ形を使う） |
| 運用手順 | [`nix/README.md`「解説動画を作る場面を知らせるフック」](../../../nix/README.md#解説動画を作る場面を知らせるフック) |

---

## 1. 背景 (Context)

### やりたかったこと

設計を出したとき・PR を作ったときの解説動画は、はじめ「作るかを聞く」形で入れ (claude-skills の TKT-124)、
その後「短尺 (2〜3 分) を答えを待たずに裏の subagent で作り始め、作り始めてから確かめる」形に変えた (TKT-148)。
1 本ごとに subagent がコンテキストを大きく使うので、既定で作り始めるのをやめたい。ユーザーの言葉では次のとおり (TKT-211)。

> デフォで短尺動画を作るやつ。やっぱりtoken使いすぎるから local flake からオンオフ切り替えられるようにしたい。(default で off)

> デフォで短尺動画を作成するのをやめさせたいだけで、短尺動画を作るかをユーザー側に聞くことはして欲しい

やめたいのは「答えを待たずに作り始める」ことだけで、作るかを聞くことは続ける。

### 動きを決めているのは 3 か所

| 場所 | 実体 | 今の中身 |
| --- | --- | --- |
| ① CLAUDE.md の「解説動画を作る」の節 | `nix/files/claude/CLAUDE.md` (dotfiles。全マシン共通) | 「条件に合えば解説動画の短尺を答えを待たずに裏で作り始める」 |
| ② skill `pjp-video-explainer-offer` | claude-skills (`~/.claude/skills/` へ symlink) | 作る条件・作り始め方・確かめ方・届け方。TKT-148 で「聞く」流れを「作り始める」流れに置き換えた |
| ③ PostToolUse の hook `video-offer-nudge.sh` | `nix/files/claude/hooks/` (dotfiles) | PR の作成・タグ「設計」の cc-page・spec / ADR の新規作成で「② を読み、条件に合えば短尺を作り始めよ」と差し込む |

3 か所とも「作り始める」と言っているので、どれか 1 か所だけ変えると食い違う。マシンごとに選べるようにするには、
3 か所が同じ値を見る必要がある。

## 2. 決定 (Decision)

### A. 「答えを待たずに作り始めるか」を host option にし、既定は false

`dotfiles.claude.videoOffer.autoStart.enable` (bool、**既定 false**) を `home/options.nix` に足す。

| 値 | 設計を出したとき・PR を作ったとき |
| --- | --- |
| false (既定) | 作る前に「解説動画を作りますか？」と聞く (TKT-124 の聞き方)。作るのは選ばれたときだけ |
| true | 答えを待たずに短尺を作り始め、作り始めてから「このまま作るか」を確かめる (TKT-148 の流れ) |

- 使うマシンはローカル flake の `local` に `dotfiles.claude.videoOffer.autoStart.enable = true;` を書く。
  雛形 (`setup-local-flake.sh`) にはコメントアウトした例だけ置く
- 登録簿のホストを直接指すなら `mkHome` の既存の `claude` 引数で渡す (`claude.videoOffer.autoStart.enable = true;`)
- module の既定そのものを false にする。`devTracker.enable` のように「module の既定は true・雛形が false」にすると、
  雛形は初回にしか書かれないので、既にある `~/dotfiles/flake.nix` のマシンが作り始めるまま残る
- 名前は skill (`pjp-video-explainer-offer`)・hook (`video-offer-nudge.sh`) に揃えた `videoOffer` の下に置く

### B. 値は `~/.local/state/dotfiles/claude-video-offer.json` に置き、② と ③ が読む

`home/modules/claude.nix` が `{"autoStart": <bool>}` + 改行を必ず書く。Notion の宛先の `claude-notion.json`
(ADR 011) と同じく、dotfiles の option の値を claude-skills に渡す置き場で、`home-manager switch` だけで効く
(settings.json を通さないので bootstrap は要らない)。

| 読む側 | `autoStart` が false・ファイルが無い・壊れている | `autoStart` が true |
| --- | --- | --- |
| ② skill | 作る前に聞く (D) | 答えを待たずに短尺を作り始める (今の流れ) |
| ③ hook | 「作る条件に合えば、…解説動画を作るかを聞くこと」 | 「作る条件に合えば、…解説動画の短尺を裏で作り始めること」 |

- ファイルが無い・壊れている・`autoStart` が真偽値の true でないときは、聞く側に倒す。dotfiles の古いマシンや、
  dotfiles の無いマシンでも、頼んでいない動画を作り始めない
- ① は値を読まない。文を 1 つにし、「条件に合えば解説動画を作るかを聞く。答えを待たずに短尺を作り始めるのは、
  dotfiles でそう設定したマシンだけ (どちらにするかは skill が決める)」とする。① は skill を読ませる入口で、
  どちらの流れにするかは ② が値を見て決める

### C. skill の見え方と CLAUDE.md の節は変えない

聞くには ② を読む必要があるので、`skillOverrides` で ② を隠さず、① の節も全マシンに残す。
③ の登録 (`bootstrap-claude-hook.sh`) も変えない。

### D. 作る前に聞く流れ (② の既定)

TKT-124 の聞き方を、TKT-148 で足した「承認してほしいことを先に書く」「出来たら詳細版も作るか聞く」に合わせて戻す。

- 問いは AskUserQuestion の 1 問 (header「解説動画」)。設計は承認を聞く前、PR は URL を返すとき
- 選択肢は「短く作る (2〜3 分)」「詳しく作る (5〜8 分)」「今回は作らない」「このセッションでは聞かない」
- 作ると選ばれたら、そのときから subagent が作る。設計の承認は動画を渡すときに聞く (TKT-148 と同じ)。
  作らないなら、続けてそのまま承認を聞く
- 「このセッションでは聞かない」は、今の「このセッションでは作らない」と同じ印のファイル
  (`pjp-video-offer/off-<session_id>`) を置く。③ もその印で黙る
- 指揮役から動かされる worker は、問いを報告に書き、答えが届くまで作らない

### E. hook の `skillOverrides` の確かめは残す

③ は、user の `settings.json` の `skillOverrides` で ② が `off` か `user-invocable-only` (Claude が skill を呼べない値)
なら黙る。option とは関係なく、手で ② を止めたマシンで「呼べない skill を読め」と知らせないため。
`skillOverrides` の値は `on` / `name-only` / `user-invocable-only` / `off` の 4 つ (公式 docs `skills` の
「Override skill visibility from settings」)。

### F. 方針の承認のあとに、こちらで決めたこと

| 問い | 決めたこと | 理由 |
| --- | --- | --- |
| hook の文を値で切り替えるか、どちらにも合う 1 つの文 (「skill のとおりに」) にするか | 値で切り替える | ユーザーに示した方針どおり。文が「作るかを聞くこと」と直に言う方が、Claude が取り違えにくい。② と ③ は同じファイルを読むので食い違わない |
| ① の文を値で切り替えるか | 切り替えない (1 つの文) | ② が値を読む以上、① まで値で作り分けると読む場所が 2 つになる。Nix で断片を連結する仕組みも要らなくなる |
| 「全部止める」(聞きもしない) を option に持たせるか | 持たせない | 頼まれていない。止めたいマシンは `skillOverrides` で ② を手で off にすれば、③ も黙る (E) |
| ADR の番号 | 023 | 021 と 022 は open の PR (#136・#137) が使っている |
| dotfiles と claude-skills の PR の merge の順 | **claude-skills → dotfiles** の順で続けて merge する | claude-skills が先なら、新しい ② が値を読み、状態ファイルの無い間は聞く側に倒れる (古い ① の「作り始める」より ② の §2 が決める)。dotfiles が先だと、古い ② はいつも作り始め、新しい ① は「skill が決める」と任せるので、作り始めてしまう。claude-skills の clone は symlink なので pull したとき、dotfiles は `switch` したときに効く |
| 書き直した設計を別の目 (builder check) に読ませるか | 自分で読んで足りない点を埋めた | 1 回目の builder check と最終レビューで、3 か所の関係と hook の入力の扱いは確かめてある。変わったのは値の渡し方と ② の流れで、最終レビューで見る |

## 3. 変更点の詳細

dotfiles:

| ファイル | 変更 |
| --- | --- |
| `nix/home/options.nix` | `dotfiles.claude.videoOffer.autoStart.enable` (bool、既定 false) を追加 |
| `nix/home/modules/claude.nix` | `~/.local/state/dotfiles/claude-video-offer.json` を置く。hook のコメント |
| `nix/files/claude/CLAUDE.md` | 「解説動画を作る」の節を「解説動画を作るか聞く」に直す (A・B の文) |
| `nix/files/claude/hooks/video-offer-nudge.sh` | `claude-video-offer.json` の `autoStart` で文を切り替える。`skillOverrides` で skill が呼べないなら黙る |
| `nix/tests/claude-video-offer.nix` | 新規。option の既定・生成 JSON・CLAUDE.md の節が値によらないこと・skill を隠さないことを評価時に確かめる |
| `nix/tests/video-offer-nudge.test.sh` | 値ごとの文、`skillOverrides` の値ごとに黙る・知らせるを足す |
| `nix/flake.nix` | checks に `claude-video-offer-state` |
| `nix/scripts/setup-local-flake.sh` | 雛形の `local` にコメントアウトした `videoOffer.autoStart.enable = true` の例 |
| `nix/lib/mk-home.nix` / `nix/hosts/default.nix` | `claude` 引数の説明 |
| `nix/scripts/bootstrap-claude-skill-overrides.sh` | コメントの `/skills` の記述を直す (処理は変えない。G) |
| `nix/README.md` | 配置の表・解説動画のフック・ローカル flake の `local`・`/skills` の記述 (G) |
| `docs/adr/007_…/README.md` | 冒頭に、`/skills` の記述が当たらないことを書いた後続 ADR のポインタ (G) |

claude-skills:

| ファイル | 変更 |
| --- | --- |
| `skills/pjp-video-explainer-offer/SKILL.md` | 値を読み、false (既定) なら作る前に聞く流れ (D)、true なら今の流れ |
| `skills/pjp-video-explainer-offer/references/brief.md` | 同意の文 (A) / (B) の選び方を、聞いて選ばれた短尺も (B) と読めるようにする |

### G. ついでに直した記述

ADR 007 と README・`bootstrap-claude-skill-overrides.sh` のコメントは「`/skills` で変えても次の update で戻る」と
書いていたが、`/skills` の切り替えは project の `.claude/settings.local.json` に保存され、user の値より優先される
(公式 docs と、手元の 2.1.302)。この作業で分かったので、README とコメントを直し、ADR 007 に後続 ADR のポインタを置く。

## 4. 検討した代替案

| 案 | 採らなかった理由 |
| --- | --- |
| option で解説動画の仕組みごと止める (`skillOverrides` で ② を off・① の節を外す・③ を黙らせる。この PR の最初の形) | 聞くことまで止まる。ユーザーがやめたいのは既定で作り始めることだけ |
| module の既定は true のまま、雛形だけ false | 雛形は初回にしか書かれないので、既にある `~/dotfiles/flake.nix` のマシンは作り始めるまま残る |
| 値を settings.json の `env` で渡す (`bootstrap-claude-env.sh`) | 反映が 2 段になり、Bash tool のすべてのコマンドに env が見える。claude-skills が dotfiles の値を読む形は ADR 011 の state の JSON が先にある |
| ① を値で作り分ける (2 つの断片を Nix で連結) | ② が値を読む以上、読む場所が 2 つになる (F) |
| ③ の文を値によらない 1 つにする | F |
| option を 3 値 (聞く / 作り始める / 止める) にする | 止めるは頼まれていない。手で止める道は E で残る |

## 5. 影響 (Consequences)

良くなること。

- 既定では頼んでいない動画を作り始めず、作るかは聞かれる。作り始める動きに戻すのは `local` の 1 行
- ①②③ が同じ値に従う。値は `switch` だけで効く

注意が必要なこと。

- **今作り始める動きのマシンは、この変更を取り込むと「先に聞く」に変わる**。作り始めるまま使うマシンは `local` に true を書く
- dotfiles と claude-skills の 2 本は、**claude-skills → dotfiles** の順で続けて merge する。dotfiles だけ先に入ると、
  古い ② が答えを待たずに作り始める (§2 F)
- 動いているセッションの CLAUDE.md は起動したときのまま。新しいセッションから効く (② と ③ はファイルを読むたびに今の値を見る)

## 6. 検証 (Verification)

`feat/TKT-211-video-offer-toggle` (dotfiles) と `feat/TKT-211-video-offer-ask-first` (claude-skills) で実施。

| 確認 | 方法 | 結果 |
| --- | --- | --- |
| option の既定・生成 JSON・CLAUDE.md・skill を隠さないこと | `nix/tests/claude-video-offer.nix` (checks の `claude-video-offer-state`) | 9 / 9。option を足す前は評価が `attribute 'autoStart' missing` で落ちることを先に確かめた |
| hook の文が値ごとに変わる・壊れたら聞く | `nix/tests/video-offer-nudge.test.sh` (checks の `video-offer-nudge-test`) | 31 / 31。既定 (ファイル無し)・false・壊れたファイル・文字列の `"true"` の「聞く」側は、hook を直す前に FAIL することを先に確かめた (main の hook に当てると 8 件が FAIL) |
| このマシンのローカル flake | `nix eval --no-write-lock-file --override-input dotfiles path:<repo>/nix ~/dotfiles#…"pollenjp@wsl"…` (lock は書き換えない) | `claude-video-offer.json` は `{"autoStart":false}`、skill-overrides は `{"pjp-dev-tracker":"on"}` だけ、CLAUDE.md は main と比べて解説動画の節の見出しと文だけが変わる |
| 雛形 | `DOTFILES_LOCAL_DIR` を使い捨ての dir にして `setup-local-flake.sh` で生成し、例の行のコメントを外して `nix eval` | 例の行がある。外すと `claude-video-offer.json` が `{"autoStart":true}` |
| skill の流れ (claude-skills) | 状態ファイルを決めた場面を subagent に渡し、SKILL.md のとおりに取る行動を並べさせた | 直す前の SKILL.md は、ファイルが無くても答えより前に短尺を作り始めた。直したあとは、ファイル無しの PR で先に 4 択で聞き、`{"autoStart":true}` の設計で作り始め、worker では答えが届くまで作らなかった |
| 静的 | 変えたファイルに `nixfmt --check` / `shfmt -d` / `shellcheck`、`check-test-headers.sh`、`check-test-grep-q.sh`、claude-skills の `scripts/lint.sh` | 指摘なし (lint.sh は 44 件 / エラー 0) |
| flake | `nix flake check --all-systems --no-build ./nix` | 通過 |
| コードレビュー (subagent) | 2 repo の差分をまとめて | Critical なし。Important 2 件 (brief.md の古い節番号・この §6 の空欄) と、格上げした 2 件 (merge の順・claude.nix のコメントの上下) を直した。「§3 で作り始めた動画を止めてと言われたときの定めが無い」は、直す前の SKILL.md で subagent に試させると §4 を当てはめて正しく止め、承認の問いも出したので、足さなかった。残りの Minor は PR に書いた |

## 7. 移行・運用手順

claude-skills → dotfiles の順で 2 本を merge したあとに:

```sh
~/dotfiles/setup --self-update --update      # dotfiles (switch で claude-video-offer.json と CLAUDE.md が変わる)
git -C "$(ghq root)/github.com/pollenjp/claude-skills" pull --ff-only   # claude-skills の skill
cat ~/.local/state/dotfiles/claude-video-offer.json                    # {"autoStart":false}
```

作り始める動きにしたいマシン:

```sh
$EDITOR ~/dotfiles/flake.nix      # local に dotfiles.claude.videoOffer.autoStart.enable = true;
~/dotfiles/setup --update         # {"autoStart":true} になる
```
