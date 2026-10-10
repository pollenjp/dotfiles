# Claude Code の設定。
#
# nix/files/claude/ 配下を ~/.claude/ へ配置する。
#
#   files/claude/CLAUDE.md      -> ~/.claude/CLAUDE.md      (全セッションで読まれる指示)
#   files/claude/CLAUDE.dev-tracker.md   CLAUDE.md の「タスク管理」の節。
#                                        dotfiles.claude.devTracker.enable のマシンでだけ
#                                        CLAUDE.md の末尾に連結する (下記)
#   files/claude/statusline-command.sh -> ~/.claude/statusline-command.sh
#   files/claude/footer-links.json -> ~/.local/state/dotfiles/claude-footer-links.json
#                                     (settings.json の footerLinksRegexes に写す値。下記)
#   files/claude/skills/<name>/ -> ~/.claude/skills/<name>  (ディレクトリ単位)
#   files/claude/agents/<name>.md   -> ~/.claude/agents/<name>.md
#   files/claude/commands/<name>.md -> ~/.claude/commands/<name>.md
#   pkgs.herdr の share/skills/herdr/herdr/ -> ~/.claude/skills/herdr  (パッケージ同梱の skill。下記)
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
#   ├── herdr/             <- Nix 管理 (herdr パッケージの中への symlink。下記)
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
#                    (フック / statusLine の登録、git の設定を渡す env、
#                    skill を隠す skillOverrides、footer のリンクの footerLinksRegexes)
#                    は scripts/bootstrap-claude-*.sh がマシンごとに注入する。
#                    skillOverrides・env・footerLinksRegexes は望む値を
#                    ~/.local/state/dotfiles/claude-skill-overrides.json /
#                    claude-env.json / claude-footer-links.json に Nix が置き (下記)、
#                    script はそれを写すだけにしている
#   plugins/       : 実行時に取得・更新される
#   claude-skills/ : private リポジトリなので public な flake.lock に載せられず、
#                    載せると CI の nix flake check も fetch できずに落ちる。
#                    scripts/bootstrap-claude-skills.sh が作業クローンへ
#                    symlink を張る。詳細は nix/README.md
#   ~/.claude-<名前>/ : 下の claude-<名前> コマンドが使う dir。中身の symlink と plugin は
#                    scripts/bootstrap-claude-accounts.sh が用意する (次節)
#
# ## Notion へ書く skill の宛先 (claude-notion.json)
#
# dotfiles.claude.notion.{profile,override} を ~/.local/state/dotfiles/claude-notion.json に
# 書き出す。値の中身 (workspace・ページ・DB の id) は private の claude-skills
# (skills/pjp-notion-profile/profiles.toml) が持ち、その resolver がこの JSON と重ねる。
#
# ## ログインアカウントを分ける (claude-personal / claude-work)
#
# `claude-<名前>` は CLAUDE_CONFIG_DIR=~/.claude-<名前> で claude を起動するコマンド。
# 分けるのはログインだけで、~/.claude-<名前>/ は CLAUDE.md・settings.json・projects を
# ~/.claude への symlink で共有し、skills/ などは中身をリンクで写す。実体で持つのは
# ログイン (.credentials.json・.claude.json)・plugins/ と、Claude Code が実行中に書くもの
# (history.jsonl・sessions/ など)。素の `claude` と ~/.claude は今まで通り。
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

  # Claude のセッション (Bash tool) にだけ渡す git の設定。1 組が
  # GIT_CONFIG_KEY_<n> / GIT_CONFIG_VALUE_<n> の 1 対になる (並びもこのまま)。
  #
  #   gitConfigBase  いつも入れる。commit / tag を無署名にする (1Password の
  #                  承認ダイアログで止まるため)
  #   gitConfigGh    gitViaGh.enable のときだけ入れる。GitHub の ssh の URL を
  #                  https に読み替え、資格情報を gh の token から取る
  gitConfigBase = [
    {
      k = "commit.gpgsign";
      v = "false";
    }
    {
      k = "tag.gpgsign";
      v = "false";
    }
  ];
  gitConfigGh = [
    {
      k = "url.https://github.com/.insteadOf";
      v = "git@github.com:";
    }
    {
      k = "url.https://github.com/.insteadOf";
      v = "ssh://git@github.com/";
    }
    {
      k = "credential.https://github.com.helper";
      v = "!gh auth git-credential";
    }
  ];

  # dir 名 (~/.claude-<名前>) とコマンド名に使う。bootstrap も同じ規則で弾くので、
  # 合わない名前を足したときはコマンドだけできて永遠に「未準備」になる前に、ここで止める。
  accounts =
    let
      names = [
        "personal"
        "work"
      ];
      valid = n: builtins.match "[a-z0-9][a-z0-9_-]*" n != null;
    in
    assert lib.assertMsg (builtins.all valid names)
      "claude.nix: accounts の名前は英小文字・数字・- と _ だけにする (${builtins.toJSON names})";
    names;

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
          if [[ -e "''${dir}/settings.json" ]]; then
            echo "claude-${name}: ''${dir}/settings.json が実ファイルです (bootstrap より先に" >&2
            echo "  この dir で Claude Code を起動した、など)。nix/README.md「Claude Code の" >&2
            echo "  アカウントを分ける」の「既に ~/.claude-<名前> があるとき」の手順で片付けてから、" >&2
            echo "  ~/dotfiles/setup --steps bootstrap-claude-accounts を実行してください。" >&2
          else
            echo "claude-${name}: ''${dir} がまだ用意されていません。" >&2
            echo "  ~/dotfiles/setup --steps bootstrap-claude-accounts を実行してください。" >&2
          fi
          exit 1
        fi

        # claude は mise 管理。`mise activate` したシェルなら PATH にあるが、シェルを
        # 通さずに起動されたときは mise に実体を聞く (bootstrap-claude-plugins.sh と同じ)。
        claude=$(command -v claude || true)
        if [[ -z "''${claude}" ]] && command -v mise >/dev/null; then
          claude=$(mise which claude 2>/dev/null || true)
        fi
        if [[ -z "''${claude}" ]]; then
          echo "claude-${name}: claude が見つかりません (mise で入れる: ~/dotfiles/setup --steps bootstrap-mise)。" >&2
          exit 127
        fi

        # この dir で /login したアカウントで動かす。/login の資格情報より優先される
        # env (API キー・OAuth トークン) は外す
        unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_AUTH_TOKEN
        export CLAUDE_CONFIG_DIR="''${dir}"
        exec "''${claude}" "$@"
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
  # Dev Tracker を使うのに Notion の宛先を選んでいないマシンでは、pjp-dev-tracker の
  # ticket.sh が「宛先が決まらない」で止まる。どの経路の switch でも気付けるよう、
  # 評価時に警告を出す (option の値しか見ないので、宛先のキーの意味には立ち入らない)。
  warnings =
    lib.optional (cfg.devTracker.enable && cfg.notion.profile == null && cfg.notion.override == { })
      ''
        dotfiles.claude.notion.profile が未設定です (dotfiles.claude.devTracker.enable = true のマシン)。
        Notion へ書く skill (pjp-dev-tracker など) は宛先が決まらず止まります。
        ~/dotfiles/flake.nix の local に dotfiles.claude.notion.profile = "personal"; (か "work") を書いて
        switch してください。local が無い古い雛形なら setup-local-flake.sh --force で作り直し、
        登録簿のホストを直接使っているなら mkHome に claude.notion.profile を渡します
        (nix/README.md「Notion の宛先を host ごとに選ぶ」)。
      '';

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
    # merge する。置き場は windows-files.json などと同じ ~/.local/state/dotfiles/。
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

    # Claude のセッションに渡す git の設定 (settings.json の env の GIT_CONFIG_*)。
    #
    # env も settings.json にしか書けないので、skill-overrides と同じく望む値だけを置き、
    # nix/scripts/bootstrap-claude-env.sh が写す。
    #
    #   managed    bootstrap が面倒を見るキー。env にあるこのキーの組はいったん全部外し、
    #              gitConfig を足し直す。gitViaGh.enable を false にしたとき HTTPS の組が
    #              消えるよう、option の値によらず両方の組のキーを載せる。
    #              使わなくなったキーも、ここからは外さずに残す (外すと settings.json に
    #              組が残り続ける)
    #   gitConfig  入れる組
    {
      ".local/state/dotfiles/claude-env.json".text =
        builtins.toJSON {
          managed = lib.unique (map (p: p.k) (gitConfigBase ++ gitConfigGh));
          gitConfig = gitConfigBase ++ lib.optionals cfg.gitViaGh.enable gitConfigGh;
        }
        + "\n";
    }

    # footer のリンク (settings.json の footerLinksRegexes)。会話に出た Dev Tracker の
    # チケットと PR を、Claude Code の footer にクリックできるバッジとして並べる。
    #
    # これも settings.json にしか書けないので、skill-overrides と同じく望む値だけを置き、
    # nix/scripts/bootstrap-claude-footer-links.sh が写す。値は option にせず、
    # files/claude/footer-links.json をそのまま置く (マシンごとに変える理由がまだ無い)。
    {
      ".local/state/dotfiles/claude-footer-links.json".source = claudeRoot + "/footer-links.json";
    }

    # Notion へ書く skill の宛先 (プロファイル名と、このマシンだけの上書き)。
    #
    # null / 空でも必ず書く。ファイルが無いのは「dotfiles が古い」、profile が null
    # なのは「このマシンで選んでいない」と、resolver が見分けて案内を出せるように。
    {
      ".local/state/dotfiles/claude-notion.json".text =
        builtins.toJSON {
          inherit (cfg.notion) profile override;
        }
        + "\n";
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

    # パッケージが同梱する agent skill。今は herdr だけ。
    #
    # nixpkgs の installAgentSkills は skill を $out/share/skills/<pname>/<skill>/ に
    # 入れるだけで、Claude Code はそこを探さない。使うものを 1 つずつ ~/.claude/skills/ へ
    # 張る (nixpkgs manual の installAgentSkills の節が勧める形)。
    #
    # home.packages の herdr (modules/packages.nix) と同じ pkgs.herdr を指すので、skill の
    # 版は CLI と揃い、flake.lock を上げれば一緒に上がる。公式の手順
    # (npx skills add herdrdev/herdr --skill herdr -g) は打った日の master を取り、
    # 宣言的でもないので使わない。名前は公式どおり herdr (pjp- は自作の印)。
    #
    # 張る元が無くても home-manager は切れた symlink を黙って作る。nixpkgs が置き場所を
    # 変えたら tests/claude-herdr-skill.nix (flake の checks) で落ちる。
    {
      ".claude/skills/herdr".source = "${pkgs.herdr}/share/skills/herdr/herdr";
    }

    (linkEntries "skills")
    (linkEntries "agents")
    (linkEntries "commands")
  ];
}
