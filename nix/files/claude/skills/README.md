# Claude Code の自作 skill

ここに置いたディレクトリが `~/.claude/skills/<名前>` へ配置される。

配置しているのは `nix/home/modules/claude.nix`。**このディレクトリを `readDir` して
サブディレクトリを自動列挙する**ので、skill を足すときに `.nix` を編集する必要はない。

> このファイル自体はディレクトリを git 管理下に残すために置いてある。
> `readDir` はディレクトリのみを拾うので、配置対象にはならない。

## skill の追加

雛形作りから適用までは `dotfiles-claude-skill` skill が案内する。
別のリポジトリで作業していて「`~/.claude` 用の skill を作りたい」となったときに
起動し、`~/.claude/` ではなくここへ作らせる。手で作るなら以下。

```
nix/files/claude/skills/<名前>/SKILL.md
```

`SKILL.md` には YAML frontmatter が要る。

```markdown
---
name: my-skill
description: いつ使うかを書く。Claude はここを読んで起動を判断するので、
             「何をするか」より「どういう時に使うか」を具体的に書く
---

# My Skill

本文。手順や規約をここに書く。
```

`scripts/` `references/` `assets/` などの補助ファイルは同じディレクトリに置けば
まとめて配置される（ディレクトリ単位で symlink するため）。

追加したら適用する。

```sh
home-manager switch --flake ~/dotfiles/nix#<host>
```

## 配置後の構造

`~/.claude/skills/` は **Claude Code 自身が書き換える**ディレクトリなので、
ディレクトリごとではなく skill 単位で symlink している。

```
~/.claude/skills/
├── manifest.json      <- Claude Code 管理
├── pdf/  docx/  ...   <- Claude Code 管理 (Anthropic 配信)
└── <自作>/            <- Nix 管理 (store への symlink)
```

Claude Code 管理のものとは兄弟として並ぶだけなので衝突しない。

## 注意

- **store 管理なので編集の度に `home-manager switch` が要る。**
  試行錯誤しながら書く場合は、一時的に `~/.claude/skills/` へ直接置いて
  固まってからこちらへ移す方が早い
- 名前は `~/.claude/skills/` 配下で一意にすること。Anthropic 配信の skill
  (`pdf` `docx` `xlsx` `pptx` `morning` `skill-creator` など) と同名にすると
  どちらが使われるか不定になる
