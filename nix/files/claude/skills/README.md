# Claude Code の自作 skill

ここに置いたディレクトリが `~/.claude/skills/<名前>` へ配置される。

> ⚠️ **このリポジトリは public。** 業務固有の手順・社内の名前・個人的な文脈を含むものは
> ここではなく [`pollenjp/claude-skills`](https://github.com/pollenjp/claude-skills)（private）へ置く。
> 配置は `nix/scripts/bootstrap-claude-skills.sh` が行う（詳細は `nix/README.md`）。

配置しているのは `nix/home/modules/claude.nix`。**このディレクトリを `readDir` して
サブディレクトリを自動列挙する**ので、skill を足すときに `.nix` を編集する必要はない。

> このファイル自体はディレクトリを git 管理下に残すために置いてある。
> `readDir` はディレクトリのみを拾うので、配置対象にはならない。

## skill の追加

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
home-manager switch --flake ~/dotfiles#<host>
```

## script が外部ツールを要求するとき

`scripts/` に置く script が手元に無いツールを要求する場合、用意する手段は
**nix flake → mise → system** の順に検討する（ユーザーレベルの `CLAUDE.md` にも書いてある）。
`pip install` / `npm install -g` / `apt install` で環境へ直接入れない。

こちら側の skill は **store へコピーされる**ので、`claude-skills`（作業クローン）とは形が変わる。

| 依存の性質 | 置き場 |
| --- | --- |
| 常用する / 他からも使う | `nix/home/modules/packages.nix` の `home.packages` |
| その skill でしか使わない | `nix/files/claude/skills/<名前>/flake.nix` + **`flake.lock`** |

前者で済むならその方が単純。skill を消したときにツールも一緒に消えてほしい、
バージョンをこの skill だけで固定したい、といった理由があるときに後者。

### skill 側に flake を持たせる場合

**`flake.lock` を必ず一緒に commit すること。** store は読み取り専用なので、
lock が無いと nix がその場で lock を書こうとして失敗する。

```
error: opening file "/nix/store/....../flake.lock": Permission denied
```

script から devShell へ入り直すときは、**symlink を解決した実体のパス**を渡す。
`~/.claude/skills/<名前>` は store への symlink なので、`$0` をそのまま使うと
flake の位置を見失う。symlink を `path:` へ渡すと、解決先を外部パス扱いされて
こう落ちる。

```
error: access to absolute path '/nix/store/...' is forbidden in pure evaluation mode
```

```sh
# 印を付けて 1 回だけにする (devShell に入っても揃わない場合の無限ループ防止)
if ! command -v <tool> &>/dev/null; then
  if [[ -z ${MY_SKILL_REEXEC:-} ]] && command -v nix &>/dev/null; then
    export MY_SKILL_REEXEC=1
    skill_dir=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd -P)
    exec nix develop "path:${skill_dir}" --command "$0" "$@"
  fi
  echo "<tool> が見つかりません。nix があれば devShell へ入り直します。" >&2
  exit 1
fi
```

`claude-skills` 側は実ディレクトリなので `path:` も `readlink` も要らない。
そちらの `skills/README.md` を参照。

## 配置後の構造

`~/.claude/skills/` は **Claude Code 自身が書き換える**ディレクトリなので、
ディレクトリごとではなく skill 単位で symlink している。

```
~/.claude/skills/
├── manifest.json      <- Claude Code 管理
├── pdf/  docx/  ...   <- Claude Code 管理 (Anthropic 配信)
├── <自作>/            <- Nix 管理 (store への symlink)
└── <private>/         <- claude-skills の作業クローンへの symlink
```

いずれも兄弟として並ぶだけなので衝突しない。

## 注意

- **store 管理なので編集の度に `home-manager switch` が要る。**
  試行錯誤しながら書く場合は、一時的に `~/.claude/skills/` へ直接置いて
  固まってからこちらへ移す方が早い
  （`claude-skills` 側は作業クローンへの symlink なのでこの制約が無い）
- 名前は `~/.claude/skills/` 配下で一意にすること。Anthropic 配信の skill
  (`pdf` `docx` `xlsx` `pptx` `morning` `skill-creator` など) や
  `claude-skills` 側のものと同名にすると、どちらが使われるか不定になる
