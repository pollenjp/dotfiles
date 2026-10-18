# ADR: 解説動画を既定で作る仕組みを host option で切り替え、既定を off にする

| 項目 | 内容 |
| --- | --- |
| ステータス | 承認 (Accepted) — 方針は 2026-10-18 にユーザーが承認。文面は PR でレビュー |
| 日付 | 2026-10-18 (JST) |
| 決定者 | pollenjp |
| チケット | [TKT-211](https://app.notion.com/p/flake-option-off-3fd79149a66f8188b335e672d60582dd) |
| 前提 ADR | [007_claude_skill_host_option](../007_claude_skill_host_option_20260926T130250JST/README.md)（skill の on / off を host option に持たせ、settings.json へ流す経路） |
| 運用手順 | [`nix/README.md`「Claude Code の skill を host ごとに止める」](../../../nix/README.md#claude-code-の-skill-を-host-ごとに止める) |

---

## 1. 背景 (Context)

### やりたかったこと

設計を出したとき・PR を作ったときに、解説動画の短尺 (2〜3 分) を答えを待たずに裏の subagent で
作り始める仕組みがある (claude-skills の TKT-124 で入れ、TKT-148 で「聞く」から「作り始める」に変えた)。
1 本作るたびに subagent がコンテキストを大きく使う。ユーザーの言葉では次のとおり (TKT-211)。

> デフォで短尺動画を作るやつ。やっぱりtoken使いすぎるから local flake からオンオフ切り替えられるようにしたい。(default で off)

### 仕組みは 3 層で、置き場所がそれぞれ違う

| 層 | 実体 | 置き場所 |
| --- | --- | --- |
| ① CLAUDE.md の「解説動画を作る」の節 | `nix/files/claude/CLAUDE.md` | dotfiles。**全マシン共通** |
| ② skill `pjp-video-explainer-offer` | `~/.claude/skills/pjp-video-explainer-offer` (claude-skills の作業クローンへの symlink) | claude-skills。`bootstrap-claude-skills.sh` が張る |
| ③ PostToolUse の hook | `nix/files/claude/hooks/video-offer-nudge.sh` | dotfiles。登録は `bootstrap-claude-hook.sh` |

③ は PR の作成・タグ「設計」の cc-page・spec / ADR の新規作成を見つけ、「② を読み、条件に合えば短尺を
作り始めよ」と Claude の文脈へ 1 文を差し込む。① はその知らせが無いとき (会話の中で出し終えた設計など) の
ための正本。

### ADR 007 の経路だけでは ③ が止まらない

① と ② は ADR 007 で `pjp-dev-tracker` を止めたのと同じ経路で切れる (① は節を別ファイルに切り出して
option で連結、② は `settings.json` の `skillOverrides` を `"off"`)。

ところが ③ は `SKILL.md` が**あるかどうか**しか見ていない。`skillOverrides` で ② を切っても
`~/.claude/skills/` のファイルは残るので、③ は知らせ続ける。知らせを受けた Claude は skill を呼べず
(off の skill を呼ぶと「override を外せ」という文が返る)、`SKILL.md` を直接読んで作り始めうる。
3 層とも切らないと止まらない。

### 頼んだときの動画は別の話

ユーザーが「解説動画を作って」と名指しで頼んだときに読む `pjp-video-explainer-pictogram` /
`pjp-video-explainer-dialogue` は、作るかどうかをユーザーが決めている。token の問題は「頼んでいないのに
作る」ことなので、こちらは止めない。

## 2. 決定 (Decision)

### A. 「解説動画を既定で作るか」を host option にし、既定は false

`dotfiles.claude.videoOffer.enable` (bool、**既定 false**) を `home/options.nix` に足す。名前は
skill (`pjp-video-explainer-offer`)・hook (`video-offer-nudge.sh`)・印の dir (`pjp-video-offer/`) に揃える。

- 使うマシンはローカル flake の `local` に `dotfiles.claude.videoOffer.enable = true;` を書く。
  雛形 (`setup-local-flake.sh`) にはコメントアウトした例だけ置く
- 登録簿のホストを直接指すなら `mkHome` の既存の `claude` 引数で渡す (`claude.videoOffer.enable = true;`)
- module の既定そのものを false にする。`devTracker.enable` は「module の既定 true・雛形が false」だったが、
  雛形は初回にしか書かれないので、同じ形では既にある `~/dotfiles/flake.nix` のマシンが on のまま残る

### B. 1 つの値から 3 層が決まる

| 層 | enable = true | enable = false (既定) | 決める場所 |
| --- | --- | --- | --- |
| ① `~/.claude/CLAUDE.md` の「解説動画を作る」の節 | 連結 | 無し | `home/modules/claude.nix` (`files/claude/CLAUDE.video-offer.md` を連結) |
| ② `settings.json` の `skillOverrides.pjp-video-explainer-offer` | `"on"` | `"off"` | `claude-skill-overrides.json` → `bootstrap-claude-skill-overrides.sh` |
| ③ hook の知らせ | 今どおり | 黙る | `video-offer-nudge.sh` が `settings.json` の `skillOverrides` を見る (C) |

① の連結は「常時部分 + 空行 + 解説動画の節 + 空行 + タスク管理の節」(どちらも option が true のときだけ)。
両方 true なら、今の `~/.claude/CLAUDE.md` と**バイト単位で同じ**になる (今の CLAUDE.md は解説動画の節で
終わり、その後ろにタスク管理の節を連結しているため)。

② は ADR 007 の生成 JSON に key を 1 つ足すだけで、`bootstrap-claude-skill-overrides.sh` は変えない
(生成 JSON の key をそのまま merge する作りのため)。

### C. hook は Claude Code と同じ `settings.json` の `skillOverrides` を見て黙る

③ は `${CLAUDE_CONFIG_DIR:-~/.claude}/settings.json` の `.skillOverrides["pjp-video-explainer-offer"]` が、
Claude が skill を自分で呼べない値なら黙る。

| 値 | Claude が自分で呼べるか | ③ |
| --- | --- | --- |
| (無い) / `"on"` | 呼べる | 知らせる |
| `"name-only"` | 呼べる (一覧に名前だけ出る) | 知らせる |
| `"user-invocable-only"` | 呼べない (ユーザーの `/` からだけ) | 黙る |
| `"off"` | 呼べない (一覧からも `/` からも消える) | 黙る |

- dotfiles が書く値は `"on"` / `"off"` だけ。ほかの値は user の `settings.json` を手で書き換えたときに入る
- `settings.json` が無い・壊れている・知らない値なら、今どおり知らせる (止める判断を hook でしない。
  作るかどうかは今までどおり ② が決める)
- hook の登録 (`bootstrap-claude-hook.sh`) は変えない。黙る hook の費用は Write と `gh pr create` の
  たびのプロセス 1 回で、登録を出し入れする仕組みより小さい

dotfiles が置く望む値 (`~/.local/state/dotfiles/claude-skill-overrides.json`) ではなく `settings.json` を
見るのは、③ の役目が「② を読め」と知らせることだから。② の値を Claude Code に渡すのは user の
`settings.json` なので、hook も同じ場所を見れば、bootstrap のあとは ③ と ② が同じ値で動く。
hook が dotfiles の中間ファイルに依らずに済む (今も Claude Code のパスしか見ていない)。

見るのは user の `settings.json` だけで、Claude Code の優先順位 (managed・`--settings` → project の
`.claude/settings.local.json` → `.claude/settings.json` / user) はたどらない (こちらの判断。E)。

### D. 頼んだときの動画と、ほかの記述は止めない

- `pjp-video-explainer-pictogram` / `pjp-video-explainer-dialogue` の `skillOverrides` には触らない
- CLAUDE.md の「方針を承認したら PR まで走り切る」の節にある 1 行 (承認のあとに書く spec は解説動画の
  対象にしない) は残す。skill を名指ししておらず、動画を作らせる向きの文でもないため
- claude-skills は直さない (② を off にすれば Claude からは見えない)

### E. 設計のレビュー (builder check) の問いに、こちらで決めたこと

方針の承認のあと、この文書を別の目 (subagent) に読ませて出た問いを、ユーザーに戻さずに決めた。

| 問い | 決めたこと | 理由 |
| --- | --- | --- |
| hook は user の `settings.json` だけを見るか、Claude Code と同じ優先順位で値を引くか。`/skills` の切り替えは project の `.claude/settings.local.json` に保存され、user の値より優先される (公式 docs `skills` の「Override skill visibility from settings」と、手元の 2.1.302) | user の `settings.json` だけを見る | 切り替えの入口は option で、option が書くのは user の `settings.json`。option が true のマシンで `/skills` から ② を隠した project では知らせが来るが、CLAUDE.md の節が「一覧に無ければ何もしない」と止める。優先順位をたどると、project の dir の決め方と組み合わせのテストが増える |
| ADR の番号 | 023 | 021 と 022 は open の PR (#136・#137) が使っている |

## 3. 変更点の詳細

| ファイル | 変更 |
| --- | --- |
| `nix/home/options.nix` | `dotfiles.claude.videoOffer.enable` (bool、既定 false) を追加 |
| `nix/home/modules/claude.nix` | CLAUDE.md の連結に解説動画の節を足す。`claude-skill-overrides.json` に `pjp-video-explainer-offer` を足す |
| `nix/files/claude/CLAUDE.md` | 「解説動画を作る」の節を抜く (常時部分) |
| `nix/files/claude/CLAUDE.video-offer.md` | 新規。抜いた節そのもの |
| `nix/files/claude/hooks/video-offer-nudge.sh` | `settings.json` の `skillOverrides` で skill が呼べない値なら黙る |
| `nix/files/claude/hooks/nix-managed-guard.sh` | 案内文に断片ファイル `CLAUDE.video-offer.md` を足す |
| `nix/scripts/setup-local-flake.sh` | 雛形の `local` にコメントアウトした `videoOffer.enable = true` の例 |
| `nix/scripts/bootstrap-claude-skill-overrides.sh` | コメントと確認の案内に `pjp-video-explainer-offer` を足す (処理は変えない) |
| `nix/lib/mk-home.nix` / `nix/hosts/default.nix` | `claude` 引数の説明に `videoOffer.enable` を足す |
| `nix/tests/claude-skill-toggles.nix` | 新規。option の値ごとの CLAUDE.md の節と `claude-skill-overrides.json` を評価時に確かめる |
| `nix/tests/video-offer-nudge.test.sh` | `skillOverrides` の値ごとに黙る・知らせるを足す |
| `nix/flake.nix` | checks に `claude-skill-toggles` を足す |
| `nix/README.md` | 配置の表・解説動画のフック・ローカル flake の `local`・「Claude Code の skill を host ごとに止める」(2 つの option の表と 3 層の表。`/skills` の保存先の記述を今の docs に合わせる) |
| `docs/adr/007_…/README.md` | 冒頭に後続 ADR (この ADR) へのポインタ |
| `docs/adr/README.md` | 一覧に 023 |

## 4. 検討した代替案

| 案 | 採らなかった理由 |
| --- | --- |
| module の既定は true のまま、雛形だけ false (`devTracker.enable` と同じ形) | 雛形は初回にしか書かれないので、既にある `~/dotfiles/flake.nix` のマシンは on のまま残る。登録簿のホストを直接指しても on。「既定で off」にならない |
| hook の登録を option で出し入れする (`bootstrap-claude-hook.sh` が登録を消す) | 登録を消す仕組みと、settings.json に残った登録の後始末が増える。黙る hook の費用はプロセスの起動 1 回で小さい |
| hook の script を option で配らない | settings.json の登録が無いファイルを指し、Write のたびに hook のエラーになる |
| hook が `~/.local/state/dotfiles/claude-skill-overrides.json` (dotfiles が置く望む値) を見る | `switch` 直後から黙るが、bootstrap までは ② (settings.json) と違う値で動く。hook が dotfiles の中間ファイルに依る |
| hook が Claude Code と同じ優先順位 (project の `.claude/settings.local.json` など) で値を引く | §2 E |
| skill 側で印を見て降りる | ADR 007 と同じ理由。毎回 SKILL.md を読み込む token を払い、降りるかどうかを Claude の判断に委ねる |
| claude-skills から skill を外す・`disable-model-invocation: true` | skill は git で全マシンに配られるので、使いたいマシンでも止まる |
| 汎用の `dotfiles.claude.skillOverrides` (attrset をそのまま流す) | ADR 007 と同じ理由。CLAUDE.md の断片と hook との対応が名前規約頼みになる。専用 option の方が 3 層の対応が読める |

## 5. 影響 (Consequences)

良くなること。

- 頼んでいない解説動画を既定で作らない。使うマシンは `local` に 1 行足せば戻る
- ③ が ② と同じ user の `settings.json` を見るので、option で切ったマシンで「skill は見えないのに
  知らせは来る」状態が無くなる
- `skillOverrides` の値を option が持つ skill が 2 つになっても、bootstrap の script は変わらない

注意が必要なこと。

- **今動いているマシンは、この変更を取り込むと off になる**。使い続けるマシンは `local` に true を書く
- 反映は 2 段 (ADR 007 と同じ)。`switch` だけでは CLAUDE.md の節が消えるだけで、② と ③ は
  `bootstrap-claude-skill-overrides.sh` が settings.json を書くまで残る。`~/dotfiles/setup --update` で揃う
- user の `settings.json` の `skillOverrides.pjp-video-explainer-offer` は option が持つ。手で書き換えても
  次の `setup --update` で戻る。`/skills` の切り替えは project の `.claude/settings.local.json` に保存され、
  user の値より優先される (update では戻らない)
- ③ が見るのは user の `settings.json` だけ。project の設定 (`/skills` が書く `.claude/settings.local.json` を
  含む) で切っても ③ は黙らない。② は呼べないので、option が true なら CLAUDE.md の節が止める (§2 E)

## 6. 検証 (Verification)

`feat/TKT-211-video-offer-toggle` で実施。

| 確認 | 方法 | 結果 |
| --- | --- | --- |
| option の値ごとの CLAUDE.md と生成 JSON | `nix/tests/claude-skill-toggles.nix` (checks の `claude-skill-toggles`)。4 つの組み合わせ | 12 / 12。option を足す前は評価が `attribute 'videoOffer' missing` で落ちることを先に確かめた |
| 両方 true の CLAUDE.md が分割前と同じ | `lib.hostsWith [ { dotfiles.claude.videoOffer.enable = true; } ]` の `pollenjp@x86_64-linux` の CLAUDE.md を、`git show main:nix/files/claude/CLAUDE.md` + 空行 + `CLAUDE.dev-tracker.md` と `diff` | 差分なし |
| このマシンのローカル flake (`devTracker.enable = true`、videoOffer は書いていない) | `nix eval --no-write-lock-file --override-input dotfiles path:<repo>/nix ~/dotfiles#homeConfigurations."pollenjp@wsl"…` (lock は書き換えない) | CLAUDE.md は「タスク管理」だけ。JSON は `{"pjp-dev-tracker":"on","pjp-video-explainer-offer":"off"}` |
| hook が値ごとに黙る・知らせる | `nix/tests/video-offer-nudge.test.sh` (checks の `video-offer-nudge-test`) | 28 / 28。足した 6 ケースのうち off・user-invocable-only・symlink の 3 つは、hook を直す前に FAIL することを先に確かめた |
| 雛形 | `DOTFILES_LOCAL_DIR` を使い捨ての dir にして `setup-local-flake.sh` で生成し、例の行のコメントを外して `nix eval` | 例の行がある。外すと `videoOffer.enable` が `true` |
| 静的 | 変えたファイルに `nixfmt --check` / `shfmt -d` / `shellcheck`、`check-test-headers.sh`、`check-test-grep-q.sh` | 指摘なし |
| flake / activation | `./nix/scripts/verify.sh` (`nix flake check --all-systems --no-build` + 使い捨ての `$HOME` での activate) | `nix flake check --all-systems --no-build` と activate 2 回は通過し、配置一覧に `.claude/CLAUDE.md` と `.local/state/dotfiles/claude-skill-overrides.json` が出る。最後の `~/dotfiles` 参照の検査は main と同じ 11 件で落ちる (この変更で増減なし。ADR 007 §6 の既知の件) |

## 7. 移行・運用手順

既定 (off) のまま使う:

```sh
~/dotfiles/setup --update                                        # switch + bootstrap
jq '.skillOverrides["pjp-video-explainer-offer"]' ~/.claude/settings.json   # "off"
grep -c '解説動画を作る' ~/.claude/CLAUDE.md                        # 0
```

使うマシン (on にする):

```sh
$EDITOR ~/dotfiles/flake.nix      # local に dotfiles.claude.videoOffer.enable = true;
~/dotfiles/setup --update         # "on" が merge され、CLAUDE.md に節が戻る
```

実行中の Claude Code には効かない。新しいセッションから効く。
