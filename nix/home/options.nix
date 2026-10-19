# このリポジトリ独自のオプション定義。
#
# 有効な組み合わせが構造に出るよう、WSL 固有の設定は dotfiles.wsl 配下へ入れ子にしている。
#
#   dotfiles.onePassword.enable                  1Password を使うか (WSL ならホスト側 Windows の、それ以外はこのマシンの)
#   dotfiles.wsl.enable                          WSL か
#   dotfiles.wsl.windowsUserName                 ホスト側 Windows のユーザー名 (/mnt/c/Users/<名前>)
#   dotfiles.wsl.windowsFiles.enable             repo 直下の win/ を Windows 側へ配るか
#   dotfiles.wsl.onePassword.windowsUserName     WSL で 1Password のパスに要る Windows ユーザー名 (既定は上の windowsUserName)
#   dotfiles.wsl.exeExecTrace.enable             WSL から起動された .exe を祖先付きで常時記録するか (ADR 012)
#   dotfiles.claude.devTracker.enable            Notion Dev Tracker (pjp-dev-tracker) を使うマシンか
#   dotfiles.claude.gitViaGh.enable              Claude の git・fetch 系の abbr / alias・setup の取得を gh の資格情報 (HTTPS) で GitHub へ通すか
#   dotfiles.claude.notion.profile               Notion へ書く skill が既定に使う宛先のプロファイル名
#   dotfiles.claude.notion.routes                作業中の repo から宛先のプロファイルを決める、このマシンだけの規則
#   dotfiles.claude.notion.override              プロファイルの値をこのマシンだけ差し替える
#   dotfiles.claude.videoOffer.autoStart.enable  設計・PR のときに解説動画の短尺を答えを待たずに作り始めるか (既定 false: 先に聞く)
#   dotfiles.cleanup.enable                      使わなくなった Nix の store path・世代と mise の版を週 1 回消すか
#   dotfiles.ccPages.port                        cc-pages のビューアが待ち受ける port (null なら cc-pages の既定の 7777)
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

  options.dotfiles.claude = {
    devTracker.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      example = false;
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

        ローカル flake の雛形 (scripts/setup-local-flake.sh) は false を書いて
        いるので、`~/dotfiles` 経由のマシンは使うところだけ true にする。
        登録簿 (hosts/default.nix) のホストを直接指すときはこの既定 (true)。
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
          (黙って別の workspace へ書かないため)。ローカル flake の雛形も null を書く。

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
        使うので、既定は聞く方にしている (docs/adr/023_claude_video_offer_host_option_*)。

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
        通らないので bootstrap は要らない。作り始める方にしたいマシンはローカル flake の
        local で true にする。
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
      止めていて逃した回は次の起動時に走る。止めたいマシンはローカル flake の
      local で false にする。
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
      ほかと衝突するマシンだけ、ローカル flake の local で選ぶ。

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
    '';
  };

  options.dotfiles.wsl = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        WSL 上で動作しているか。WSL 固有の分岐に使う。

        hosts/default.nix では `wsl.enable = true;` のように指定する。
      '';
    };

    windowsUserName = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "polle";
      description = ''
        ホスト側 Windows のユーザー名。`/mnt/c/Users/<名前>/...` の組み立てに使う。
        `wsl.enable = true` のときだけ意味を持つ。

        使うところは 2 つ:

        - `windowsFiles.enable` の配り先 (`/mnt/c/Users/<名前>`)。未設定なら評価時に止まる
        - `onePassword.windowsUserName` の既定値 (1Password の op-ssh-sign のパス)

        Linux 側のユーザー名 (home.username) とは別物なので、マシンごとに
        hosts/default.nix で指定する。値は WSL 上で次を実行すると判る:

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
        (docs/adr/015_win_google_ime_powertoys_*)。`~/dotfiles/setup --update`
        (bootstrap まで走る) で揃う。

        `win/` を home-manager で読まないのは、ローカル flake が本体を
        `path:<repo>/nix` で読むので、その評価から repo 直下が見えないため
        (docs/adr/010_win_files_from_wsl_*)。
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

    # enable は dotfiles.onePassword.enable へ出した (上の imports の改名)。
    onePassword = {
      windowsUserName = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = config.dotfiles.wsl.windowsUserName;
        defaultText = lib.literalExpression "config.dotfiles.wsl.windowsUserName";
        example = "polle";
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
