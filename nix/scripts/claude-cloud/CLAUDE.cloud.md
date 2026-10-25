# ユーザーレベルの指示

この session は Claude Code on the web (cloud) の VM で動いている。`~/.claude/` の `CLAUDE.md`・`skills/`・`agents/`・
`commands/`・`hooks/` は、環境の setup script が流した dotfiles の `nix/scripts/claude-cloud/bootstrap-claude-cloud.sh`
が組み立てたもので、Nix (home-manager) 管理ではない。この VM には home-manager も `~/dotfiles/setup` も無い。

- `skills/` などは、session に clone された dotfiles (`nix/files/claude/`) と claude-skills の checkout への symlink。
  直すときは checkout の側を直して commit・push する (VM は捨てられるので、push しなければ残らない)
- この `CLAUDE.md` は組み立てた写し。直すときは dotfiles の `nix/files/claude/CLAUDE.md` (共通の部分) か
  `nix/scripts/claude-cloud/CLAUDE.cloud.md` (この冒頭) を直す
- 手元のマシンにだけあるもの (herdr・ghq・cc-pages・1Password の SSH agent・`~/.config/pjp/env`) は無い。
  Notion の token は環境の設定 (Network secret か環境変数) から来る
