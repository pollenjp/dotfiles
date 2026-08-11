# Claude Code のカスタムサブエージェント

ここに置いた `.md` が `~/.claude/agents/<名前>.md` へ配置される。

配置しているのは `nix/home/modules/claude.nix`。**このディレクトリを `readDir` して
自動列挙する**ので、追加時に `.nix` を編集する必要はない。

> このファイル自体はディレクトリを git 管理下に残すために置いてある。
> `README.md` は配置対象から除外している。

## 追加

```
nix/files/claude/agents/<名前>.md
```

```markdown
---
name: my-agent
description: いつ起動すべきかを書く。Claude はここを読んで委譲を判断する
tools: Read, Grep, Glob      # 省略すると全ツール
model: sonnet                # 省略すると親から継承
---

システムプロンプトをここに書く。
```

追加したら適用する。

```sh
# 新規ファイルなら git add する (~/dotfiles 経由の switch は path: なので
# untracked でも入るが、CI は git 管理下しか見ないので commit 忘れはそこで出る)
git -C "$(ghq root)/github.com/pollenjp/dotfiles" add nix/files/claude

home-manager switch --flake ~/dotfiles#<ホスト名>
```

## 注意

**`~/.claude/agents/` を直接編集しないこと。** store への symlink なので、
一般ユーザーでは `Permission denied`、root では黙って store が破損する。
