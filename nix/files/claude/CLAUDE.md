# ユーザーレベルの指示

`~/.claude/` の一部（`CLAUDE.md` / `skills/` / `agents/` / `commands/`）は
**Nix (home-manager) 管理**で、dotfiles 本体（`$(ghq root)/github.com/pollenjp/dotfiles`）
の `nix/files/claude/` の複製が `/nix/store` 経由で配置されている。
直接編集せず、リポジトリ側を編集して `home-manager switch` すること。

詳しい手順は、該当パスを編集しようとしたときに `PreToolUse` フック
（`~/.claude/hooks/nix-managed-guard.sh`）が返す。

`skills/` などには private リポジトリ（`claude-skills`）の作業クローンへの symlink も
混ざる。そちらは直接編集してよいが、実体はクローンなので **commit が要る**。
