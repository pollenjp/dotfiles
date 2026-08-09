# Claude Code の設定。
#
# nix/files/claude/ 配下を ~/.claude/ へ配置する。
#
#   files/claude/CLAUDE.md      -> ~/.claude/CLAUDE.md      (全セッションで読まれる指示)
#   files/claude/skills/<name>/ -> ~/.claude/skills/<name>  (ディレクトリ単位)
#   files/claude/agents/<name>.md   -> ~/.claude/agents/<name>.md
#   files/claude/commands/<name>.md -> ~/.claude/commands/<name>.md
#
# ## なぜ skills/ agents/ commands/ ごとではなく中身を 1 つずつ配置するのか
#
# ~/.claude/ 配下は **Claude Code 自身が書き換える**。skills/ には manifest.json
# (lastUpdated を持つ) があり、Anthropic 配信の skill (pdf / docx / xlsx / pptx など)
# がここへ入る。ディレクトリごと store の symlink にすると、それらの導入・更新が壊れる。
#
# 一方 manifest.json に載っていない skill ディレクトリが共存できることは確認済み
# (session-start-hook が実例)。中身を 1 つずつ配置すれば、Claude Code 管理のものと
# **兄弟として並ぶ**だけで衝突しない。
#
#   ~/.claude/skills/
#   ├── manifest.json      <- Claude Code 管理 (実ファイル)
#   ├── pdf/  docx/  ...   <- Claude Code 管理 (実ディレクトリ)
#   └── <自作>/            <- Nix 管理 (store への symlink)
#
# ## 追加方法
#
# 対応するディレクトリに置くだけ。下の readDir が自動で拾うので、この .nix を
# 編集する必要はない。README.md だけは配置対象から除外している。
#
# ## 管理しないもの
#
#   settings.json : Claude Code が書き換える (権限の「常に許可」など)。
#                   store 管理にすると書けなくなる
#   plugins/      : 実行時に取得・更新される
{ lib, ... }:

let
  claudeRoot = ../../files/claude;

  # <kind> 直下のエントリを 1 つずつ ~/.claude/<kind>/ へ配置する。
  #
  # ファイルとディレクトリの両方を対象にしている。用途が種類ごとに違うため:
  #   skills   ... ディレクトリ (SKILL.md + scripts/ などの補助ファイル)
  #   agents   ... *.md ファイル
  #   commands ... *.md ファイル。サブディレクトリで名前空間を切ることもできる
  linkEntries =
    kind:
    let
      dir = claudeRoot + "/${kind}";
      entries = lib.filterAttrs (name: _type: name != "README.md") (builtins.readDir dir);
    in
    lib.mapAttrs' (
      name: _type:
      lib.nameValuePair ".claude/${kind}/${name}" {
        source = dir + "/${name}";
      }
    ) entries;
in

{
  home.file = lib.mkMerge [
    # 全セッションで読まれるユーザーレベルの指示。
    # skill などが Nix 管理であることをここに書いておくと、Claude が
    # ~/.claude/ を直接編集しようとして失敗するのを防げる。
    { ".claude/CLAUDE.md".source = claudeRoot + "/CLAUDE.md"; }

    (linkEntries "skills")
    (linkEntries "agents")
    (linkEntries "commands")
  ];
}
