# 子に Claude in Chrome を使わせる (hc 版)

`references/delegate.md` のうち、子に Claude in Chrome (Chrome の拡張で Claude がブラウザを操作する仕組み) を使わせるときに
hc 版で変わる所。ブラウザの側の決まり (ブラウザを選ぶ・ログインの受け渡し・書き換えは 2 段に分ける・画面に写る秘密の黒塗り
(`redact.sh`)・罠・依頼の雛形) は、旧版と同じなので pjp-herdr-other-repo の `references/chrome.md` の同じ名前の節を読む
(旧 herdr をやめる W4 で、こちらへ移す。pjp-herdr-other-repo は private な claude-skills の skill で、skill の一覧に無いホストでは読めない)。

**ユーザーの決まり (2026-11-15):** 子の claude は基本 `--no-chrome` で立て、Claude in Chrome を使わせる作業の子だけ `--chrome`
を付ける。

## 子の置き場所

- ブラウザだけの作業 (repo を変えない): 子のマシンの集約ハブ `~/h` (手元の WSL なら旧 herdr のハブ) から切った worktree。PR は無い

  ```text
  pjp child new --on wsl --checkout '~/h' --label 'h: <一言>' --agent <名前> --chrome --brief <依頼のファイル>
  ```

  - `--on wsl` は省かない (`wsl` は手元の WSL の machine を名前によらず選ぶ語。`references/delegate.md` の「起動する」の 1.)。
    Claude in Chrome は WSL の子で確かめた (下の「起動」)。`--chrome` の子は `--on` を省いても WSL だけから
    選ぶが、手順では WSL を名指しする
  - `~/h` に origin は無いので、`pjp child new` は fetch せずに今の branch (main) から切る
- repo も触る作業 (落としたファイルを repo に取り込むなど): ふつうの子と同じく `--repo <owner/repo>` の worktree に `--chrome`

## 起動

- `pjp child new … --chrome` (`--no-chrome` の代わりに `--chrome` が付く)。effort・pack の決め方はふつうの子と同じ
  (ブラウザだけの作業に当たる pack は無い)
- 起動直後に「Claude in Chrome」の案内の画面 (末尾が「Enter to confirm · Esc to cancel」) で止まることがある。`pjp child new` は
  画面を出して `!!` の行で知らせる。ユーザーが Claude in Chrome を使うよう頼んだ子なら `hc keys <子の端末> enter` で確定してよい
  (`references/common.md` の「答えてよい範囲」)。頼まれていない子の画面なら、確定せずにユーザーに聞く
- WSL の子は、Windows の Chrome に `--chrome` でつながった (旧 herdr の子で確かめた。公式の docs は WSL を未対応とするが、
  アカウントにつながったブラウザの経路でつながる)。hc の子で確かめたら、ここに書き足す

## 流れ (親がすること)

1. `pjp child new … --chrome` で子を立て、案内の画面が出たら確定する
2. 依頼は旧版の chrome.md の「依頼の雛形」で書き、hc の子に渡すので `references/common.md` の雛形の hc の行に合わせる:
   3 行目を「<ハブのマシン> の hc の端末 (この端末の hc の親) にいる指揮役」にし、進め方に `pjp child report "子 <英字>: <要旨>"` で
   知らせる行を、しないことにユーザーの Windows の画面と hc の session の行を足す
3. 子がログイン待ちで止まったら、ユーザーに頼んで済んだら子に知らせる (`pjp child send`)
4. 中間報告 (段階 1) が来たら、表をユーザーに見せ、OK と答えを子に送る

## 片付け

- PR の無い子は、merge を待たず、子の作業が済んだら (子の「## 報告」が来た。チケットのある子は Done になってから)
  `pjp child cleanup <英字> --no-pr`
- 片付ける前に、子の worktree に子の作ったものが残っていないかを見る (`hc exec --on <m> -- git -C <worktree の絶対パス> status --short --ignored`。
  `hc exec` は shell を通さないので `~` は使えない。絶対パスは `pjp child ls` の行の最後)。
  残っていれば子に scratchpad へ移させるか消させる (`pjp child cleanup` は `--ignored` のものまでは見ない。cc-page と scratchpad は
  worktree の外にあり、worktree を消しても残る)
- repo も触った子は、ふつうの子と同じく PR が merge されてから (`references/delegate.md` の「片付け」)
