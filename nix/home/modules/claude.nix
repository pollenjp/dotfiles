# Claude Code の設定。
#
# 現時点では自作 skill の配置のみ。
#
# ## なぜ ~/.claude/skills/ ごとではなく skill 単位で配置するのか
#
# ~/.claude/skills/ は **Claude Code 自身が書き換えるディレクトリ**。
# manifest.json (lastUpdated を持つ) があり、Anthropic 配信の skill
# (pdf / docx / xlsx / pptx など、source が "anthropic") がここへ入る。
# ディレクトリごと store の symlink にすると、それらの導入・更新が壊れる。
#
# 一方 manifest.json に載っていない skill ディレクトリが共存できることは
# 確認済み (session-start-hook が実例)。したがって skill を 1 つずつ
# 配置すれば、Claude Code 管理のものと**兄弟として並ぶ**だけで衝突しない。
#
#   ~/.claude/skills/
#   ├── manifest.json      <- Claude Code 管理
#   ├── pdf/  docx/  ...   <- Claude Code 管理 (配信 skill)
#   └── <自作>/            <- ここが Nix 管理 (store への symlink)
#
# ## skill の追加方法
#
# nix/files/claude/skills/<名前>/SKILL.md を作るだけ。
# 下の readDir が自動で拾うので、この .nix を編集する必要はない。
#
# SKILL.md には YAML frontmatter で name と description が要る:
#
#   ---
#   name: my-skill
#   description: いつ使うかを書く。ここを読んで起動が判断される
#   ---
#
# scripts/ references/ assets/ などの補助ファイルは同じディレクトリに置けば
# まとめて配置される (ディレクトリ単位で symlink するため)。
#
# ## 編集したら
#
# store 管理なので `home-manager switch` が必要。
{ lib, ... }:

let
  skillsDir = ../../files/claude/skills;

  # nix/files/claude/skills/ のサブディレクトリを自動で列挙する。
  # skill を足すたびにこのファイルを編集しなくて済む。
  skillNames = lib.attrNames (
    lib.filterAttrs (_name: type: type == "directory") (builtins.readDir skillsDir)
  );
in

{
  home.file = lib.listToAttrs (
    map (name: {
      name = ".claude/skills/${name}";
      value.source = "${skillsDir}/${name}";
    }) skillNames
  );
}
