---
name: pjp-hc-hub-panel
description: >-
  herdr-app のハブ (`HC_TERMINAL_ID` があり、ハブかその worktree にいる会話) で、panel (herdr-app の mod `pjp-hub-panel` の
  まとめのペイン) を開く・開き直して今の状況を書くときに使う。ユーザーが `/pjp-hc-hub-panel` と打った・「panel を開いて」と
  言ったとき、mod があるのに panel を開いていないと気づいたとき、panel が「見張れない」「ファイルが無い」と出たままのときに読む
metadata:
  pjp-pack: hc
---

# pjp-hc-hub-panel

ハブの会話で panel を開き忘れたときに、開かせる (開いていれば今の状況に書き直させる) ための入口。手順の正は
`pjp-hc-hub` の `references/panel.md` で、ここには写さない (写すと食い違う)。図の描き方は同じ skill の
`references/panel-figures.md`。

1. `pjp-hc-hub` をこの会話でまだ読んでいなければ読む (ハブの決まりと、panel の段落)
2. `references/panel.md` の「いつ使うか」で、panel を使えるハブ (mod のあるハブ) かを確かめる。使えなければ、そう 1 行で返して
   返答の文だけで進める
3. 控え (panes.json) を読み、どちらかに進む。読む節は panel.md の見出しのとおり:
   - まとめのペインが無い (控えが無い・`summary` が空): 「書き方」と「チケット・進み具合・PR」で今の状況を panel.json に書き、
     「開く (まとめのペイン)」で開く
   - まとめのペインがある: props (file・terminal) が今の scratchpad・`HC_TERMINAL_ID` と違う、panel が「見張れない」「ファイルが
     無い」と出たまま、控えに `terminalPane` が無い、のどれかなら「開き直す・置き場所を移す」で開き直す。どれでもなければ
     ペインはそのままで、「書き方」と「チケット・進み具合・PR」で panel.json を今の状況に書き直す
4. 答えていない問いがあれば「問いを出す」で問いのペインも出す
