# Claude Code のカスタムサブエージェント

ここに置いた `.md` が `~/.claude/agents/<名前>.md` へ配置される。

> ⚠️ **このリポジトリは public。** 公開できない内容は
> [`pollenjp/claude-skills`](https://github.com/pollenjp/claude-skills)（private）の
> `agents/` へ置く（詳細は `nix/README.md`）。

配置しているのは `nix/home/modules/claude.nix`。**このディレクトリを `readDir` して
自動列挙する**ので、追加時に `.nix` を編集する必要はない。

> このファイル自体はディレクトリを git 管理下に残すために置いてある。
> `README.md` は配置対象から除外している。

## 追加

**名前は `pjp-` で始める**（skill と同じ規約。理由は `nix/README.md` の
「命名: `pjp-` で始める」）。ファイル名と `name` の両方。

```
nix/files/claude/agents/pjp-<名前>.md
```

サブディレクトリに分けて置いてもよい。Claude Code は agents の下をサブディレクトリまで読み、呼び名はパスでなく `name` で
決まる（サブディレクトリはディレクトリごと `~/.claude/agents/` へ配置される）。

- サブディレクトリの名前も `pjp-` で始める。`~/.claude/agents/` には claude-skills 側のものも並び、同じ名前なら
  claude-skills 側が警告とともに飛ばされる（`check-claude-frontmatter.sh` は見ない）
- 別のサブディレクトリに同じファイル名を置かない。`name` が重なり、Claude Code はどちらか一方しか読まない
  （`check-claude-frontmatter.sh` が落とす）
- 説明の文書は `README.md` という名前にする。Claude Code は frontmatter の無い `.md` を文書として扱うが、
  `check-claude-frontmatter.sh` は `README.md` のほかは agent として見る

```markdown
---
name: pjp-my-agent
description: いつ起動すべきかを書く。Claude はここを読んで委譲を判断する
tools: Read, Grep, Glob      # 省略すると全ツール
model: sonnet                # 省略すると親から継承
---

システムプロンプトをここに書く。
```

追加したら（frontmatter を直したときも）、frontmatter を確かめてから適用する。

```sh
# frontmatter を YAML として読み、name とファイル名の食い違い・pjp- で始まらない名前なども見る
# (CI の lint ジョブも流す。yq が無ければ nix/ の devShell に入り直す。nix/README.md の「frontmatter を確かめる」)
"$(ghq root)/github.com/pollenjp/dotfiles/nix/scripts/check-claude-frontmatter.sh"

# 新規ファイルなら git add する (~/dotfiles 経由の switch は path: なので
# untracked でも入るが、CI は git 管理下しか見ないので commit 忘れはそこで出る)
git -C "$(ghq root)/github.com/pollenjp/dotfiles" add nix/files/claude

home-manager switch --flake ~/dotfiles#<ホスト名>
```

## 注意

**`~/.claude/agents/` を直接編集しないこと。** store への symlink なので、
一般ユーザーでは `Permission denied`、root では黙って store が破損する。
