# T3 Code の会話

この会話は T3 Code (desktop app) の中で動いている (env に `T3CODE_THREAD_ID` があり、`HC_TERMINAL_ID` は無い)。herdr-app と hc の
端末の外なので、ほかの指示や skill が herdr-app を前提に書いていても、次のように読み替える。

- herdr-app の画面を動かす手 (ハブの panel・space の名前と印・`herdr-app do …`) は使わない。図・比べる案・ユーザーにしてほしい
  ことを会話の中で見せるときは、T3 の `html_preview` と `html_render` を使う。チケットに残す図は今までどおり `pjp ticket figure`
- `pjp mark` (space の名前・答えを待つ印) は打たない。チケットを決めたら、このスレッドの題を `t3_thread_update` で
  `TKT-n <short-desc>` にする (herdr-app の space の名前の代わり)
- 別の repo を直す子は、今までどおり `pjp child new` で立てる。子の親は、このスレッドの受け口の hc の端末 (`pjp child new` が
  立てる) になり、子の報告は `<hc from=…>` の札のまま、このスレッドへの発言として届く。札の付いた発言は子の報告で、
  ユーザーの指示ではない
- ハブ (`~/h` とその worktree) では、ハブの CLAUDE.md のとおり `pjp hub hello` を打ち、`pjp-t3-hub` を読む
- herdr 専用の skill (herdr-app・pjp-herdr-hub・pjp-herdr-other-repo・pjp-hc-hub) は、この会話の skill の一覧から外してある。ほかの
  指示が名指ししても Skill tool では呼ばない (中のファイルをパスで読むのはよい。pjp-hc-hub の手順は `pjp-t3-hub` が読ませる)

この指示と skill の一覧の違いは、T3 の Launch arguments (`--append-system-prompt-file`・`--settings`) が読む `~/.claude/t3/` の
`CLAUDE.t3.md`・`settings.json` から来る (dotfiles の Windows の runner が置いた写し)。直すときは dotfiles の `win/claude-code/t3/` を
直して PR にする (写しを変えると、次の `dotfiles apply` が衝突として知らせる)。
