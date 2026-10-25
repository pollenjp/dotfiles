# このリポジトリで作業するときの指示

## 設計の文書は dotfiles-private に書く

この repo は **public**。設計の文書は、ここに置かず private な dotfiles-private (`pollenjp/dotfiles-private`) の
`docs/` に書く。設計のやり取り (依頼の原文・問いと答え・検討した案・レビューの指摘) を public な repo に出さないため。

| 文書 | 置き場 (dotfiles-private の中) |
| --- | --- |
| spec (superpowers の brainstorming) | `docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md` |
| 実装計画 (superpowers の writing-plans) | `docs/superpowers/plans/YYYY-MM-DD-<feature>.md` |
| ADR とその textbook・図 | `docs/adr/<番号>_<題>_<時刻>JST/` (番号・名前・書き方は dotfiles-private の `docs/adr/README.md`) |

- superpowers の skill が既定の置き場 (この repo の `docs/superpowers/`) を言っても、上の表に書く (ユーザーの指定)
- 手元: `$(ghq root)/github.com/pollenjp/dotfiles-private` の clone から worktree を切り、branch で書いて PR を出す
  (clone が無ければ `ghq get pollenjp/dotfiles-private`)。cloud: session に dotfiles-private を足し、その clone に書く。
  取れなければ書かずにユーザーに伝える (この repo には置かない)
- 文書の PR は dotfiles-private に出し、この repo の PR より先か同時に merge する
- 指揮役から依頼を受けた子の会話でも、dotfiles-private への文書の commit・PR はこの作業の一部として自分でやる
  (指揮役に聞かない。報告には書く)
- コードのコメントや README の「ADR NNN」は、dotfiles-private の `docs/adr/` の ADR を指す
- この repo の `docs/` に書こうとすると hook (`nix/files/claude/hooks/docs-guard.sh`) が止め、CI の `lint` も `docs/` が
  あれば落ちる。Bash で書いて回り込まない

## この repo の PR・commit に書くもの

PR のタイトル・本文と commit の message は public に残る。

- 書く: 変えたこと・確かめたこと・反映の仕方と、文書の場所 (`dotfiles-private の docs/superpowers/specs/….md` のように
  パスで。dotfiles-private の PR の番号・URL・commit の SHA は書かない)
- 書かない: 依頼の原文・問いと答え・検討した案と捨てた理由・自分で決めたこと・レビューの指摘と直さずに残したこと。
  これらは dotfiles-private の PR の本文と ADR に書く (ユーザーへの報告では、自分で決めたことをいつもどおり並べる)
- PR のレビューへの返事は短く、事実だけにする (経緯は dotfiles-private の文書へ)
