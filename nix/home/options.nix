# このリポジトリ独自のオプション定義。
#
# 有効な組み合わせが構造に出るよう、WSL 固有の設定は dotfiles.wsl 配下へ入れ子にしている。
#
#   dotfiles.group                               設定グループ (personal・company・client。既定 personal)。段の switch の既定を決める
#   dotfiles.aiTools.enable                      ② AI の道具の段を入れるか (既定はグループから。personal・company は true)
#   dotfiles.personalAccounts.enable             ③ 個人のアカウントにつながるものの段を入れるか (既定はグループから。personal だけ true)
#   dotfiles.onePassword.enable                  1Password を使うか (WSL ならホスト側 Windows の、それ以外はこのマシンの)
#   dotfiles.opReason.sshRelay.enable            op-reason の SSH の中継を WSL の側で使うか (WSL の ssh を op-reason-ssh に向ける。Windows の側は runner のホストの値。既定 false)
#   dotfiles.opReason.sshRelay.mode              その中継のモード (per-call・show-only。既定 per-call)
#   dotfiles.git.identity.enable                 git の名前とメールを個人のアカウント (pollenjp・pollenjp-sub) にするか (既定は ③)
#   dotfiles.wsl.enable                          WSL か
#   dotfiles.wsl.windowsUserName                 ホスト側 Windows のユーザー名 (/mnt/c/Users/<名前>)
#   dotfiles.wsl.windowsFiles.enable             repo 直下の win/ を Windows 側へ配るか
#   dotfiles.wsl.windowsFiles.typeClipboard.enable  Windows に自作の type-clipboard を固定した版で入れるか (既定 false)
#   dotfiles.wsl.windowsFiles.ntn.enable         Windows に ntn (Notion の CLI) を winget で固定した版で入れるか (既定は ③)
#   dotfiles.wsl.windowsFiles.claudeCode.enable  Windows に Claude Code を winget で固定した版で入れるか (既定は ②)
#   dotfiles.wsl.windowsFiles.claudeAccounts.enable  Windows の runner が claude-personal・claude-work を用意するか (既定は ② と ③。UAC の確認が出る)
#   dotfiles.wsl.windowsFiles.herdr.enable       Windows に herdr と herdr-app を固定した版で入れるか (既定は ②)
#   dotfiles.wsl.windowsFiles.tailscale.enable   Windows に Tailscale を winget で固定した版で入れるか (既定 false。どのグループでも)
#   dotfiles.wsl.windowsFiles.sshd.enable        Windows に sshd (OpenSSH Server) を入れ、Tailscale から鍵でだけ入れるようにするか (既定 false。どのグループでも)
#   dotfiles.wsl.windowsFiles.sshd.authorizedKeys  その sshd に入れる公開鍵 (authorized_keys の行。既定 null: dotfiles は鍵を置かない)
#   dotfiles.wsl.onePassword.windowsUserName     WSL で 1Password のパスに要る Windows ユーザー名 (既定は上の windowsUserName)
#   dotfiles.wsl.exeExecTrace.enable             WSL から起動された .exe を祖先付きで常時記録するか (ADR 012)
#   dotfiles.wsl.mtuGuard.enable                 WSL の eth0 の MTU を上限まで下げ続ける見張り (system の unit) を置くか
#   dotfiles.wsl.mtuGuard.maxMtu                 その上限 (既定 1350。1280〜1500)
#   dotfiles.claude.enable                       Claude Code 一式 (設定・hook・skill・status line・plugin・mise の claude) を入れるか (既定は ②)
#   dotfiles.claude.privateSkills.enable         private な skill 置き場 (claude-skills) を clone して繋ぐか (既定は ② と ③)
#   dotfiles.claude.devTracker.enable            Notion Dev Tracker (pjp-dev-tracker) を使うマシンか
#   dotfiles.claude.devTracker.inbox.enable      チケットのコメントをハブ (~/h) の会話へ届ける見回り役を常駐させるか
#   dotfiles.claude.gitViaGh.enable              Claude の git と plugin の取得・fetch 系の abbr / alias・setup の取得を gh の資格情報 (HTTPS) で GitHub へ通すか
#   dotfiles.claude.notion.profile               Notion へ書く skill が既定に使う宛先のプロファイル名
#   dotfiles.claude.notion.routes                作業中の repo から宛先のプロファイルを決める、このマシンだけの規則
#   dotfiles.claude.notion.override              プロファイルの値をこのマシンだけ差し替える
#   dotfiles.claude.videoOffer.autoStart.enable  設計・PR のときに解説動画の短尺を答えを待たずに作り始めるか (既定 false: 先に聞く)
#   dotfiles.claude.heavyJobs.limitPercent       重い処理 (動画の書き出し・推論など) が使ってよい CPU とメモリの、マシン全体に対する割合 (既定 70)
#   dotfiles.claude.sshAgentNotice.extraCommands 中で ssh を打つ道具のうち、Claude が打つ前に「1Password の承認が出るかも」と知らせるもの
#   dotfiles.claude.iacGuard.enable              Claude が打つ terraform・tofu・terragrunt の apply など (実物を変える操作) を hook で止めるか (既定 true)
#   dotfiles.mise.minimumReleaseAge              mise が入れる版の遅延 (既定 9d。setup が ~/.config/mise/config.toml に書く)
#   dotfiles.mise.releaseAgeOverrides            期間を区切って遅延を緩める上書きの list (from・zeroDays・reason。日付は Asia/Tokyo)
#   dotfiles.cursorAgent.enable                  cursor-agent (Cursor の CLI) を mise で入れるか (既定 false。setup が入れた版に固定する)
#   dotfiles.cleanup.enable                      使わなくなった Nix の store path・世代と mise の版を週 1 回消すか
#   dotfiles.ccPages.enable                      cc-pages (clone と build・常駐のビューア) を入れるか (既定は ② と ③)
#   dotfiles.ccPages.port                        cc-pages のビューアが待ち受ける port (null なら cc-pages の既定の 7777)
#   dotfiles.ntn.enable                          ntn (Notion CLI) を入れるか (既定は ③)
#   dotfiles.ntn.keyring                         ntn (Notion CLI) の config.json の keyring (null なら触らない。false で token を auth.json に置く)
#   dotfiles.herdr.enable                        herdr (包み・ssh 先の agent の固定名・設定・abbr) を入れるか (既定は ②)
#   dotfiles.herdr.hub.enable                    herdr の集約ハブ ~/h を setup が作るか (既定は ② と ③)
#   dotfiles.herdrCore.enable                    herdr-core (hc) を入れるか (既定は ② で Linux なら true。herdr-app が SSH でつなぐ machine の側に要る)
#   dotfiles.osCaBundle.enable                   自前の証明書の束を持つツールを、環境変数で OS の信頼ストアに寄せるか (Linux)
#   dotfiles.osCaBundle.requestsCaBundle.enable  そのうち REQUESTS_CA_BUNDLE も入れるか
#
# 親が false なら子は意味を持たない、という関係がそのまま階層になっている。
# 平坦に並べていたときの「どの組み合わせが有効なのか判らない」を避けるため。
{
  config,
  lib,
  pkgs,
  ...
}:

let
  # JSON にそのまま書き出せる値 (dotfiles.claude.notion.override 用)
  jsonValue = (pkgs.formats.json { }).type;

  # 暦にある日付 (YYYY-MM-DD。dotfiles.mise.releaseAgeOverrides の from 用)。nixpkgs の猶予の例外の date
  # (lib/release-age.nix) と共用する
  calendarDate = import ../lib/calendar-date.nix { inherit lib; };

  # 設定グループと段への割り当ての表 (lib/groups.nix)。段の switch の既定をグループから引く。道具の switch の既定は、段の
  # switch を素の式 (config.dotfiles.aiTools.enable など) で書く (どれも option の既定 (優先度 1500) なので、ホストの素の値が勝つ。
  # 素の式にしておくと、dotfiles-private の hostmap の読み手も既定をたどれる)
  groups = import ../lib/groups.nix;
in
{
  # 1Password は WSL 専用の dotfiles.wsl.onePassword.enable だったのを、WSL 以外でも使えるよう
  # dotfiles.onePassword.enable へ出した (ADR 022)。ローカル flake (git 管理外) に旧名が残っていても
  # 評価が止まらないよう、旧名は新しい名前へ渡して警告を出す。
  imports = [
    (lib.mkRenamedOptionModule
      [ "dotfiles" "wsl" "onePassword" "enable" ]
      [ "dotfiles" "onePassword" "enable" ]
    )
  ];

  options.dotfiles.group = lib.mkOption {
    type = lib.types.enum groups.groupNames;
    default = "personal";
    example = "client";
    description = ''
      このホストの設定グループ (dotfiles-private の docs/adr/057_host_setting_groups_*)。グループは「どの段まで入れるか」で
      決まり、段の switch (`aiTools.enable`・`personalAccounts.enable`) の既定になる。段の switch は、その段の道具の switch
      (`claude.enable`・`ntn.enable` など) の既定になる。表は lib/groups.nix。

      | グループ | ① エンジニアの道具 | ② AI の道具 | ③ 個人のアカウント |
      | --- | --- | --- | --- |
      | personal (個人の PC。既定) | on | on | on |
      | company (自社の PC) | on | on | off |
      | client (客先の PC) | on | off | off |

      personal は段が全部 on で、どの道具も今までの既定と同じになる。グループを選ばないホストは personal。

      mkHome の引数で `group = "client";` のように選ぶ (dotfiles-private に登録したファイルか、ローカル flake の tmp)。どれも
      option の既定なので、ホストのファイルはグループ・段・道具のどこでも素の値で上書きできる (客先で Claude Code だけ許可が
      出たら `claude.enable = true;`)。値は `~/.local/state/dotfiles/group.json` (home/modules/group.nix) に落ち、setup は off の
      道具の手順を飛ばす。書き方は nix/README.md「設定グループ」。
    '';
  };

  options.dotfiles.aiTools.enable = lib.mkOption {
    type = lib.types.bool;
    default = groups.groupHasTier config.dotfiles.group "aiTools";
    defaultText = lib.literalExpression ''config.dotfiles.group != "client"'';
    example = false;
    description = ''
      ② AI の道具の段を入れるか。既定はグループから決まる (personal・company は true、client は false)。この段の道具の switch
      (`claude.enable`・`herdr.enable`・`herdrCore.enable`・`wsl.windowsFiles.claudeCode.enable`・`wsl.windowsFiles.herdr.enable`) の
      既定になる。② と ③ の両方に当たる道具 (`claude.privateSkills.enable`・`ccPages.enable`・`herdr.hub.enable`・
      `wsl.windowsFiles.claudeAccounts.enable`) は、`personalAccounts.enable` も true のときだけ既定で入る。`cursorAgent.enable` は
      既定が false のまま (段によらない)。
    '';
  };

  options.dotfiles.personalAccounts.enable = lib.mkOption {
    type = lib.types.bool;
    default = groups.groupHasTier config.dotfiles.group "personalAccounts";
    defaultText = lib.literalExpression ''config.dotfiles.group == "personal"'';
    example = false;
    description = ''
      ③ 個人のアカウントにつながるものの段を入れるか。既定はグループから決まる (personal だけ true)。この段の道具の switch
      (`ntn.enable`・`wsl.windowsFiles.ntn.enable`・`git.identity.enable`) の既定になる。② と ③ の両方に当たる道具
      (`wsl.windowsFiles.claudeAccounts.enable` など) は `aiTools.enable` も true のときだけ既定で入る。`onePassword.enable`・`claude.devTracker.enable` は既定が false のまま
      (段によらず、使うホストが入れる)。

      自社の PC (company) は ③ を段ごと戻さず、要る道具を 1 つずつ足す (何に頼っているかがホストのファイルで分かるように)。
    '';
  };

  options.dotfiles.git.identity.enable = lib.mkOption {
    type = lib.types.bool;
    default = config.dotfiles.personalAccounts.enable;
    defaultText = lib.literalExpression "config.dotfiles.personalAccounts.enable";
    example = false;
    description = ''
      git の名前とメールを個人のアカウントにするか (home/modules/git.nix)。true なら `user.name`・`user.email` を pollenjp にし、
      `~/workdir/github.com/pollenjp-sub` の下の repo だけ pollenjp-sub にする。既定は ③ の段 (`personalAccounts.enable`)。

      false なら名前もメールも書かない。そのホストで使う名前とメールを、ホストの modules に
      `programs.git.settings.user = { name = "…"; email = "…"; };` で書く (書かなければ git は commit の前に止まり、
      「Please tell me who you are」と出す。別の名前で commit してしまうことは無い)。
    '';
  };

  options.dotfiles.onePassword.enable = lib.mkOption {
    type = lib.types.bool;
    default = false;
    example = true;
    description = ''
      1Password を使うか。WSL (`wsl.enable = true`) ならホスト側 Windows の、それ以外のマシンなら
      そのマシンの 1Password を使う。

      true のとき、git の署名を 1Password の鍵で行う:

      - `gpg.format = ssh`、`commit.gpgSign = true` (署名を既定にする)
      - `gpg.ssh.defaultKeyCommand` で ssh-agent の鍵から名前に "Signing" を含むものを選ぶ
      - 署名のプログラム (`gpg.ssh.program`):
        - WSL: Windows 側の op-ssh-sign-wsl.exe (パスは `wsl.onePassword.windowsUserName` から組み立てる)。
          ssh / ssh-add も Windows 側の実体へ差し替える (home/modules/ssh.nix)
        - それ以外: home-manager の既定 (openssh の ssh-keygen)。`SSH_AUTH_SOCK` のエージェントで
          署名するので、手元では 1Password の SSH エージェント、ssh 先では転送されてきたエージェントの
          同じ鍵で署名できる。`SSH_AUTH_SOCK` を 1Password へ向けるのは system の側
          (NixOS の laptop は nixos-config の ADR 009)

      false のときは署名関連の設定を一切書き出さない。1Password の無いマシンで
      `commit.gpgSign = true` だけが残ると、署名鍵が見つからず `git commit`
      そのものが失敗するため。
    '';
  };

  options.dotfiles.opReason.sshRelay = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      example = true;
      description = ''
        op-reason (自作の OSS。WSL の op の wrapper) の SSH の中継 (`op-reason.exe --ssh-agent`。1Password の SSH agent の前に
        立ち、鍵を使う呼び出しごとに「誰が・何のために」を窓に出して許可させる) を、WSL の側で使うマシンか。既定は false
        (今までどおり、ssh は 1Password の agent に直に行く)。使えるのは、Windows の受け持ちを runner に切り替えた WSL +
        1Password のマシン (`wsl.enable`・`onePassword.enable` が true で `wsl.windowsFiles.enable` が false) だけ (ほかで true に
        すると評価で止まる)。

        Windows の側は、Windows の runner (`dotfiles apply`) が、ホストの値 (`win/hosts/*.toml`) の `[tools] opReasonSshRelay = true`
        で置く (win/README.md の「SSH の中継」)。同じ PC で両方を on にする (片方だけだと、中継を通らないのに窓の知らせが出る・
        WSL の ssh だけが中継に向くなど食い違う):

        - runner の手順 op-reason が、`Install-OpReason.ps1 -SshRelay <モード>` で logon の task (`\pjp\op-reason-ssh-relay`。
          trigger は logon と 1 分ごと) を置いて中継を起こす。版を上げるときは中継を止めて入れ替え、起こし直す (中継が窓を
          開いている間は止めない)
        - runner の手順 ssh-config が、中継が答えるのを見てから、Windows の `%USERPROFILE%\.ssh\config.d\` の最初に読まれる
          ファイル (`00-op-reason-ssh-relay.ssh_config`) に、どの接続先にも効く `IdentityAgent` (中継の pipe) を書く。Windows の
          ssh.exe (herdr-app の lavie へのつなぎ・pf も) は中継を通る

        この option が true のマシンでは:

        - WSL の `ssh` の wrapper (`~/.local/bin/ssh`) は `ssh.exe` でなく `op-reason-ssh` を起こす (呼び出しの事実を中継へ渡す。
          git・rsync も PATH の ssh なので通る)。`ssh-add` は今のまま
        - Claude の hook (ssh-agent-notice) は、ssh の前に「op-reason の窓が出る」と知らせ、理由 (`OPREASON_SSH_REASON`) を
          付けるよう Claude に言う

        中継が動いていなければ、ssh は鍵を使えない (黙って 1Password に直に回らない)。1 回だけ 1Password に直につなぐ書き方と、
        中継の起こし直し方は win/README.md の「SSH の中継」。false に戻すと、次の setup が wrapper を `ssh.exe` に戻す (Windows の
        側は、ホストの値の opReasonSshRelay を外した次の `dotfiles apply` が task と `IdentityAgent` のファイルを消す)。
      '';
    };

    mode = lib.mkOption {
      type = lib.types.enum [
        "per-call"
        "show-only"
      ];
      default = "per-call";
      example = "show-only";
      description = ''
        中継のモード (`op-reason.exe --ssh-agent --mode <mode>`)。`per-call` は op-reason の窓で呼び出しごとに許可する
        (1Password はロックを解いた後に中継を 1 回承認するだけ。1Password の設定は「アプリケーションおよびターミナルセッション」
        のまま)。`show-only` は決めるのが 1Password の画面のままで、op-reason の窓は誰が・何のためにを並べて見せるだけ
        (1Password を「リクエストごと」にする人向け)。この値は WSL の側 (hook の文) に効く。中継そのもののモードは、Windows の
        runner のホストの値の `[opReason] sshRelayMode` (同じ値にする。替えると、次の `dotfiles apply` が task を置き直して中継を
        起こし直す)。
      '';
    };
  };

  options.dotfiles.claude = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = config.dotfiles.aiTools.enable;
      defaultText = lib.literalExpression "config.dotfiles.aiTools.enable";
      example = false;
      description = ''
        Claude Code 一式を入れるか。既定は ② の段 (`aiTools.enable`)。

        true のとき入るもの: `~/.claude` の CLAUDE.md・hook・skill・agent・command・status line と、`~/.local/state/dotfiles/` の
        Claude Code 向けの state (home/modules/claude.nix)、`claude-<名前>` のコマンド、fish・bash の abbr / alias の `c`。setup の
        手順では、mise の claude (bootstrap-mise.sh) と bootstrap-claude-* (plugin・hook と status line の登録・env・footer の
        リンク・skillOverrides・アカウントの dir)。

        false なら、どれも入れない (setup は bootstrap-claude-* を飛ばし、mise の claude を入れない。前に入れたものは消さない)。
        客先の PC で利用の許可が出たら、そのホストで `claude.enable = true;` を書く (claude-skills・cc-pages・herdr は入らない)。
        `git-via-gh.json` (setup の取得が gh を使うか) は Claude Code によらず書く。
      '';
    };

    privateSkills.enable = lib.mkOption {
      type = lib.types.bool;
      default = config.dotfiles.aiTools.enable && config.dotfiles.personalAccounts.enable;
      defaultText = lib.literalExpression "config.dotfiles.aiTools.enable && config.dotfiles.personalAccounts.enable";
      example = false;
      description = ''
        private な skill 置き場 (pollenjp/claude-skills) を clone して `~/.claude/` に繋ぐか (setup の bootstrap-claude-skills.sh)。
        既定は ② と ③ の段が両方 on のとき (Claude Code の道具で、private な repo でもあるため)。`claude.enable` が要る
        (false のマシンで true にすると評価で止まる)。

        false なら setup は clone も繋ぎ直しもしない (前に clone したものと張った symlink は消さない)。Dev Tracker
        (`devTracker.enable`) と集約ハブ (`herdr.hub.enable`) は claude-skills の skill を使うので、これが要る。
      '';
    };

    devTracker.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      example = true;
      description = ''
        このマシンで Notion Dev Tracker (pjp-dev-tracker skill) を使うか。

        1 つの値から 2 つが決まる (home/modules/claude.nix):

        - `~/.claude/CLAUDE.md` の「タスク管理」の節 (files/claude/CLAUDE.dev-tracker.md)。
          false なら連結しない。節だけが残ると Claude が無い skill を探しに行くため
        - `~/.local/state/dotfiles/claude-skill-overrides.json` の値 ("on" / "off")。
          nix/scripts/bootstrap-claude-skill-overrides.sh がこれを
          `~/.claude/settings.json` の skillOverrides へ写し、false なら skill が
          Claude の一覧からも `/` メニューからも消える

        settings.json は Claude Code 自身が書き換えるので Nix では置けない。
        そのため反映は 2 段で、`home-manager switch` だけでは skillOverrides に
        届かない。`~/dotfiles/setup --update` (bootstrap まで走る) で揃える。

        既定は false (使わない)。使うマシンだけ true を書く: dotfiles-private に
        登録したホストのファイル、ローカル flake (~/dotfiles/flake.nix) に足した tmp
        (雛形の例は true を書く)、検証用の sandbox。登録簿の型のホスト
        (`<user>@<system>`) を `--host` で当てたマシンでは使わない
        (dotfiles-private の docs/adr/027_*。前は既定が true で、ローカル flake の雛形の local が false を書いていた)。

        skill (pjp-dev-tracker) は claude-skills にあるので、`claude.privateSkills.enable` が要る (false のマシンで true に
        すると評価で止まる)。既定は設定グループ (`group`) によらず false (② と ③ の段の道具だが、使うホストが入れる)。
      '';
    };

    devTracker.inbox.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      example = true;
      description = ''
        Dev Tracker のチケットに書いたコメントを、ハブ (`~/h`) の会話へ届ける見回り役
        (claude-skills の pjp-dev-tracker の `ticket.sh inbox`) を、systemd の user service
        `pjp-dev-tracker-inbox` で常駐させるか (home/modules/dev-tracker-inbox.nix)。
        `devTracker.enable = true` のときだけ使える (false のマシンで true にすると評価時に止まる)。

        見回り役は、herdr で動いているハブの会話のチケットのページへのコメントを 30 秒ごとに読み、
        ユーザーが書いたものをその会話の入力欄へ打つ。コメントの拾い方・届け方は claude-skills の側。

        既定は false。herdr でハブの会話を回すホストだけ true を書く (dotfiles-private に登録した
        ファイルか、ローカル flake の tmp)。見回り役は自分のマシンに worktree の無いチケットを
        読まないので、複数のホストで動かしても互いの会話のチケットには書かない。ただ、プロファイルに
        ユーザーの Notion の id (claude-skills の profiles.toml の user.id) が無いホストでは終了コード 2 で
        止まったままになり、ハブの会話を回さないホストでは Notion を引くだけになる。

        - 反映は `~/dotfiles/setup --update`。switch が unit を置いて起こし、bootstrap
          (nix/scripts/bootstrap-dev-tracker-inbox.sh) が claude-skills を進めた後に起こし直す
          (claude-skills の更新では unit ファイルが変わらず、switch だけでは再起動しない)
        - claude-skills を取れない (ticket.sh が無い)・ハブ `~/h` がまだ無いマシンでは、
          条件不成立としてスキップする (failed で残らない。bootstrap が無い方と直し方を警告する)
        - 設定の誤り (ユーザーの Notion の id が無いなど) と inbox の無い古い ticket.sh は、
          終了コード 2 で止まったまま、再起動を繰り返さない
        - Linux だけ (macOS には launchd の agent を置いていない。true を書くと評価のたびに警告が出る)

        状態は `systemctl --user status pjp-dev-tracker-inbox`、ログは
        `journalctl --user -u pjp-dev-tracker-inbox`。
      '';
    };

    gitViaGh.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      example = false;
      description = ''
        Claude Code のセッションの git と、自分のターミナルの fetch 系の abbr / alias と、
        setup の取得が GitHub と通信するとき、gh の資格情報で HTTPS を使うか。false なら
        今までどおり ssh (WSL では 1Password の agent) を通る。

        true のとき、Claude のセッション (Bash tool) にだけ次の git の設定を env で渡す
        (組は lib/git-via-gh.nix):

        - `url.https://github.com/.insteadOf` に `git@github.com:` と `ssh://git@github.com/`。
          fetch と push の両方で、GitHub の ssh の URL を https に読み替える
        - `credential.https://github.com.helper = !gh auth git-credential`。
          資格情報は gh の token から取る

        この env は Claude Code 自身が打つ git (plugin の marketplace と plugin の clone・fetch) にも届くので、
        そちらも https と gh の token で取る。加えて env に `CLAUDE_CODE_PLUGIN_PREFER_HTTPS=1` を入れる。
        Claude Code は source が GitHub の marketplace と plugin を取る前に `ssh -T git@github.com` で鍵が
        通るかを確かめ (plugin の自動更新では会話ごとに 1 回、最初の発言から最大 10 分のどこか)、WSL では
        その ssh が 1Password の承認を出す。この env があると確認を飛ばして最初から https の URL で取るので、
        承認が出なくなる。取れる repo (private も) は変わらない (https で取れなくても ssh には切り替えない)。
        false なら env から消え、今までどおり ssh で確かめ、鍵が通れば ssh で取る。

        自分のターミナルでは、素の git は変わらない。変わるのは fish の abbr と bash の alias の
        fetch 系 (gf・gfp・gpul・gpull・gcl と、gpr などの git_* の関数) で、同じ組を -c で付ける
        `git gh` (pkgs/git-gh) で打つようになる (home/modules/fish.nix・bash.nix)。gfp は gfp-gh と
        同じ中身になり、false なら gfp-base (今までの gfp) と同じ中身になる。push 系 (gp・gpf・gpup) は
        option によらず ssh のまま。gfp-base・gfp-gh・git gh は option によらず使える。

        setup が GitHub から取るとき (bootstrap の claude-skills・cc-pages・dotfiles-private の
        clone / 取得と、origin が GitHub の ssh の URL のときの本体の更新 (--self-update) の fetch) も、
        git gh で先に試す。gh か git-gh が無い・github.com にログインしていない・git gh で
        取れないときは ssh で取り直す (nix/scripts/ の git_github。TKT-221)。ssh を張り直したあとの herdr の中のように
        SSH_AUTH_SOCK が切れていても、gh が使えれば取れる。値は
        `~/.local/state/dotfiles/git-via-gh.json` (home/modules/claude.nix) に落ち、switch の後の
        setup の手順から効く (本体の更新は switch より前に走るので、前の世代の値で動く)。

        ssh は WSL の ssh.exe を通るので、interop が外れると Exec format error で落ち、
        通っても 1Password の承認ダイアログで止まる。gh は HTTPS の API なので
        どちらにも依らない。

        gh は home/modules/packages.nix が入れる。前提は `gh auth login` 済みであること
        (gh が無い・未ログインなら bootstrap が警告し、setup の最後のまとめにも出す)。
        token に workflow scope が無いと、`.github/workflows/` を変える push を
        GitHub が拒否する (`gh auth refresh -h github.com -s workflow` で足す)。

        Claude の側の値は `~/.local/state/dotfiles/claude-env.json` (home/modules/claude.nix) に落ち、
        nix/scripts/bootstrap-claude-env.sh が `~/.claude/settings.json` の env へ写す。
        devTracker.enable と同じく反映は 2 段で、`home-manager switch` だけでは
        settings.json に届かない。`~/dotfiles/setup --update` で揃える。abbr / alias の側は
        switch だけで変わる (開き直したシェルから)。
      '';
    };

    notion = {
      profile = lib.mkOption {
        type = lib.types.nullOr (lib.types.strMatching "[a-z0-9][a-z0-9_-]*");
        default = null;
        example = "personal";
        description = ''
          Notion へ書く skill (claude-skills の pjp-dev-tracker・pjp-notion-authoring・
          pjp-docs-to-notion・pjp-scan-to-notion) が、このマシンで既定に使う宛先のプロファイル名。

          宛先は作業中の repo で決まる: このマシンの routes → profiles.toml の [routes] → この既定。
          規則に当たらない repo (OSS の clone など) と repo の外 (スキャンのフォルダなど) でこれを使う。

          中身 (workspace の id・Dev Tracker の場所・新しいページの既定の親・Scan Data DB・
          repo にチケットの ID と URL を書くか)
          は private の claude-skills (skills/pjp-notion-profile/profiles.toml) が持ち、
          ここでは名前だけを選ぶ。ページ名入りの URL を public なこのリポジトリに
          出さないため。

          null (既定) のマシンでは、規則に当たらない repo と repo の外で skill が止まる
          (黙って別の workspace へ書かないため)。devTracker.enable = true なのに null の
          マシンでは、評価のたびに警告が出る (home/modules/claude.nix)。

          home/modules/claude.nix が ~/.local/state/dotfiles/claude-notion.json に
          書き出し、claude-skills の resolver がそれを読む。反映は home-manager switch
          (~/dotfiles/setup --update でもよい)。
        '';
      };

      routes = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        example = lib.literalExpression ''
          {
            "pollenjp/*" = "work";
            "pollenjp/some-repo" = "personal";
          }
        '';
        description = ''
          このマシンだけの宛先の規則。作業中の repo (origin の owner/repo) から、使うプロファイルの
          名前を決める。キーは "owner/*" か "owner/repo"、値は profiles.toml にあるプロファイルの名前。

          claude-skills の profiles.toml の [routes] (全マシンで共通の規則) より先に見る。
          同じ層の中 (このマシンの規則どうし、共通の規則どうし) では、"owner/repo" の行が "owner/*" の行に勝つ。
          どちらにも当たらない repo と repo の外では profile (このマシンの既定) を使う。

          キーと値の綴りはここでは検査しない (resolver が使うときに止める)。
        '';
      };

      override = lib.mkOption {
        type = lib.types.attrsOf jsonValue;
        default = { };
        example = lib.literalExpression ''
          {
            personal = {
              scanData = "https://app.notion.com/p/…";
              devTracker = null;
            };
          }
        '';
        description = ''
          プロファイルの値を、このマシンだけ差し替える。外側のキーはプロファイルの名前で、
          中のキーは profiles.toml と同じ (workspace.id / defaultParent / scanData / devTracker.hub /
          devTracker.linkFromRepo など)。入れ子はプロファイルの値へ重ね、同じキーはこちらが勝ち、
          null はそのキーを消す。

          devTracker.linkFromRepo だけは真偽値で、pjp-dev-tracker が branch・PR・commit に
          チケットの ID と URL を書くかを決める (書かなければ true。work のプロファイルは false)。
          このマシンだけ変えるなら `{ work = { devTracker.linkFromRepo = true; }; }` のように書く。

          キーの綴りはここでは検査しない (キーの形は claude-skills が持つ)。
          skill が使うときに resolver が知らないキーとして止める。
        '';
      };
    };

    videoOffer.autoStart.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      example = true;
      description = ''
        設計を出したとき・PR を作ったときに、解説動画の短尺を答えを待たずに裏の subagent で
        作り始めるか (claude-skills の pjp-video-explainer-offer)。false (既定) なら、作る前に
        「解説動画を作りますか？」と聞き、選ばれたときだけ作る。1 本ごとにコンテキストを大きく
        使うので、既定は聞く方にしている (dotfiles-private の docs/adr/023_claude_video_offer_host_option_*)。

        値は `~/.local/state/dotfiles/claude-video-offer.json` (`{"autoStart": <bool>}`) に落ち
        (home/modules/claude.nix)、次の 2 つが読む:

        - hook (files/claude/hooks/video-offer-nudge.sh): 設計の書き出しと PR の作成で Claude に
          差し込む文を、true なら「短尺を作り始める」、false なら「作るかを聞く」にする
        - claude-skills の pjp-video-explainer-offer: true なら答えを待たずに作り始め、
          false なら先に聞く。ファイルが無い・壊れているときも聞く

        `~/.claude/CLAUDE.md` の「解説動画を作るか聞く」の節は、この値によらず同じ文で、
        どちらにするかは skill に任せている。skill の見え方 (skillOverrides) も変えない。
        ユーザーが名指しで頼んだ解説動画 (pjp-video-explainer-pictogram / dialogue) は、
        この値によらず作れる。

        反映は home-manager switch (~/dotfiles/setup --update でもよい)。settings.json は
        通らないので bootstrap は要らない。作り始める方にしたいマシンは、dotfiles-private に
        登録したホストのファイルか、ローカル flake の tmp で true にする。
      '';
    };

    heavyJobs.limitPercent = lib.mkOption {
      type = lib.types.ints.between 1 100;
      default = 70;
      example = 40;
      description = ''
        重い処理が使ってよい CPU とメモリの上限を、このマシン全体に対する割合 (%) で決める。claude-skills の
        skill pjp-heavy-jobs の scripts/limit.sh が、包んだコマンドを systemd の user slice pjp-heavy.slice に
        入れ、slice に上限を付ける。上限は slice の中の合計に効くので、別々の会話が同時に重い処理を流しても、
        合わせて上限の内に収まる (dotfiles-private の docs/adr/043_claude_heavy_jobs_limit_host_option_*)。

        重い処理は、数分以上 CPU を使い切るか GB 単位でメモリを取る処理 (動画の書き出し・エンコード、コマや
        画像をまとめて読む処理、whisper などの推論、重い処理を並べて流すとき)。どれを包むかは pjp-heavy-jobs の
        SKILL.md が決め、動画の雛形の render-all.sh などは自分で包む。縛るのは limit.sh で包んだ処理だけ。

        割合は次のように効く:

        - CPU: CPUQuota = 割合 × nproc (systemd の CPUQuota は CPU 1 つを 100% と数える)。nproc は包むたびに
          数える。WSL の nproc は、既定では Windows の論理 CPU の全部なので、PC 全体に対する割合になる
        - メモリ: MemoryMax=<割合>%。systemd は kernel から見えるメモリに対して割合を取る。WSL では VM の
          メモリに対してで、VM のメモリは既定で Windows の半分ほど (40 なら PC 全体の約 20%)
        - swap: 重い処理には使わせない (MemorySwapMax=0)

        値は `~/.local/state/dotfiles/claude-heavy-jobs.json` (`{"limitPercent": <値>}`) に落ち
        (home/modules/claude.nix)、limit.sh が包むたびに読む。ファイルが無い・読めないときは
        70 で縛る。cgroup v2 の cpu・memory が systemd の user manager に委譲されていないマシンでは、
        その分の上限は付かない (limit.sh が警告を 1 行出し、CPU は nice で流す)。

        反映は home-manager switch (~/dotfiles/setup --update でもよい)。上限は次に包むときに付け直す。
        割合を変えたいマシンは、dotfiles-private に登録したホストのファイルか、ローカル flake の tmp に書く。
      '';
    };

    sshAgentNotice.extraCommands = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "nix run .#vm" ];
      description = ''
        中で ssh を打つ道具のうち、Claude Code が Bash で打つ前に「🔑 1Password の承認が出るかも」と
        知らせるもの (hook の files/claude/hooks/ssh-agent-notice.sh。dotfiles-private の docs/adr/029_claude_ssh_agent_notice_*)。
        ssh・scp・rsync・nixos-rebuild --target-host・git の署名などは hook が自分で見つけるので、ここには
        コマンドの文字に ssh が出ない道具 (infra-v2 の nix run .#vm など) だけを書く。

        項目は語を空白で区切った文字列で、1 語目をコマンドの頭の語 (そのままか basename) に、残りの語を
        引数の中に順に当てる (間に別の語があってよい。"nix run .#vm" は nix run -L .#vm -- ip にも当たる)。
        各語は bash の glob として比べる ("*/deploy.sh" など)。書いていない道具でも、agent に断られれば
        hook がそのあとで選択肢の問いを出させる。

        値は `~/.local/state/dotfiles/claude-ssh-agent-notice.json` (`{"extraCommands": [...]}`) に落ち
        (home/modules/claude.nix)、hook が読む。反映は home-manager switch (~/dotfiles/setup --update でもよい)。
        使う PC のホストの値 (dotfiles-private に登録したファイルか、ローカル flake の tmp) に書く。
      '';
    };

    iacGuard.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      example = false;
      description = ''
        Claude Code が Bash で打つ terraform・tofu・terragrunt の操作のうち、実物 (資源か state) を変えるもの
        (apply・destroy・import・state rm など) を、打つ前に止めるか (hook の files/claude/hooks/install-iac-guard.sh)。
        既定は true (止める)。実環境への apply は merge の後に人が流し、Claude は検査か plan までにする
        (claude-skills の docs/superpowers/specs/2026-11-13-lang-prefs-pack-design.md の §3.5)。

        false にするのは、agent が sandbox で自分でプロジェクトを作って消すマシン (止めると agent が進めない) だけ。
        false でも、同じ hook が止める venv・project の外への install (pip install・npm install -g・apt install・
        brew install など) は止める。止めたコマンドを流すときは、ユーザーが明示したうえでコマンドの頭に
        PJP_ALLOW_IAC=1 を付ける (マシンごと外すのではなく 1 回だけ通す口)。

        値は `~/.local/state/dotfiles/claude-iac-guard.json` (`{"enable": <bool>}`) に落ち
        (home/modules/claude.nix)、hook が読む。ファイルが無い・壊れているときは止める。反映は home-manager switch
        (~/dotfiles/setup --update でもよい)。外すマシンは、dotfiles-private に登録したホストのファイルか、
        ローカル flake の tmp に書く。
      '';
    };
  };

  options.dotfiles.cleanup.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    example = false;
    description = ''
      使わなくなった Nix の store path・古い世代と、mise の使っていない版を、
      週 1 回自動で消すか (home/modules/cleanup.nix)。

      - Nix: home-manager の nix.gc で `nix-collect-garbage --delete-older-than 14d`。
        14 日より古い世代は消え、そこへはロールバックできなくなる
      - mise: `mise prune --yes` と、mise の downloads/ に残った 7 日より古いアーカイブの削除

      どちらも systemd の user timer (darwin は launchd の agent) で動き、マシンを
      止めていて逃した回は次の起動時に走る。止めたいマシンは、そのホストの modules
      (dotfiles-private に登録したファイルか、ローカル flake の tmp) で false にする。
    '';
  };

  options.dotfiles.mise = {
    minimumReleaseAge = lib.mkOption {
      type = lib.types.strMatching "[0-9]+d";
      default = "9d";
      example = "14d";
      description = ''
        mise が入れる版の遅延。公開からこれだけ経っていない版は取らない (npm / pnpm の minimumReleaseAge と同じく、
        出たばかりの版を掴まないため)。日の単位 (`<数>d`) だけを受け付ける (下の上書きが終わる日を日で数えるため)。

        nix/scripts/bootstrap-mise.sh が `~/dotfiles/setup --update` のたびに、`~/.config/mise/config.toml` の
        `[settings] minimum_release_age` へ書く (下の releaseAgeOverrides の上書き中は、その上限の日時を書く)。
        claude だけは 1d に縮めて入れる (この値の方が短ければこの値)。

        値は `~/.local/state/dotfiles/mise-release-age.json` (home/modules/mise-release-age.nix) に落ち、
        bootstrap-mise.sh が読む。config.toml は mise が実行時に書き換えるので Nix では置かない。反映は
        `~/dotfiles/setup --update` で、`home-manager switch` だけでは config.toml に届かない。
      '';
    };

    releaseAgeOverrides = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            from = lib.mkOption {
              type = calendarDate;
              example = "2026-10-22";
              description = "上書きを始める日 (Asia/Tokyo)。この日は遅延 0d と同じに新しい版を取る。";
            };
            zeroDays = lib.mkOption {
              type = lib.types.ints.positive;
              default = 1;
              example = 3;
              description = ''
                遅延 0d を続ける日数 (from の日を含む)。取る版の上限は from + zeroDays − 1 の日の終わり。
              '';
            };
            reason = lib.mkOption {
              type = lib.types.str;
              default = "";
              example = "脆弱性の修正版を入れる";
              description = "setup の出力と警告に出す理由。";
            };
          };
        }
      );
      default = [ ];
      example = lib.literalExpression ''
        [
          {
            from = "2026-10-22";
            zeroDays = 3;
            reason = "脆弱性の修正版を入れる";
          }
        ]
      '';
      description = ''
        期間を区切って minimumReleaseAge を緩める上書きの list。項目は「from の日から zeroDays 日 (from の日を含む)
        のうちに出た版まで取る」と読む: その zeroDays 日は遅延 0d と同じに新しい版を取り、その後は取る版の上限を
        据え置いたまま遅延が 1 日ずつ伸び、上限 + minimumReleaseAge を過ぎると上書きが無いときと同じに戻る
        (終わった項目。zeroDays = 3・既定 9d なら、from の 11 日後の終わりで終わる)。

        日付は Asia/Tokyo で読む。今日の日付は Nix の評価では読めないので、終わったかどうかは
        nix/scripts/bootstrap-mise.sh が `~/dotfiles/setup --update` のたびに決める:

        - from が今日より先の項目と、終わった項目は写さない
        - 残った項目のうち上限がいちばん新しいものを `minimum_release_age` に書く
          (`2026-10-24T23:59:59+09:00` の形)。残りが無ければ minimumReleaseAge を書く
        - 上書きのあいだは setup の出力に 1 行出す。入っている tool は上げない (新しい版は `mise up` で入れる)
        - claude も、上限の方が 1d より新しい版を取るあいだは上限で入れる
        - 終わった項目が残っていれば setup の警告のまとめに出す (写さないので害は無い。書いた所から消す)

        登録した全 PC に効かせるなら dotfiles-private の `nix/shared/*.nix` (lib/private-hosts.nix が登録した
        全ホストに足す)、1 台だけならそのホストの modules (dotfiles-private の `nix/hosts/<ホスト>.nix` か、
        ローカル flake の tmp。mkHome の引数ではない) に書く。list は書いた所どうしでつながる。書き方は
        nix/README.md の「遅延 (minimum_release_age) を期間付きで緩める」。
      '';
    };
  };

  options.dotfiles.cursorAgent.enable = lib.mkOption {
    type = lib.types.bool;
    default = false;
    example = true;
    description = ''
      cursor-agent (Cursor の CLI) を mise で入れるか。既定は false で、入れるホストだけ、そのホストの modules
      (dotfiles-private の `nix/hosts/<ホスト>.nix` か、ローカル flake の tmp。mkHome の引数ではない) で true にする。

      - true: nix/scripts/bootstrap-mise.sh が `~/dotfiles/setup --update` のたびに、出てから claude と同じ遅延
        (1d。dotfiles.mise.releaseAgeOverrides の上書き中は上限) を過ぎた一番新しい版を決め、mise の宣言
        `~/.config/mise/conf.d/dotfiles-cursor-agent.toml` に版そのものを書いて入れる (雛形は
        files/mise/conf.d/cursor-agent.toml)。版を指すので、どのディレクトリの素の `mise install` も遅延で落ちない
      - false: 宣言を置かない (setup が前に書いた宣言は消す)。mise は cursor-agent を知らず、素の `mise install` も
        触らない。入っている版は消さず、dotfiles.cleanup.enable のマシンなら週 1 回の掃除の `mise prune` が消す。今すぐ
        消すなら `mise uninstall --all cursor-agent`

      値は `~/.local/state/dotfiles/cursor-agent.json` (home/modules/cursor-agent.nix) に落ち、bootstrap-mise.sh が読む。
      反映は `~/dotfiles/setup --update` で、`home-manager switch` だけでは宣言も版も変わらない。書き方と、on にする行を
      足す順番 (この option を持つ本体が先) は nix/README.md の「`cursor-agent` も mise に置いている理由」。
    '';
  };

  options.dotfiles.ccPages.enable = lib.mkOption {
    type = lib.types.bool;
    default = config.dotfiles.aiTools.enable && config.dotfiles.personalAccounts.enable;
    defaultText = lib.literalExpression "config.dotfiles.aiTools.enable && config.dotfiles.personalAccounts.enable";
    example = false;
    description = ''
      cc-pages (cc-page のページを見せるローカル web ビューア。private な pollenjp/cc-pages) を入れるか。既定は ② と ③ の段が
      両方 on のとき (Claude Code の道具で、private な repo を clone して build するため)。

      true のとき、home/modules/cc-pages.nix が systemd の user service (cc-pages.service) と、port を選んだマシンの
      `~/.config/cc-pages/config.toml` を置き、setup の bootstrap-cc-pages.sh が clone・build して daemon を起こす。false なら
      どちらも置かず、setup は bootstrap-cc-pages を飛ばす (前に build した `~/bin/cc-pages` と clone は消さない)。
    '';
  };

  options.dotfiles.ccPages.port = lib.mkOption {
    # types.port は 0 も通す。0 だと cc-pages は空いている port を選び、返すリンクが合わない
    type = lib.types.nullOr (lib.types.ints.between 1 65535);
    default = null;
    example = 7778;
    description = ''
      cc-pages (cc-page のページを見せるローカル web ビューア。home/modules/cc-pages.nix) が
      待ち受ける port。bind 先は 127.0.0.1 のまま変えない (LAN には出さない)。

      null (既定) なら何も置かず、cc-pages の既定の 7777 で待ち受ける。7777 が
      ほかと衝突するマシンだけ、そのホストの modules (dotfiles-private に登録した
      ファイルか、ローカル flake の tmp) で選ぶ。

      値を入れると home-manager が ~/.config/cc-pages/config.toml に
      `addr = "127.0.0.1:<port>"` を書く。daemon (`cc-pages serve`) も、skill が
      ページを作る `cc-pages new` (返すリンク) も、このファイルを読む。systemd の unit の
      環境変数 (CC_PAGES_ADDR) で渡さないのは、new に届かずリンクが 7777 のまま残るため。

      - 反映は home-manager switch (~/dotfiles/setup --update でもよい)。port が変わると
        switch が cc-pages.service を再起動する
      - config.toml を home-manager が持つので、手で書いた config.toml があると switch が
        「既にファイルがある」で止まる。退けてから switch する
      - port を変える前に作ったページのリンク (http://localhost:<前の port>/…) は開けなくなる。
        ページそのものは残るので、リンクの port を今の値に書き換えれば開ける
      - Claude Code の footer の cc-page のバッジ (home/modules/claude.nix が作る
        ~/.local/state/dotfiles/claude-footer-links.json) も、この port のページだけを拾う。
        settings.json へ写すのは scripts/bootstrap-claude-footer-links.sh (setup --update で走る)
      - status line の先頭の 📄top (cc-pages の会話のトップページへのリンク。~/.claude/statusline-command.sh) も、
        この port の /s/<session_id>/ を指す (home/modules/claude.nix が埋める。switch で変わる)
    '';
  };

  options.dotfiles.ntn.enable = lib.mkOption {
    type = lib.types.bool;
    default = config.dotfiles.personalAccounts.enable;
    defaultText = lib.literalExpression "config.dotfiles.personalAccounts.enable";
    example = false;
    description = ''
      ntn (Notion の CLI。nix/pkgs/ntn) を入れるか。既定は ③ の段 (`personalAccounts.enable`)。

      true のとき home.packages に ntn を入れ、`~/.local/state/dotfiles/ntn.json` (`ntn.keyring`) を置く。false ならどちらも置かず、
      setup は bootstrap-ntn・bootstrap-path-shadow を飛ばす。Windows の ntn は `wsl.windowsFiles.ntn.enable` (既定は同じ ③)。
    '';
  };

  options.dotfiles.ntn.keyring = lib.mkOption {
    type = lib.types.nullOr lib.types.bool;
    default = null;
    example = false;
    description = ''
      ntn (Notion CLI) が `ntn login` の token を OS の keychain に置くか (ntn の config.json の `keyring`)。
      keychain の無い・続かないマシン (SSH で入る Linux の VM など) では `ntn login` が keychain のエラーで
      落ちるので、false にして token を ntn の config directory の `auth.json` に置く。

      - null (既定): config.json に触らない (false から null に戻しても、書いた keyring は残る。
        keychain に戻すなら true)
      - false: config.json に `"keyring": false` を書く (token は config directory の `auth.json`。
        config directory を 700・`auth.json` を 600 にもそろえる)
      - true: config.json に `"keyring": true` を書く (OS の keychain に戻すとき)

      config.json は ntn が自分で書き換える (`ntn login` が既定の workspace を書く) ので、Nix では置かない
      (store の読み取り専用の symlink にすると ntn が書けずに落ちる)。値は `~/.local/state/dotfiles/ntn.json`
      (home/modules/ntn.nix) に落ち、nix/scripts/bootstrap-ntn.sh が `~/dotfiles/setup --update` のたびに
      config.json の `keyring` だけを merge する (無ければ ntn が作るのと同じ形で作る)。反映は
      `~/dotfiles/setup --update` で、`home-manager switch` だけでは config.json に届かない。
      ntn では環境変数 `NOTION_KEYRING` が config.json より強いが、dotfiles はそれを入れない。

      使うマシンのホストの modules (dotfiles-private に登録したファイルか、ローカル flake の tmp。mkHome の
      引数ではない) に書く。書き方は nix/README.md の「ntn (Notion CLI) の token をファイルに置く (keyring)」。
    '';
  };

  options.dotfiles.herdr = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = config.dotfiles.aiTools.enable;
      defaultText = lib.literalExpression "config.dotfiles.aiTools.enable";
      example = false;
      description = ''
        herdr (coding agent 向けの terminal multiplexer) を入れるか。既定は ② の段 (`aiTools.enable`)。

        true のとき入るもの: herdr を包んだ実行ファイルと、ssh 先で forward された agent を固定名で見せる仕組み
        (home/modules/agent-link.nix の pjp-agent-link・`~/.ssh/rc`・見張りの unit。ADR 025)・ssh の `SetEnv PJP_SSH_CLIENT`
        (home/modules/ssh.nix)・`~/.config/herdr/config.toml`・fish と bash の abbr / alias (`h`・`hss`・`hr` など)・Claude Code の
        herdr の skill (`claude.enable` も true のとき)。false ならどれも入れない。Windows の herdr は
        `wsl.windowsFiles.herdr.enable`、herdr-core (hc) は `herdrCore.enable` (どちらも既定は同じ ②)。
      '';
    };

    hub.enable = lib.mkOption {
      type = lib.types.bool;
      default = config.dotfiles.aiTools.enable && config.dotfiles.personalAccounts.enable;
      defaultText = lib.literalExpression "config.dotfiles.aiTools.enable && config.dotfiles.personalAccounts.enable";
      example = false;
      description = ''
        herdr の集約ハブ `~/h` を、setup (bootstrap-herdr-hub.sh) が claude-skills の hub-init.sh で作る (作り済みなら雛形との差だけ
        直す) か。既定は ② と ③ の段が両方 on のとき (② の道具だが、作る hub-init.sh が claude-skills にあるため)。
        `herdr.enable` と `claude.privateSkills.enable` が要る (どちらかが false のマシンで true にすると評価で止まる)。false なら
        setup は bootstrap-herdr-hub を飛ばす (作った `~/h` は消さない)。
      '';
    };
  };

  options.dotfiles.herdrCore.enable = lib.mkOption {
    type = lib.types.bool;
    default = config.dotfiles.aiTools.enable && pkgs.stdenv.hostPlatform.isLinux;
    defaultText = lib.literalExpression "config.dotfiles.aiTools.enable && pkgs.stdenv.hostPlatform.isLinux";
    example = false;
    description = ''
      herdr-core (hc) を入れるか (home/modules/herdr-core.nix)。Linux のホストだけで、既定は ② の段 (`aiTools.enable`) で Linux なら true。

      herdr-app (Windows・macOS の desktop app) が SSH でつなぐ machine は、その machine の herdr-core が terminal を
      持つので、server になりうる Linux のホストには herdr-core が要る。版は Windows の herdr-core と同じ
      (nix/pkgs/herdr-core/releases.json) で、同じ版ならつなぐときに写し直しを聞かれない。

      `herdr-core` と `hc` を home.packages に入れ、`~/.local/bin/herdr-core`・`~/.local/bin/hc` も同じ binary への
      リンクにする (remote の herdr-core の探し先の 2 つ目。非対話の SSH の PATH に nix の profile が入らないホストのため)。
      前に `hc machine add --install` などで写した `~/.local/bin/herdr-core`・`hc` は、リンクに置き換わる。
      store の core は `hc update` が「nix のもの」として断る。このホストへは `hc machine update` を打たず、版は
      releases.json を上げる PR で上げる (nix/README.md の「herdr-core (hc) を Nix で入れる」)。

      入れないホストは、そのホストの modules (dotfiles-private に登録したファイルか、ローカル flake の tmp) で false にする。
    '';
  };

  options.dotfiles.osCaBundle = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      example = false;
      description = ''
        自前の証明書の束を持つツール (nixpkgs の python の certifi・uv・venv の requests・gcloud) にも
        OS の信頼ストア (/etc/ssl/certs/ca-certificates.crt) を読ませる環境変数 (NIX_SSL_CERT_FILE・
        SSL_CERT_FILE・REQUESTS_CA_BUNDLE・CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE) を、session に入れるか
        (home/modules/os-ca-bundle.nix。ADR 028)。入るのは Linux のホストで束があるときだけ (macOS では
        何もしない)。

        false にすると 4 つとも入れない。入れたくないホストだけ、そのホストの modules
        (dotfiles-private に登録したファイルか、ローカル flake の tmp) で false にする。

        反映は `~/dotfiles/setup --update` のあと、新しい login から開いた shell から (反映の前から
        続いている process の下の shell には入らない。nix/README.md の「証明書の束を OS の信頼ストアに寄せる」)。
      '';
    };

    requestsCaBundle.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      example = false;
      description = ''
        `enable = true` のとき、REQUESTS_CA_BUNDLE も入れるか。false にすると、残りの 3 つ
        (NIX_SSL_CERT_FILE・SSL_CERT_FILE・CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE) だけを入れる。
        `enable = false` なら意味を持たない (4 つとも入れない)。

        requests は REQUESTS_CA_BUNDLE を、アプリが Session に置いた verify (私設 CA の束・False) より
        先に使う。Session の verify で自己署名の機器などに繋ぐ script をよく動かすホストは false にする
        (コマンド 1 回だけなら `REQUESTS_CA_BUNDLE= <コマンド>` と空で打てば足りる)。false にすると、
        venv に入れた PyPI の requests は certifi の束を読むまま残る。
      '';
    };
  };

  options.dotfiles.wsl = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        WSL 上で動作しているか。WSL 固有の分岐に使う。

        mkHome の引数で `wsl.enable = true;` のように指定する (dotfiles-private に
        登録したファイルか、ローカル flake の tmp)。
      '';
    };

    windowsUserName = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "alice";
      description = ''
        ホスト側 Windows のユーザー名。`/mnt/c/Users/<名前>/...` の組み立てに使う。
        `wsl.enable = true` のときだけ意味を持つ。

        使うところは 2 つ:

        - `windowsFiles.enable` の配り先 (`/mnt/c/Users/<名前>`)。未設定なら評価時に止まる
        - `onePassword.windowsUserName` の既定値 (1Password の op-ssh-sign のパス)

        Linux 側のユーザー名 (home.username) とは別物なので、マシンごとに
        mkHome の引数で指定する (dotfiles-private に登録したファイルか、ローカル flake の
        tmp)。値は WSL 上で次を実行すると判る:

            pwsh.exe -NoProfile -Command '$env:USERNAME'

        Nix の評価は純粋なのでこのコマンドを評価時に実行して自動取得すること
        はできない (getEnv や --impure は nix flake check を壊す)。
      '';
    };

    windowsFiles.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      example = true;
      description = ''
        repo 直下の `win/` を Windows 側 (`/mnt/c/Users/<windowsUserName>`) へ配るマシンか。
        `wsl.enable = true` と `windowsUserName` が要る (欠けていれば評価時に止まる)。

        switch は Windows 側に触らない。home-manager は配り先を
        `~/.local/state/dotfiles/windows-files.json` に置き、Google 日本語入力の設定を
        組み立てる `pjp-google-ime` を PATH に入れるだけで (home/modules/windows-files.nix)、
        `win/` を読んで /mnt/c へコピーするのは nix/scripts/bootstrap-windows-files.sh、
        Google 日本語入力の設定を組み立てて置くのは nix/scripts/bootstrap-windows-google-ime.sh
        (dotfiles-private の docs/adr/015_win_google_ime_powertoys_*)。`~/dotfiles/setup --update`
        (bootstrap まで走る) で揃う。

        `win/` を home-manager で読まないのは、ローカル flake が本体を
        `path:<repo>/nix` で読むので、その評価から repo 直下が見えないため
        (dotfiles-private の docs/adr/010_win_files_from_wsl_*)。
      '';
    };

    windowsFiles.typeClipboard.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      example = true;
      description = ''
        Windows に type-clipboard (クリップボードの文字を選んだ窓へキー入力として打ち込む自作のアプリ。
        pollenjp/type-clipboard の GitHub の Release の exe) を入れるマシンか。`windowsFiles.enable = true` の
        マシンでだけ使える (false のマシンで true にすると評価時に止まる)。

        switch は Windows 側に触らない。値は `~/.local/state/dotfiles/windows-files.json` の `typeClipboard` に
        落ち、`~/dotfiles/setup --update` で走る nix/scripts/bootstrap-windows-type-clipboard.sh が読む。
        true のマシンでは、配った `Install-TypeClipboard.ps1` (win/type-clipboard/) で、固定した版の exe を
        Release から落とし、SHA-256 が合えば `%LOCALAPPDATA%\Programs\type-clipboard` に置いてスタートメニューに
        出す (入っていなければ入れ、版がずれていれば ⚠ で知らせるだけ)。版と SHA-256 は ps1 で固定する
        (win/README.md の「type-clipboard」)。

        false に戻しても、入れたものは消さない (setup が見なくなるだけ。消し方は win/README.md)。
      '';
    };

    windowsFiles.ntn.enable = lib.mkOption {
      type = lib.types.bool;
      default = config.dotfiles.personalAccounts.enable;
      defaultText = lib.literalExpression "config.dotfiles.personalAccounts.enable";
      example = false;
      description = ''
        Windows に ntn (Notion の CLI。winget の `Notion.ntn`) を、dotfiles が固定した版で入れるマシンか。
        効くのは `windowsFiles.enable = true` のマシンだけ (既定が true なので、配らないマシンでも true のまま。
        そのマシンでは何もしない)。既定は ③ の段 (`personalAccounts.enable`。personal なら true)。

        switch は Windows 側に触らない。値は `~/.local/state/dotfiles/windows-files.json` の `ntn` に落ち、
        `~/dotfiles/setup --update` で走る nix/scripts/bootstrap-windows-ntn.sh が読む。true のマシンでは、配った
        `Install-Ntn.ps1` (win/ntn/) が、入っていなければ入れ、版がずれていれば固定した版に揃えて winget の pin を足す
        (ntn.exe が動いていれば揃えずに ⚠ で知らせる)。版は ps1 の `-Version` の既定値で固定する (win/README.md の「ntn」)。

        false に戻しても、入れたものは消さない (setup が見なくなるだけ。消し方は win/README.md)。
      '';
    };

    windowsFiles.claudeCode.enable = lib.mkOption {
      type = lib.types.bool;
      default = config.dotfiles.aiTools.enable;
      defaultText = lib.literalExpression "config.dotfiles.aiTools.enable";
      example = false;
      description = ''
        Windows に Claude Code (winget の `Anthropic.ClaudeCode`) を、dotfiles が固定した版で入れるマシンか。
        効くのは `windowsFiles.enable = true` のマシンだけ (既定が true なので、配らないマシンでも true のまま。
        そのマシンでは何もしない)。WSL の claude (mise が入れる。`claude.enable`) とは別のもの。既定は ② の段
        (`aiTools.enable`。personal・company なら true)。

        switch は Windows 側に触らない。値は `~/.local/state/dotfiles/windows-files.json` の `claudeCode` に落ち、
        `~/dotfiles/setup --update` で走る nix/scripts/bootstrap-windows-claude-code.sh が読む。true のマシンでは、配った
        `Install-ClaudeCode.ps1` (win/claude-code/) が、入っていなければ入れ、版がずれていれば固定した版に揃えて winget の pin を
        足す (Windows の Claude Code が動いていれば揃えずに ⚠ で知らせる)。版は ps1 の `-Version` の既定値で固定し、
        `CLAUDE_CODE_PACKAGE_MANAGER_AUTO_UPDATE` は設定しない (win/README.md の「Claude Code」)。Claude Code の設定
        (`%USERPROFILE%\.claude`) とログインには触らない。

        false に戻しても、入れたものは消さない (setup が見なくなるだけ。消し方は win/README.md)。
      '';
    };

    windowsFiles.claudeAccounts.enable = lib.mkOption {
      type = lib.types.bool;
      default = config.dotfiles.aiTools.enable && config.dotfiles.personalAccounts.enable;
      defaultText = lib.literalExpression "config.dotfiles.aiTools.enable && config.dotfiles.personalAccounts.enable";
      example = false;
      description = ''
        Windows の claude-personal・claude-work (ログインだけを分けて Windows の Claude Code を起こすコマンド。Linux の
        `claude-<名前>` と同じ考え) を、Windows の runner が用意するマシンか。runner の手順 `claude-accounts` が
        `%USERPROFILE%\.claude-<名前>` と `claude-<名前>.exe` を置き、その置き場をユーザーの PATH に足す (win/README.md の
        「claude-personal・claude-work」)。効くのは Windows の Claude Code を入れるマシン (`windowsFiles.claudeCode.enable`) だけ。

        settings.json と CLAUDE.md をファイルの symlink で `~/.claude` と共有するので、初回の apply で UAC の確認が 1 回出る。
        そのため既定は ② と ③ の段が両方 on のとき (personal だけ true) で、会社や客先の PC (company・client) では既定で
        走らせない。

        WSL の setup はこの switch を読まない (Windows にしか無い手順)。値は `~/.local/state/dotfiles/group.json` の
        `tools.windowsClaudeAccounts` と、Windows の runner が読むグループの既定 (win/runner/groups.json) に落ちる。Windows の runner
        では、ホストの値 (dotfiles-private の `win/hosts/*.toml`) の `[tools]` に `windowsClaudeAccounts = true` (か false) を書く。

        false に戻しても、作った `~/.claude-<名前>` とコマンドは消さない (runner が見なくなるだけ。片付け方は win/README.md)。
      '';
    };

    windowsFiles.herdr.enable = lib.mkOption {
      type = lib.types.bool;
      default = config.dotfiles.aiTools.enable;
      defaultText = lib.literalExpression "config.dotfiles.aiTools.enable";
      example = false;
      description = ''
        Windows に herdr (winget の `Herdr.Herdr`) と herdr-app・herdr-core を、dotfiles が固定した版で入れるマシンか。
        効くのは `windowsFiles.enable = true` のマシンだけ (配らないマシンでは true でも何もしない)。既定は ② の段
        (`aiTools.enable`。personal・company なら true)。WSL の herdr (`herdr.enable`) とは別のもの。

        switch は Windows 側に触らない。値は `~/.local/state/dotfiles/group.json` の `tools.windowsHerdr` に落ち (home/modules/group.nix。
        `windows-files.json` には入れない)、`~/dotfiles/setup --update` は false なら bootstrap-windows-herdr.sh・
        bootstrap-windows-herdr-app.sh を飛ばす (script の冒頭の `# tool: windowsHerdr`)。bootstrap-windows-pin-updates.sh も、false なら
        herdr・herdr-app・herdr-core の新しい版を確かめない。group.json が無い前の世代では、今までどおり入れる。

        false に戻しても、入れたものは消さない (setup が見なくなるだけ。消し方は win/README.md)。
      '';
    };

    windowsFiles.tailscale.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      example = true;
      description = ''
        Windows に Tailscale (winget の `Tailscale.Tailscale`。machine スコープの MSI) を、dotfiles が固定した版で入れるマシンか。
        効くのは `windowsFiles.enable = true` のマシンだけ (配らないマシンでは true でも何もしない)。tailnet にログインして使う
        VPN の道具で、会社の PC などに勝手に入れないよう、どのグループでも既定は false (③ の段に置くが、段からは決めない。
        入れるホストが true を書く)。

        switch は Windows 側に触らない。値は `~/.local/state/dotfiles/group.json` の `tools.windowsTailscale` に落ち
        (home/modules/group.nix。`windows-files.json` には入れない)、`~/dotfiles/setup --update` は false なら
        bootstrap-windows-tailscale.sh を飛ばす (script の冒頭の `# tool: windowsTailscale`。group.json やその欄が無い前の世代でも、
        script が入れないマシンとして飛ばす)。true のマシンでは、配った `Install-Tailscale.ps1` (win/tailscale/) が、入っていなければ
        固定した版を入れて winget の pin を足す (UAC の確認が出る)。入っていれば上げない (Tailscale が自分で上がる。入っている版の方が
        新しくても下げない)。版は ps1 の `-Version` の既定値で固定する (win/README.md の「Tailscale」)。bootstrap-windows-pin-updates.sh も、
        true のときだけ Tailscale の新しい版を確かめる。tailnet へのログインには触らない (入れた後に手でする)。

        Windows の runner では、ホストの値 (dotfiles-private の `win/hosts/*.toml`) の `[tools]` に `windowsTailscale = true` を書く。

        false に戻しても、入れたものは消さない (setup が見なくなるだけ。消し方は win/README.md)。
      '';
    };

    windowsFiles.sshd.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      example = true;
      description = ''
        Windows に sshd (OpenSSH Server) を入れ、Tailscale (tailnet) と localhost からだけ、鍵でだけ SSH で入れるようにするマシンか。
        iPhone の Herdr のアプリや hc が、Windows の herdr-core に SSH でつなぐのに使う。効くのは `windowsFiles.enable = true` の
        マシンだけ (配らないマシンでは true でも何もしない)。PC に外から入る口を開けるので、会社の PC などに勝手に入れないよう、
        どのグループでも既定は false (③ の段に置くが、段からは決めない。入れるホストが true を書く)。入る経路の Tailscale も
        入れるホスト (`windowsFiles.tailscale.enable`) で使う。

        switch は Windows 側に触らない。値は `~/.local/state/dotfiles/group.json` の `tools.windowsSshd` に落ち (home/modules/group.nix)、
        `~/dotfiles/setup --update` は false なら bootstrap-windows-sshd.sh を飛ばす (script の冒頭の `# tool: windowsSshd`)。true の
        マシンでは、配った `Install-Sshd.ps1` (win/openssh/) が、dotfiles が winget で固定した OpenSSH (`Install-OpenSSH.ps1` が入れる
        `C:\Program Files\OpenSSH`) に server を足して入れ、sshd の設定 (鍵だけ・AllowUsers と Match Address で tailnet と localhost に限る)・Windows Firewall の
        拒否の規則・自動起動を揃える (入っていないときだけ setup が入れる。UAC の確認が出る。ずれていれば ⚠ で知らせ、揃えはしない)。
        Windows の機能 (System32) の OpenSSH Server とは二重にしない (win/README.md の「sshd」)。

        Windows の runner では、ホストの値 (dotfiles-private の `win/hosts/*.toml`) の `[tools]` に `windowsSshd = true` を書く。

        false に戻しても、入れたものは消さない (setup が見なくなるだけ。止め方・消し方は win/README.md)。
      '';
    };

    windowsFiles.sshd.authorizedKeys = lib.mkOption {
      type = lib.types.nullOr (lib.types.listOf lib.types.str);
      default = null;
      example = lib.literalExpression ''
        [ "from=\"100.64.0.1,fd7a:115c:a1e0::1\" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... phone (Herdr)" ]
      '';
      description = ''
        `windowsFiles.sshd.enable` の sshd に入れる公開鍵。authorized_keys の 1 行を 1 つの文字列で書く (先頭に `from="<端末の
        Tailscale の IP>"` を付けると、鍵が漏れてもその端末からしか使えない)。Windows のユーザーは管理者なので、sshd は
        `C:\ProgramData\ssh\administrators_authorized_keys` を読む。

        null (既定) なら dotfiles は鍵を置かない (そのファイルが無ければ空で作り、権限だけ揃える。中身は手で置く)。list なら、
        bootstrap-windows-sshd.sh が Windows の `%LOCALAPPDATA%\dotfiles\sshd\authorized_keys` へ写しを置き、`Install-Sshd.ps1` が
        その写しどおりに administrators_authorized_keys を書く (写しに無い鍵は消す。空の list なら鍵は 0 本で、誰も入れない)。
        値は `~/.local/state/dotfiles/windows-sshd.json` の `authorizedKeys` に落ちる (home/modules/windows-files.nix)。

        公開鍵と、from= に書く端末の IP は public な dotfiles には書かず、dotfiles-private のホストの値に書く (端末の足し引きが PR に
        残る)。1 行に改行は入れられない (評価で止まる)。
      '';
    };

    exeExecTrace.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      example = true;
      description = ''
        WSL から起動された Windows の .exe (ssh.exe など) を、起動元の祖先付きで常時記録するか。
        `wsl.enable = true` のときだけ使える (false のマシンで true にすると評価時に止まる)。

        1Password の承認ダイアログは要求元を「Windows Terminal」としか出さず、承認した後は
        同じタブのどのプロセスもダイアログ無しで鍵を使える。要求元が分かるのは Linux 側で
        .exe の起動を見たときだけなので、eBPF のトレーサ (pkgs/pjp-exe-exec-trace) を systemd の
        system の unit で動かす (ADR 012)。

        true のとき home/modules/exe-exec-trace.nix が次を置く:

        - unit ファイル `~/.local/share/dotfiles/systemd/dotfiles-exe-exec-trace.service`。
          ExecStart は store の固定パス
        - PATH の `pjp-exe-exec-trace` (記録を読む `--pretty` 用)

        eBPF には root が要るので、switch だけでは動かない。unit を /etc/systemd/system へ
        入れるのは setup の手順 exe-exec-trace (中で sudo を呼ぶ) で、`~/dotfiles/setup --update`
        の最後に走る。トレーサを更新したときも --update で入れ替わる (sudo がパスワードを
        訊けずに飛ばしたら、setup の最後に知らせる)。false に戻して --update を打つと、
        入っている unit を止めて消す。

        記録は journald に残る:

            journalctl -u dotfiles-exe-exec-trace -o cat | pjp-exe-exec-trace --pretty

        承認ダイアログが出ている間に要求元をたどる `pjp-who-is-asking` は、この option に
        よらず `wsl.enable` のマシンの PATH に入る (root が要らないため)。
      '';
    };

    mtuGuard = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        example = true;
        description = ''
          WSL の eth0 の MTU が上限 (`maxMtu`) を超えるたびに、上限まで下げる見張りを置くか。
          `wsl.enable = true` のときだけ使える (false のマシンで true にすると評価時に止まる)。

          VPN のトンネルの実効 MTU が eth0 の MTU より小さく、トンネルの奥から返る ICMP
          (Fragmentation Needed) が WSL (NAT) まで届かないと、実効 MTU を超える大きさのパケットが
          黙って捨てられ続ける (PMTU ブラックホール)。小さい通信は通るので、つながっているのに大きな
          送信 (Claude Code の API のリクエストなど) だけが止まる。WSL はホスト側のネットワークが
          変わるたびに (VPN の接続・切断など) eth0 の MTU を設定し直すので、`/etc/wsl.conf` の
          boot command のように起動時に 1 回下げるだけでは足りない。

          true のとき home/modules/wsl-mtu-guard.nix が unit ファイル
          `~/.local/share/dotfiles/systemd/dotfiles-wsl-mtu-guard.service` を生成する。ExecStart は
          store の固定パスの見張り (pkgs/pjp-wsl-mtu-guard) で、起動したときに 1 回と、eth0 のリンクの
          変化のたびに下げる。上げはしないので、VPN を使っていないときも上限のまま (パケットが少し
          小さくなるだけ)。

          MTU を変えるには root が要るので、switch だけでは動かない。unit を /etc/systemd/system へ
          入れるのは setup の手順 wsl-mtu-guard (中で sudo を呼ぶ) で、`~/dotfiles/setup --update` で走る
          (sudo がパスワードを訊けずに飛ばしたら、setup の最後に知らせる)。false に戻して --update を
          打つと、入っている unit を止めて消す。

          下げた記録は journald に残る:

              journalctl -u dotfiles-wsl-mtu-guard
        '';
      };

      maxMtu = lib.mkOption {
        type = lib.types.ints.between 1280 1500;
        default = 1350;
        example = 1300;
        description = ''
          見張りが保つ eth0 の MTU の上限。`mtuGuard.enable = true` のときだけ意味を持つ。
          下限は IPv6 の最小の MTU (1280)。

          既定の 1350 は、実効 MTU が 1382 のトンネルで測った上限に 32 バイトの余裕を持たせた値。
          トンネルの実効 MTU がもっと小さい回線では下げる。値を変えて `~/dotfiles/setup --update` を
          打つと、setup の手順が unit を入れ替えて起こし直す。見張りは上げないので、上げたときは
          `sudo ip link set dev eth0 mtu <値>` も打つ。
        '';
      };
    };

    # enable は dotfiles.onePassword.enable へ出した (上の imports の改名)。
    onePassword = {
      windowsUserName = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = config.dotfiles.wsl.windowsUserName;
        defaultText = lib.literalExpression "config.dotfiles.wsl.windowsUserName";
        example = "alice";
        description = ''
          1Password の op-ssh-sign のパス (`/mnt/c/Users/<名前>/AppData/...`) に使う
          Windows ユーザー名。WSL で `onePassword.enable = true` のときだけ必要
          (未設定なら評価時に止まる)。

          既定は `dotfiles.wsl.windowsUserName`。ふつうはそちらに書けばよく、
          ここに書くのは 1Password だけ別の名前を指したいときに限る
          (書けばこちらが勝つ)。
        '';
      };
    };
  };
}
