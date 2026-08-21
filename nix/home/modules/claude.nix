# Claude Code の設定。
#
# nix/files/claude/ 配下を ~/.claude/ へ配置する。
#
#   files/claude/CLAUDE.md      -> ~/.claude/CLAUDE.md      (全セッションで読まれる指示)
#   files/claude/statusline-command.sh -> ~/.claude/statusline-command.sh
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
#   ├── <自作>/            <- Nix 管理 (store への symlink)
#   └── <private>/         <- claude-skills の作業クローンへの symlink
#                             (scripts/bootstrap-claude-skills.sh が張る)
#
# ## 追加方法
#
# 対応するディレクトリに置くだけ。下の readDir が自動で拾うので、この .nix を
# 編集する必要はない。README.md だけは配置対象から除外している。
#
# ## 管理しないもの
#
#   settings.json  : Claude Code が書き換える (権限の「常に許可」など)。
#                    store 管理にすると書けなくなる
#   plugins/       : 実行時に取得・更新される
#   claude-skills/ : private リポジトリなので public な flake.lock に載せられず、
#                    載せると CI の nix flake check も fetch できずに落ちる。
#                    scripts/bootstrap-claude-skills.sh が作業クローンへ
#                    symlink を張る。詳細は nix/README.md
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
    # 常時トークンを消費するので最小限に留め、詳しい手順は下のフックに持たせている。
    { ".claude/CLAUDE.md".source = claudeRoot + "/CLAUDE.md"; }

    # PreToolUse フック。Nix 管理パスを編集しようとしたときだけ介入する。
    #
    # フックの **登録** は ~/.claude/settings.json に書く必要があるが、
    # そのファイルは Claude Code 自身が書き換える (権限の「常に許可」など) ため
    # Nix 管理下に置けない。スクリプトだけを配置し、登録はマシンごとに手で行う。
    # 手順は scripts/bootstrap-claude-hook.sh と nix/README.md を参照。
    {
      ".claude/hooks/nix-managed-guard.sh" = {
        source = claudeRoot + "/hooks/nix-managed-guard.sh";
        executable = true;
      };
    }

    # statusLine のスクリプト。フックとまったく同じ事情で、**登録**だけが
    # settings.json 側に残る。手順は scripts/bootstrap-claude-statusline.sh。
    #
    # 既存マシンには /statusline が書いた実ファイルが在る。home-manager は
    # 自分が作ったのではないファイルを消さないので、初回の switch は
    # "would be clobbered" で止まる。退避するか消してから switch する。
    {
      ".claude/statusline-command.sh" = {
        source = claudeRoot + "/statusline-command.sh";
        executable = true;
      };
    }

    (linkEntries "skills")
    (linkEntries "agents")
    (linkEntries "commands")
  ];
}
