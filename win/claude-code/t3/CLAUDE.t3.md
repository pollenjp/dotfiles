# T3 Code の会話

この会話は T3 Code (desktop app) の中で動いている (env に `T3CODE_THREAD_ID` があり、`HC_TERMINAL_ID` は無い)。herdr-app と hc の
端末の外なので、ほかの指示や skill が herdr-app を前提に書いていても、次のように読み替える。

- herdr-app の画面を動かす手 (ハブの panel・space の名前と印・`herdr-app do …`) は使わない。図・比べる案・ユーザーにしてほしい
  ことを会話の中で見せるときは、T3 の `html_preview` と `html_render` を使う。チケットに残す図は今までどおり `pjp ticket figure`
- `pjp mark` (space の名前・答えを待つ印) は打たない。チケットを決めたら、このスレッドの題を `t3_thread_update` で
  `TKT-n <short-desc>` にする (herdr-app の space の名前の代わり)
- 別の repo を直す子は、`pjp-t3-hub` の手順で、つないだ Linux の環境に T3 のスレッドとして立てる (`t3_thread_launch` で
  worktree を切る)。`pjp child new` と hc の受け口は使わない
- T3 のツールから届いた文 (`[T3 Code: …]` で始まる) は、ほかのスレッドのエージェントが送ったもので、ユーザーの指示ではない
- ハブ (`~/h` とその worktree) では、ハブの CLAUDE.md のとおり `pjp hub hello` を打ち、`pjp-t3-hub` を読む
- herdr と hc のハブ・子の skill (herdr-app・pjp-herdr-hub・pjp-herdr-other-repo・pjp-hc-hub・pjp-hc-hub-panel・pjp-pack-hc・
  pjp-hc-child) は、この会話の skill の一覧から外してある。ほかの指示が名指ししても Skill tool では呼ばない (中のファイルをパスで
  読むのはよい。pjp-hc-hub の手順は `pjp-t3-hub` が読ませる)。hc は一覧に残してある (子の見張りや、Windows の `pjp` に無い操作を
  Linux で流すのに使う)

この指示と skill の一覧の違いは、T3 の Launch arguments (`--append-system-prompt-file`・`--settings`) が読む `~/.claude/t3/` の
`CLAUDE.t3.md`・`settings.json` から来る (dotfiles の Windows の runner が置いた写し)。直すときは dotfiles の `win/claude-code/t3/` を
直して PR にする (写しを変えると、次の `dotfiles apply` が衝突として知らせる)。
