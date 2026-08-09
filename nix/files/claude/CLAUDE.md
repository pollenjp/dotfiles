# ユーザーレベルの指示

このファイル自体を含め、`~/.claude/` 配下の以下は **Nix (home-manager) 管理**であり、
`~/dotfiles/nix/files/claude/` の複製が `/nix/store` 経由で配置されている。

| 配置先 | 実体 |
| --- | --- |
| `~/.claude/CLAUDE.md` | `~/dotfiles/nix/files/claude/CLAUDE.md` |
| `~/.claude/skills/<名前>/` | `~/dotfiles/nix/files/claude/skills/<名前>/` |
| `~/.claude/agents/<名前>.md` | `~/dotfiles/nix/files/claude/agents/<名前>.md` |
| `~/.claude/commands/<名前>.md` | `~/dotfiles/nix/files/claude/commands/<名前>.md` |

## skill / agent / command を追加・編集するとき

**`~/.claude/` 配下を直接編集しないこと。** store 上の read-only ファイルへの
symlink なので、編集は次のように失敗する。

- 一般ユーザー → `Permission denied`
- **root → 黙って成功するが store が破損する**（`nix store verify` が hash 不一致を
  検出する状態になる。変更は次の GC やリビルドで失われ、エラーも出ないので気づけない）

正しい手順:

```sh
# 1. リポジトリ側を編集する
$EDITOR ~/dotfiles/nix/files/claude/skills/<名前>/SKILL.md

# 2. 新規ファイルなら git add する (flake は untracked ファイルを見ない)
git -C ~/dotfiles add nix/files/claude

# 3. 適用する
home-manager switch --flake ~/dotfiles/nix#<ホスト名>
```

ホスト名は `~/dotfiles/nix/hosts/default.nix` に登録されているもの。

新しい skill / agent / command を足すときに `.nix` を編集する必要はない。
`nix/home/modules/claude.nix` がディレクトリを `readDir` して自動列挙する。

## Nix 管理ではないもの

次は Claude Code 自身が書き換えるため Nix 管理下に置いていない。直接編集してよい。

- `~/.claude/settings.json` — 権限の「常に許可」などで書き換わる
- `~/.claude/skills/manifest.json` と Anthropic 配信の skill（`pdf` `docx` `xlsx`
  `pptx` `morning` `skill-creator` など）
- `~/.claude/plugins/`
- 実行時の状態（`projects/` `sessions/` `shell-snapshots/` `history` など）

## 試行錯誤するとき

skill を書いている最中は `home-manager switch` の往復が煩わしい。固まるまでは
`~/.claude/skills/<仮名>/` に**実ディレクトリとして**置いて動かし、完成してから
`~/dotfiles/nix/files/claude/skills/` へ移すとよい。
（Nix 管理下の名前と衝突させないこと）
