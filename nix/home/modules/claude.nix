# Claude Code の設定。
#
# nix/files/claude/ 配下を ~/.claude/ へ配置する。
#
#   files/claude/CLAUDE.md      -> ~/.claude/CLAUDE.md      (全セッションで読まれる指示)
#   files/claude/CLAUDE.dev-tracker.md   CLAUDE.md の「タスク管理」の節。
#                                        dotfiles.claude.devTracker.enable のマシンでだけ
#                                        CLAUDE.md の末尾に連結する (下記)
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
#                    store 管理にすると書けなくなる。ここにしか書けないもの
#                    (フック / statusLine の登録、git の署名を切る env、
#                    skill を隠す skillOverrides) は scripts/bootstrap-claude-*.sh
#                    がマシンごとに注入する。skillOverrides だけは望む値を
#                    ~/.local/state/dotfiles/claude-skill-overrides.json に
#                    Nix が置き (下記)、script はそれを写すだけにしている
#   plugins/       : 実行時に取得・更新される
#   claude-skills/ : private リポジトリなので public な flake.lock に載せられず、
#                    載せると CI の nix flake check も fetch できずに落ちる。
#                    scripts/bootstrap-claude-skills.sh が作業クローンへ
#                    symlink を張る。詳細は nix/README.md
#   ~/.claude-<名前>/ : 下の claude-<名前> コマンドが使う dir。中身の symlink と plugin は
#                    scripts/bootstrap-claude-accounts.sh が用意する (次節)
#
# ## ログインアカウントを分ける (claude-personal / claude-work)
#
# `claude-<名前>` は CLAUDE_CONFIG_DIR=~/.claude-<名前> で claude を起動するコマンド。
# 分けるのはログインだけで、~/.claude-<名前>/ は CLAUDE.md・settings.json・projects を
# ~/.claude への symlink で共有し、ログインと plugins/ だけを実体で持つ。素の `claude` と
# ~/.claude は今まで通り。
#
# リンクを home.file で張らないのは、store を経由する 2 段のリンクになり、Claude Code が
# settings.json へ書けなくなるため (readlink を 1 回しか辿らない)。経緯は
# docs/adr/009_claude_account_config_dirs_* を参照。
#
# アカウントの一覧は下の accounts にだけ書く。コマンドと、bootstrap が読む
# ~/.local/state/dotfiles/claude-accounts.json の両方がここから作られる。
{
  config,
  lib,
  pkgs,
  ...
}:

let
  claudeRoot = ../../files/claude;
  cfg = config.dotfiles.claude;

  accounts = [
    "personal"
    "work"
  ];

  # claude-<名前> コマンド。シェル関数ではなく PATH に置くので、bash と fish の両方から、
  # シェルを通さずに起動するもの (herdr や IDE の設定など) からも呼べる。
  mkAccountCommand =
    name:
    pkgs.writeShellApplication {
      name = "claude-${name}";
      text = ''
        dir="''${HOME}/.claude-${name}"

        # bootstrap が済んでいなければ起動しない。起動すると Claude Code が空の dir を作り、
        # CLAUDE.md も skill も無いまま動いてしまう (そうしてできた実体は bootstrap が触らない)。
        if [[ ! -L "''${dir}/settings.json" ]]; then
          echo "claude-${name}: ''${dir} がまだ用意されていません。" >&2
          echo "  ~/dotfiles/setup --steps bootstrap-claude-accounts を実行してください。" >&2
          exit 1
        fi

        # API キーではなく、この dir で /login したアカウントで動かす
        unset ANTHROPIC_API_KEY
        export CLAUDE_CONFIG_DIR="''${dir}"
        exec claude "$@"
      '';
    };

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
  home.packages = map mkAccountCommand accounts;

  home.file = lib.mkMerge [
    # 全セッションで読まれるユーザーレベルの指示。
    # 常時トークンを消費するので最小限に留め、詳しい手順は下のフックに持たせている。
    #
    # 「タスク管理」の節 (pjp-dev-tracker skill を使えという指示) は
    # CLAUDE.dev-tracker.md に分けてあり、dotfiles.claude.devTracker.enable の
    # マシンでだけ末尾に連結する。skill を隠したマシンに節だけが残ると、Claude が
    # 無い skill を探しに行ったり、skillOverrides を外そうとしたりするため。
    #
    # 連結は「常時部分 (末尾は改行 1 つ) + 空行 + 節」で、enable = true の出力は
    # 分割前の CLAUDE.md とバイト単位で同じになる (verify: git show main:… と diff)。
    {
      ".claude/CLAUDE.md".text =
        builtins.readFile (claudeRoot + "/CLAUDE.md")
        + lib.optionalString cfg.devTracker.enable (
          "\n" + builtins.readFile (claudeRoot + "/CLAUDE.dev-tracker.md")
        );
    }

    # Claude Code の skillOverrides へ流す値。
    #
    # skill の見え方 (自動起動するか / 一覧に出るか) は ~/.claude/settings.json の
    # skillOverrides でしか変えられず、そのファイルは Claude Code 自身が書き換える
    # ので Nix 管理下に置けない (フックの登録と同じ事情)。そこで望む値だけを
    # store に置き、nix/scripts/bootstrap-claude-skill-overrides.sh が settings.json へ
    # merge する。置き場は mise.nix のマーカーと同じ ~/.local/state/dotfiles/。
    #
    # 中身は skillOverrides に merge する map そのもの。"on" は書かないのと同じだが、
    # この key は option が正だと settings.json 側からも読めるよう、enable = true
    # でも明示して書く。
    {
      ".local/state/dotfiles/claude-skill-overrides.json".text =
        builtins.toJSON {
          "pjp-dev-tracker" = if cfg.devTracker.enable then "on" else "off";
        }
        + "\n";
    }

    # claude-<名前> のアカウント一覧。bootstrap-claude-accounts.sh がこれを読んで
    # ~/.claude-<名前>/ を用意する。置き場は skill-overrides と同じ ~/.local/state/dotfiles/。
    {
      ".local/state/dotfiles/claude-accounts.json".text = builtins.toJSON accounts + "\n";
    }

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
