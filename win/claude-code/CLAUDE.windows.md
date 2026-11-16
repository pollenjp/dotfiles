# ユーザーレベルの指示

この PC は Windows (Claude Code は Windows のアプリで、Bash の tool は Git Bash で動く)。`%USERPROFILE%\.claude\` の `CLAUDE.md`・
`skills/`・`agents/`・`commands/`・`rules/`・`hooks/` と `settings.json` の一部 (hook・status line・skill の見え方・env) は、dotfiles の
Windows の runner (`win/runner/`。PowerShell の `dotfiles apply`) が配ったもの。Nix (home-manager) と `~/dotfiles/setup` は無い。

- 直接編集せず、repo の側を直して PR にする (repo の作業は Linux の子に任せる)。merge の後、Windows の clone
  (`%USERPROFILE%\ghq\github.com\pollenjp\<repo>`) を pull して `dotfiles apply` で配り直す
- この `CLAUDE.md` は組み立てた写し。直すのは dotfiles の `nix/files/claude/CLAUDE.md` (共通の部分) か `win/claude-code/CLAUDE.windows.md`
  (この冒頭)。`skills/` などは dotfiles と claude-skills の clone への junction かコピーで、runner が写したコピーを変えると次の apply が衝突として知らせる
- hook と status line は、runner が写した `hooks\dotfiles-claude.exe` が動かす。入れたのは Linux の hook の一部だけ (下の節が名指す
  `~/.claude/hooks/*.sh` は Linux の形。どれを入れたかは dotfiles の `win/README.md` の「Claude Code の設定」)
- Claude の会話の git は、settings.json の env で commit・tag を無署名にし、GitHub へは gh の資格情報 (HTTPS) で通す (1Password の SSH の
  鍵を使わない)。GitHub の操作は gh で打つ
