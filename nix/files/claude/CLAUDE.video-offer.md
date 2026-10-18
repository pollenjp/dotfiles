## 解説動画を作る

`pjp-video-explainer-offer` が skill の一覧にあるときだけ、まとまった設計を提案したとき・
PR を作ったときにその skill を読み、条件に合えば解説動画の短尺を答えを待たずに裏で作り始める。
一覧に無ければ何もしない (ファイルを探さない・作らない)。PR の作成・タグ「設計」の cc-page・
spec / ADR の書き出しは hook (`~/.claude/hooks/video-offer-nudge.sh`) も知らせてくる。
