---
name: dotfiles-claude-skill
description: 全プロジェクト共通（~/.claude/ 配下）の skill / subagent / スラッシュコマンドを新しく作る、または既存のものを直すときに使う。実体は ~/dotfiles/nix/files/claude/ に置いて home-manager 経由で ~/.claude/ へ配置するので、~/.claude/ へ直接書いてはいけない。「skill を作りたい」「~/.claude に skill を足したい」「グローバルな slash command や subagent を追加したい」といった依頼なら、いまどのディレクトリで作業していても使う。リポジトリ内の .claude/skills/（そのプロジェクト専用のもの）を作るときは使わない。
---

# dotfiles で管理する Claude Code の skill を作る

`~/.claude/` の `skills/` `agents/` `commands/` は **Nix (home-manager) 管理**。
実体は `~/dotfiles/nix/files/claude/` にあり、`/nix/store` への symlink として配置される。

**新しく作るものも、最初からリポジトリ側に置く。**

## なぜこの skill が要るか

`~/.claude/` 配下の **既存の** Nix 管理ファイルを編集しようとすると `PreToolUse`
フック（`~/.claude/hooks/nix-managed-guard.sh`）が止めて手順を教えてくれる。

ただしフックの判定は「解決先が `/nix/store` 配下か」なので、
**まだ存在しない skill を新規に作る場合は発火しない**。
`~/.claude/skills/` 自体は実ディレクトリで、試作を直接置く用途を潰さないよう
意図的にそうしてある。

つまり新規作成だけがフックの守備範囲の外にある。そこを埋めるのがこの skill。

## 置き場所

| 作るもの | リポジトリ側（ここに書く） | 配置先（触らない） |
| --- | --- | --- |
| skill | `~/dotfiles/nix/files/claude/skills/<名前>/SKILL.md` | `~/.claude/skills/<名前>/` |
| subagent | `~/dotfiles/nix/files/claude/agents/<名前>.md` | `~/.claude/agents/<名前>.md` |
| slash command | `~/dotfiles/nix/files/claude/commands/<名前>.md` | `~/.claude/commands/<名前>.md` |

`nix/home/modules/claude.nix` が各ディレクトリを `readDir` で自動列挙するので、
**`.nix` を編集する必要はない**。skill の `scripts/` `references/` `assets/` などの
補助ファイルは同じディレクトリに置けばまとめて配置される。

## 手順

### 0. dotfiles の場所を確かめる

作業ディレクトリがどこであっても、書き込む先は dotfiles。

```sh
ls -d ~/dotfiles/nix/files/claude
```

無ければ clone 先が違うので、場所をユーザーに聞くこと。以下 `~/dotfiles` は
その場所に読み替える。

### 1. 名前を決める

- `^[a-z0-9][a-z0-9-]*$`。ディレクトリ名と frontmatter の `name` を一致させる
- `~/.claude/skills/` 配下で一意にする。Anthropic 配信の skill
  （`pdf` `docx` `xlsx` `pptx` `skill-creator` など）と同名にすると
  **どちらが使われるか不定になる**

```sh
ls ~/.claude/skills ~/dotfiles/nix/files/claude/skills
```

### 2. 雛形を作る

```sh
~/.claude/skills/dotfiles-claude-skill/scripts/new.sh skill <名前>
```

`skill` の代わりに `agent` / `command` も指定できる。名前の検証・衝突確認・
`git add` までやる。手で作る場合は下の「中身の書き方」を見て、
手順 3 の `git add` を忘れないこと。

### 3. 中身を書く

雛形の frontmatter と本文を埋める。`description` が起動判定に使われるので、
「何をするか」より **「どういう時に使うか」** を具体的に書く。

中身の設計そのものは Anthropic 配信の `skill-creator` skill に任せてよい。
**この skill が持っているのは置き場所と反映手順**で、書き方はそちらの担当。

### 4. git add する

**忘れると黙って反映されない。** flake は git 管理下の *追跡済み* ファイルしか
見ないため、新規ディレクトリは untracked のままだと評価に入らない。
エラーは出ず、ただ配置されないだけなので気付きにくい。

```sh
git -C ~/dotfiles add nix/files/claude
```

### 5. 適用する

```sh
~/dotfiles/nix/scripts/setup.sh --update
```

ホスト名は `$USER` と `uname` から自動判定される。手で書くなら:

```sh
home-manager switch --flake ~/dotfiles/nix#<ホスト名>
```

`<ホスト名>` は `~/dotfiles/nix/hosts/default.nix` の登録名。

### 6. 確認する

```sh
ls -l ~/.claude/skills/<名前>
```

`/nix/store/...` への symlink になっていれば成功。
**使えるようになるのは新しいセッションから**で、いま開いているセッションには
載らないことがある。

## 反復するとき

1 文字直すたびに `git add` + `switch` が要る。書き直しが多いうちは
`~/.claude/skills/<仮の名前>/` に **実ディレクトリとして** 置いて動かし、
固まってから dotfiles へ移す方が速い（フックはこれを止めない）。

移したあとは仮ディレクトリを必ず消す。同じ名前が 2 つあると
どちらが使われるか不定になる。

## そのプロジェクト専用にしたいとき

この skill は使わない。リポジトリ内の `.claude/skills/<名前>/` に置いて、
そのリポジトリごとコミットする。**全プロジェクトで使いたいものだけ** dotfiles
に入れる。

判断に迷ったら、そのリポジトリでしか意味を持たない知識（ビルド手順、
デプロイ先、そのコードベース固有の規約）ならプロジェクト側。

## 中身の書き方

### skill (`SKILL.md`)

```markdown
---
name: my-skill
description: どういう時に使うかを具体的に書く。ここが起動判定に使われる
---

# My Skill

本文。手順や規約をここに書く。
```

### subagent (`agents/<名前>.md`)

```markdown
---
name: my-agent
description: いつ起動すべきかを書く。Claude はここを読んで委譲を判断する
tools: Read, Grep, Glob      # 省略すると全ツール
model: sonnet                # 省略すると親から継承
---

システムプロンプトをここに書く。
```

### slash command (`commands/<名前>.md`)

```markdown
---
description: /help や補完に出る 1 行説明
argument-hint: <path>        # 省略可
---

プロンプト本文。$ARGUMENTS で引数を受け取れる。
```

サブディレクトリで名前空間を切れる（`commands/git/sync.md` → `/git:sync`）。

## やってはいけないこと

- **`~/.claude/` 配下の Nix 管理パスを直接編集する。**
  store は read-only。一般ユーザーは `Permission denied` で済むが、
  **root では黙って成功して store が壊れる**（変更は次の GC やリビルドで
  失われ、エラーも出ない）
- **`.nix` を編集して skill を登録する。** `readDir` が自動で拾うので不要
- **`git add` を飛ばす。** 黙って配置されない
