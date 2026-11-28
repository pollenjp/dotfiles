# ここは集約ハブ (herdr-app・T3 Code と hc)

このディレクトリ (Windows では `%USERPROFILE%\h`) と、ここから切った worktree (herdr-app の「New worktree」の
`~/.herdr/worktrees/h/…`、T3 Code の worktree のスレッドの `~/.t3/worktrees/h/…`) は、会話の受け口 (ハブ) で、コードを
持たない。会話を 1 つずつ worktree に分けるためだけに git 管理している。

- 会話を始めたら、最初に `pjp hub hello` を打ち、出た形に合うハブの skill を読んで、その手順で動く
  - herdr-app と hc の中 (「この端末」の行が出る。env に `HC_TERMINAL_ID` がある): `pjp-hc-hub`
  - T3 Code の中 (「T3 のスレッド」の行が出る。env に `T3CODE_THREAD_ID` があり、`HC_TERMINAL_ID` が無い): `pjp-t3-hub`
- 質問には、repo を読んで答える。読むだけなら子は立てない
- repo の中 (コード・設定・文書) を変えるときは、自分では直さない。直す repo ごとに子に任せる。herdr-app からは
  `pjp child new` で子 (WSL か SSH 先の Linux の Claude) を立て、T3 Code からは T3 につないだマシンに子のスレッドを立てる
  (`pjp-t3-hub`)。repo の外にあるこのマシンの設定は、ハブで直してよい (それぞれの確認の決まりはそのまま)
- ハブの中にも repo の中にも、ファイルを作らない。作業用のファイルは scratchpad に置く (Write / Edit は hook の
  `pjp hub guard` が止める。PowerShell や Bash で書いても同じ決まり)

このファイルは `pjp-hc-hub` の `pjp hub init` が書いた (dotfiles の Windows の runner が打つ)。直すときは dotfiles の雛形
(`nix/pkgs/pjp-tools/crates/pjp-hc-hub/assets/hub/CLAUDE.md`) を直す。merge の後に dotfiles の runner が `pjp hub init` を打ち直すと、
ここに写る。
