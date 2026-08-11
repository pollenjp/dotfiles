# Claude Code のカスタムスラッシュコマンド

ここに置いた `.md` が `~/.claude/commands/<名前>.md` へ配置され、`/<名前>` で呼べる。

> ⚠️ **このリポジトリは public。** 公開できない内容は
> [`pollenjp/claude-skills`](https://github.com/pollenjp/claude-skills)（private）の
> `commands/` へ置く（詳細は `nix/README.md`）。

配置しているのは `nix/home/modules/claude.nix`。**このディレクトリを `readDir` して
自動列挙する**ので、追加時に `.nix` を編集する必要はない。

> このファイル自体はディレクトリを git 管理下に残すために置いてある。
> `README.md` は配置対象から除外している。

## 追加

```
nix/files/claude/commands/<名前>.md
```

```markdown
---
description: /help や補完に出る 1 行説明
argument-hint: <path>        # 省略可
---

プロンプト本文。$ARGUMENTS で引数を受け取れる。
```

サブディレクトリで名前空間を切ることもできる。

```
nix/files/claude/commands/git/sync.md   ->  /git:sync
```

ディレクトリも配置対象なので、そのまま置けば動く。

追加したら適用する。

```sh
# 新規ファイルなら git add する (~/dotfiles 経由の switch は path: なので
# untracked でも入るが、CI は git 管理下しか見ないので commit 忘れはそこで出る)
git -C "$(ghq root)/github.com/pollenjp/dotfiles" add nix/files/claude

home-manager switch --flake ~/dotfiles#<ホスト名>
```

## 注意

**`~/.claude/commands/` を直接編集しないこと。** store への symlink なので、
一般ユーザーでは `Permission denied`、root では黙って store が破損する。
