---
name: pjp-pack-hc
description: herdr-app と hc のハブ (pjp-hc-hub) の会話で、panel (herdr-app の mod pjp-hub-panel) を開き忘れた・開き直す・今の状況に書き直すときに、最初に読む
---

# hc の pack の入口

常駐でない skill は、skill の一覧では名前だけになっている (説明が出ない)。ここで選び、名前で呼ぶ (Skill tool に
名前を渡せば、一覧に説明が無くても本文が読み込まれる)。この pack はハブ (`~/h`) でも説明つきにせず、名前だけのまま置く。

ハブの決まりと panel の手順そのものは、常駐の `pjp-hc-hub` (panel は `references/panel.md`)。子を立てる・別の repo を触るのは、
常駐の `pjp-hc-child`。この pack は、ハブで決まった操作をユーザーが `/` で名指しして呼ぶための入口を集める。

| すること | 呼ぶ skill |
| --- | --- |
| ハブの panel を開く・開き直して今の状況を書く (開き忘れたとき) | `pjp-hc-hub-panel` (ユーザーが `/pjp-hc-hub-panel` と打つ) |

## pjp-hc-hub-panel

- いつ: herdr-app のハブの会話で、mod `pjp-hub-panel` があるのに panel を開いていないとき・ユーザーが「panel を開いて」と言ったとき・
  panel が「見張れない」「ファイルが無い」と出たままのとき。ユーザーが `/pjp-hc-hub-panel` と打ったとき
- 中身: `pjp-hc-hub` の `references/panel.md` の「開く」「開き直す・置き場所を移す」「書き方」「チケット・進み具合・PR」を指し、
  panel が無ければ開き、あれば今の状況に書き直させる (手順は写さない)
- 呼び方: Skill tool で `pjp-hc-hub-panel` を名前で呼ぶ。ユーザーは `/pjp-hc-hub-panel`
- 置き場所: dotfiles (`nix/files/claude/skills/pjp-hc-hub-panel`)
