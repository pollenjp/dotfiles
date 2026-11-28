# 設定グループ (道具の集合) と、道具の表 (dotfiles-private の docs/adr/109_host_groups_minimum_all_*。前の段の組は ADR 057)。
#
# ホストは設定グループを 1 つ選び (dotfiles.group。mkHome の group)、グループに入る道具は全部既定で on、入らない道具は既定で off に
# なる。グループはカテゴリのラベルでなく、道具の集合。2 つで、minimum ⊂ all:
#
#   minimum   どの PC にも初めからあってほしいもの。switch の無い基本の道具 (下の base。常に入る) と、minimum = true の道具の switch
#             (証明書の束・掃除)。グループを書かないホストもこれ。ほとんどのホストは minimum にして、使う道具をホストのファイルで足す
#   all       道具を全部 (minimum の全部と、ほかの道具の switch の全部)
#
# 道具の既定は「グループに入る && そのマシンで効く」。効くかは 2 つで決まる:
#
#   env       環境の条件 (下の envs の名前)。そのマシンの事実 (WSL か・win/ を配るか・Linux か) で、グループでは決めない。合わなければ
#             グループに入っていても既定で off にする (評価で止めない。assertion は、ホストが素の値で書いた誤りのためにだけ残る)
#   requires  効く条件。ほかの道具の switch (option の path)。どれかが false なら値によらず効かない (既定も off)
#
# ここは表 (data) だけを持つ。option の既定は home/options.nix に素の式で書く (`config.dotfiles.group == "all" && <env> && <requires>`。
# options.nix を読めば既定が分かり、dotfiles-private の hostmap の読み手もたどれる形。ADR 057 §4 で表から既定を作る形を退けたわけと同じ)。
# 表と既定が合っていることは tests/groups.nix (flake の checks の groups-state) が、環境の組 5 つと 2 つのグループで確かめる。
# 道具の switch を足すときは、ここと options.nix の両方を直し、minimum に入れるかを決める (all には必ず入る)。
#
# 表を読むもの: home/modules/group.nix (~/.local/state/dotfiles/group.json。setup が読んで手順を飛ばす)・lib/host-summary/ (ホストの
# 要約と nix/groups.md)・flake.nix の lib.windowsGroups (win/runner/groups.json)・tests/groups.nix・tests/group-minimum.nix。
#
#   groups         グループ。並びは既定の minimum から
#   removedGroups  やめたグループの名前 (ADR 057 の 3 つ) → 前のグループと同じ道具にするために足す道具の説明。書いたホストは評価で止める
#   envs           環境の条件の名前 → 要約と nix/groups.md に出す名前 (label)・何で決まるか (doc)・合わないときの文 (off)
#   base           switch の無い基本の道具 (常に入る。minimum の中)。要約の図と nix/groups.md に出すだけ
#   tools          道具の switch。並びは前の表 (ADR 057) の順 (段の印は出さない)
#     key       group.json の tools のキーと、setup が読む bootstrap の見出し (# tool: <key>) の名前
#     option    dotfiles からの path (bool の option)
#     minimum   minimum に入るか (all には必ず入る)
#     env       環境の条件 (envs の名前)
#     requires  効く条件 (ほかの道具の option の path)
#     follows   既定がグループでなく、ほかの道具 (key) の値に従う (linger は herdrCore に従う。ADR 101)。従う先の値が既定になる
#     short     ホストの要約の図の箱に出す短い名前 (下の shorts。無ければ label)
#     runner    Windows の runner (win/runner/) が手順の gate で読む道具か (下の runnerTools)
#     runnerRequires  Windows の runner の側だけの依存 (runner の道具の key → わけ)。この道具が on なのに、ここに並べた道具が off なら、runner は
#               ホストの値を読むときに止める (終了コード 2)。Nix の requires (option の既定を決める) とは別に持つ: 同じ key でも OS で
#               意味が違う道具があり (herdrHub は Windows では herdr-app のハブ、Linux では旧 herdr のハブ)、Linux の既定を変えないため
#   runnerOnlyTools  Windows の runner だけが読む道具 (Nix の option が無く、group.json にも入らない。privateRepos。下の runnerOnlyTools)
#   runnerDeps     runner の止める条件の表 (runner の道具の key → 要る道具の key → わけ)。runnerRequires と runnerOnlyTools の requiredBy を
#                  合わせたもの。flake の lib.windowsGroups (groups.json の requires・requiresWhy) と lib/host-summary/ が読む
#   skills         skill の依存 (skill の名前 → OS ごとに要る道具の key。下の skills)
let
  groups = [
    {
      name = "minimum";
      label = "最低限";
      description = "どの PC にも初めからあってほしいもの (基本の道具と、証明書の束・掃除)。ほとんどのホストはこれにして、使う道具をホストのファイルで足す (グループを書かないホストもこれ)";
    }
    {
      name = "all";
      label = "全部";
      description = "道具を全部入れる (minimum の全部と、ほかの道具の switch の全部)。環境が合わない道具 (WSL だけ・win/ を配るマシンだけ・Linux だけなど) は、そのマシンでは入らない。道具の前提 (1Password の署名の鍵・Windows の側の SSH の中継・Notion の宛先など) もそろう PC で選ぶ (README の「設定グループ」)";
    }
  ];

  groupNames = map (g: g.name) groups;

  # 前のグループ (ADR 057) と同じ道具にするために足す道具。書き方は nix/README.md の「設定グループ」の「前のグループから移す」
  removedGroups = {
    personal = "前の personal と同じにするなら Claude Code・herdr・herdr-core・claude-skills・cc-pages・~/h・ntn・git の名前とメール (win/ を配るマシンは Windows の Claude Code・herdr・claude アカウント・Claude Desktop・ntn も)";
    company = "前の company と同じにするなら Claude Code・herdr・herdr-core (win/ を配るマシンは Windows の Claude Code・herdr も) と、ホストで足していた道具";
    client = "前の client と同じにするなら、ホストで足していた道具だけ";
  };

  envs = {
    linux = {
      label = "Linux";
      doc = "Linux (macOS でない)";
      off = "Linux でない";
    };
    wsl = {
      label = "WSL";
      doc = "`wsl.enable`";
      off = "WSL でない";
    };
    windowsFiles = {
      label = "win/ を配る";
      doc = "`wsl.windowsFiles.enable`";
      off = "win/ を配らない";
    };
    noWindowsFiles = {
      label = "win/ を配らない (Windows は runner)";
      doc = "`wsl.windowsFiles.enable` が false";
      off = "win/ を配る (Windows は WSL の setup)";
    };
    windowsUser = {
      label = "Windows のユーザー名がある (WSL)";
      doc = "WSL なら `wsl.onePassword.windowsUserName` (既定は `wsl.windowsUserName`) が null でない (WSL でなければいつも)";
      off = "Windows のユーザー名が無い";
    };
  };

  tool =
    key: label: option: extra:
    {
      inherit key label option;
      minimum = false;
      env = [ ];
      requires = [ ];
      follows = null;
      short = shorts.${key} or label;
      runner = builtins.elem key runnerTools;
      runnerRequires = { };
    }
    // extra;

  # ホストの要約の図 (lib/host-summary/ の HTML) の箱に出す短い名前。箱の幅に収まる長さにし、label (表とポップアップに出す) と
  # 同じ道具だと分かる名前にする
  shorts = {
    windowsTypeClipboard = "Win の type-clipboard";
    exeExecTrace = ".exe の起動の記録";
    mtuGuard = "MTU の見張り";
    osCaBundle = "証明書の束 (OS)";
    cleanup = "store・mise の掃除";
    claude = "Claude Code";
    herdrCore = "herdr-core (hc)";
    linger = "systemd の linger";
    windowsClaudeCode = "Win の Claude Code";
    windowsHerdr = "Win の herdr";
    t3Code = "T3 Code";
    windowsT3Code = "Win の T3 Code";
    claudePrivateSkills = "private な skill";
    herdrHub = "集約ハブ ~/h";
    windowsClaudeAccounts = "Win の claude アカウント";
    windowsClaudeDesktop = "Win の Claude Desktop";
    devTracker = "Dev Tracker";
    devTrackerInbox = "Dev Tracker の見回り";
    onePassword = "1Password";
    opReasonSshRelay = "SSH の中継";
    ntn = "ntn";
    windowsNtn = "Win の ntn";
    codex = "Codex CLI";
    windowsCodex = "Win の Codex CLI";
    windowsOpenssh = "Win の OpenSSH";
    windowsTailscale = "Win の Tailscale";
    windowsSshd = "Win の sshd";
    gitIdentity = "git の名前とメール";
  };

  # Windows の runner が手順の gate で読む道具 (win/README.md の「ホストの値」の一覧と同じ)。ホストの要約は、dotfiles-private の
  # win/hosts/*.toml (Windows のホストの値) のページに、この道具だけを箱にして出す。runner に道具を足したら、ここにも足す。
  # 表 (tools) の道具 (runner の印) と、下の runnerOnlyTools の道具 (Nix の option が無い) の両方を並べる
  runnerTools = [
    "windowsClaudeCode"
    "windowsHerdr"
    "windowsT3Code"
    "claudePrivateSkills"
    "herdrHub"
    "windowsClaudeAccounts"
    "windowsClaudeDesktop"
    "devTracker"
    "onePassword"
    "opReasonSshRelay"
    "windowsNtn"
    "windowsCodex"
    "windowsOpenssh"
    "windowsTailscale"
    "windowsSshd"
    "windowsTypeClipboard"
    "gitIdentity"
    "privateRepos"
  ];

  # Windows の runner だけが読む道具 (dotfiles-private の docs/adr/111_win_runner_without_gh_*)。Nix の option を持たず、group.json にも
  # 入らない (Linux の setup は読まない。Linux で private な repo を読めない PC は、ローカルの flake で扱う)。runner の groups.json (flake の
  # lib.windowsGroups) と、ホストの要約の Windows のホストのページにだけ出る
  #   key         groups.json の tools のキーと、ホストの値 (win/hosts/*.toml) の [tools] の名前
  #   minimum     minimum に入るか (all には必ず入る)
  #   requiredBy  この道具が off なのに on にできない道具 (runner の道具の key → わけ)。runner はホストの値を読むときに止め (終了コード 2)、
  #               ホストの要約は評価で止める。わけは runner の止める文に出す
  runnerOnlyTools = [
    {
      key = "privateRepos";
      label = "pollenjp の private な repo と gh のログイン (Windows)";
      short = "private な repo と gh";
      minimum = false;
      # 集約ハブ (herdrHub) は要らない: ハブと子の道具・mod pjp-spaces・土台の skill は公開の dotfiles にある (dotfiles-private の ADR 124)
      requiredBy = {
        claudePrivateSkills = "claude-skills の clone を読む";
        opReasonSshRelay = "中継のファイルを置く手順 ssh-config が dotfiles-private の ssh/ を読む";
      };
    }
  ];

  # runner の止める条件の表 (runner の道具の key → 要る道具の key → わけ)。tools の runnerRequires と、runnerOnlyTools の requiredBy を
  # 合わせる。どちらも書いた組は無い (tests/groups.nix が、key が全部 runnerTools にあることを見る)
  runnerDeps = builtins.zipAttrsWith (_: builtins.foldl' (a: b: a // b) { }) (
    map (t: { ${t.key} = t.runnerRequires; }) (builtins.filter (t: t.runnerRequires != { }) tools)
    ++ builtins.concatMap (
      r:
      map (k: {
        ${k} = {
          ${r.key} = r.requiredBy.${k};
        };
      }) (builtins.attrNames r.requiredBy)
    ) runnerOnlyTools
  );

  # skill の依存 (dotfiles-private の ADR 124)。skill の名前 → OS ごとに要る道具の key の並び。要る道具のどれかが off のホストでは、その
  # skill を Claude Code の一覧に出さない (表に無い skill は、いつも出す)。Windows は runner の道具の key (ホストの値の [tools] と groups.json の
  # 既定で引く。runner の手順 claude-files が読む)、Linux は表 (tools) の道具の key (option の path で引く。home/modules/claude.nix が
  # linuxSkillOn で読む)。同じ key でも OS で意味が違う道具 (herdrHub) があるので、OS ごとに書く。SKILL.md の frontmatter には書かない
  # (表を 1 つに保つ。Nix は YAML を読めない)。key が表にあることと、skill が nix/files/claude/skills/ にあることは tests/groups.nix が見る
  #
  # ハブと子の土台の skill は、Windows では集約ハブ (herdrHub。herdr-app のハブ) のホスト、Linux では hc が入るホスト (herdrCore。子が
  # 動く所と Linux のハブ) に出す
  skills =
    let
      hubAndChild = {
        windows = [ "herdrHub" ];
        linux = [ "herdrCore" ];
      };
    in
    {
      pjp-hc-child = hubAndChild;
      pjp-hc-hub = hubAndChild;
      pjp-hc-hub-panel = hubAndChild;
    };

  # switch の無い基本の道具 (今の module が常に入れるもの。minimum の中)。外したいホストが出たら、そのとき switch を足して tools に移す
  base = [
    {
      key = "shell";
      label = "shell (fish・bash)";
      short = "fish・bash";
    }
    {
      key = "starship";
      label = "starship (prompt)";
      short = "starship";
    }
    {
      key = "git";
      label = "git";
      short = "git";
    }
    {
      key = "ssh";
      label = "ssh";
      short = "ssh";
    }
    {
      key = "vim";
      label = "vim と neovim";
      short = "vim・neovim";
    }
    {
      key = "tmux";
      label = "tmux と zellij";
      short = "tmux・zellij";
    }
    {
      key = "cli";
      label = "CLI (rg・fd・jq・fzf・gh・ghq など)";
      short = "CLI (rg・fzf・gh…)";
    }
    {
      key = "mise";
      label = "mise";
      short = "mise";
    }
    {
      key = "direnv";
      label = "direnv";
      short = "direnv";
    }
    {
      key = "python";
      label = "python";
      short = "python";
    }
  ];

  windowsFilesTool =
    key: label: name: extra:
    tool key label [ "wsl" "windowsFiles" name "enable" ] ({ env = [ "windowsFiles" ]; } // extra);

  tools = [
    # WSL だけの道具 (WSL でないマシンでは、all でも既定で off)
    (tool "exeExecTrace" ".exe の起動の記録 (WSL)" [ "wsl" "exeExecTrace" "enable" ] { env = [ "wsl" ]; })
    (tool "mtuGuard" "eth0 の MTU の見張り (WSL)" [ "wsl" "mtuGuard" "enable" ] { env = [ "wsl" ]; })
    # minimum の道具 (どのグループでも既定で on)
    (tool "osCaBundle" "証明書の束を OS の信頼ストアに寄せる" [ "osCaBundle" "enable" ] { minimum = true; })
    (tool "cleanup" "使わない store path・mise の版の掃除" [ "cleanup" "enable" ] { minimum = true; })

    (tool "claude" "Claude Code 一式" [ "claude" "enable" ] { })
    (tool "herdr" "herdr" [ "herdr" "enable" ] { })
    # herdr-core の公式の配布物は Linux 版だけ (macOS は herdr-app が入れる)
    (tool "herdrCore" "herdr-core (hc)" [ "herdrCore" "enable" ] { env = [ "linux" ]; })
    # systemd の linger (setup の手順 linger が sudo loginctl enable-linger で有効にする)。herdr-core の server (user の service) を
    # ログアウトで止めないための道具なので、既定は herdrCore.enable に従う (ホストが herdrCore を足せば付いてくる。グループからは
    # on にならない。dotfiles-private の docs/adr/101_linger_with_herdr_core_* と ADR 109)
    (tool "linger" "systemd の linger (ログアウトしても user の service を止めない)" [ "linger" "enable" ] {
      env = [ "linux" ];
      follows = "herdrCore";
    })
    (windowsFilesTool "windowsClaudeCode" "Windows の Claude Code" "claudeCode" { })
    (windowsFilesTool "windowsHerdr" "Windows の herdr・herdr-app" "herdr" { })
    (tool "cursorAgent" "cursor-agent" [ "cursorAgent" "enable" ] { })
    # T3 Code (CLI と常駐の service・設定)。公式の配布物は Linux 版だけ。claude のアカウント t3 と Claude の設定を前提にするので、
    # claude が off なら効かない
    (tool "t3Code" "T3 Code (t3 と t3code.service)" [ "t3Code" "enable" ] {
      env = [ "linux" ];
      requires = [
        [
          "claude"
          "enable"
        ]
      ];
    })
    # Windows の T3 Code (desktop app と設定)。Windows の runner の手順 t3-code・t3-code-settings だけが読む switch (WSL の setup に同じ
    # 手順は無い)
    (windowsFilesTool "windowsT3Code" "Windows の T3 Code" "t3Code" { })
    (tool "claudePrivateSkills" "private な skill (claude-skills の clone)" [
      "claude"
      "privateSkills"
      "enable"
    ] { })
    (tool "ccPages" "cc-pages" [ "ccPages" "enable" ] { })
    # Windows の集約ハブ (herdr-app のハブ) は、mod pjp-spaces と hc を入れる herdr-app と、ハブの会話の Claude Code (土台の skill を置く
    # 手順 claude-files も) が要る。runner の側だけの依存にする (Linux の herdr.hub.enable は旧 herdr のハブで、要るものが違う。依存は
    # home/modules/group.nix の assertion)
    (tool "herdrHub" "集約ハブ ~/h" [ "herdr" "hub" "enable" ] {
      runnerRequires = {
        windowsClaudeCode = "ハブの会話の Claude Code と、土台の skill を置く手順 claude-files";
        windowsHerdr = "mod pjp-spaces と hc を入れる herdr-app";
      };
    })
    # 初回の apply で UAC の確認 (管理者の権限) が出る手順。Windows の runner の手順 claude-accounts だけが読む switch (WSL の setup に
    # 同じ手順は無い)。Windows の Claude Code を入れるマシンでだけ効く
    (windowsFilesTool "windowsClaudeAccounts" "Windows の claude-personal・claude-work" "claudeAccounts" {
      requires = [
        [
          "wsl"
          "windowsFiles"
          "claudeCode"
          "enable"
        ]
      ];
    })
    # Windows の Claude Desktop (winget の Anthropic.Claude の MSIX。Cowork も使う)。入れるときに UAC の確認 (管理者の権限) が出る。
    # Windows の runner の手順 claude-desktop だけが読む switch (WSL の setup に同じ手順は無い)
    (windowsFilesTool "windowsClaudeDesktop" "Windows の Claude Desktop (MSIX)" "claudeDesktop" { })
    (tool "devTracker" "Notion Dev Tracker" [ "claude" "devTracker" "enable" ] { })
    # 見回り役は systemd の user service (macOS には launchd の agent を置いていない)
    (tool "devTrackerInbox" "Dev Tracker の見回り役" [ "claude" "devTracker" "inbox" "enable" ] {
      env = [ "linux" ];
    })
    # WSL では Windows の 1Password を使い、git の署名の道具の場所を Windows のユーザー名で組み立てる
    (tool "onePassword" "1Password" [ "onePassword" "enable" ] { env = [ "windowsUser" ]; })
    # op-reason の SSH の中継 (Windows の logon の task と、ssh の設定の IdentityAgent・WSL の ssh の向け先)。鍵を使う ssh の通り道を
    # 替える。Windows の側は runner が置くので、Windows の受け持ちを runner に切り替えた (win/ を配らない) WSL + 1Password のマシンでだけ
    # 効く。Windows の runner の手順 op-reason・ssh-config と、WSL の option (home/modules/op-reason.nix) が同じ名前で引く
    (tool "opReasonSshRelay" "op-reason の SSH の中継" [ "opReason" "sshRelay" "enable" ] {
      env = [
        "wsl"
        "noWindowsFiles"
      ];
      requires = [
        [
          "onePassword"
          "enable"
        ]
      ];
    })
    (tool "ntn" "ntn (Notion の CLI)" [ "ntn" "enable" ] { })
    (windowsFilesTool "windowsNtn" "Windows の ntn" "ntn" { })
    # OpenAI のコーディング エージェントの CLI。Linux は nixpkgs の codex、Windows は winget の OpenAI.Codex (Windows の runner の手順 codex
    # だけが読む switch。WSL の setup に同じ手順は無い)
    (tool "codex" "Codex CLI (OpenAI)" [ "codex" "enable" ] { })
    (windowsFilesTool "windowsCodex" "Windows の Codex CLI" "codex" { })
    # Windows の OpenSSH を dotfiles が固定した版 (winget の Microsoft.OpenSSH.Preview) に入れ替える。Windows には OpenSSH (System32) が
    # 初めから入っているので、版を上げるのは minimum の役目にしない (UAC の確認が出て、Windows Installer の不調な PC では落ちる)
    (windowsFilesTool "windowsOpenssh" "Windows の OpenSSH (固定した版)" "openssh" { })
    # tailnet にログインして使う VPN の道具
    (windowsFilesTool "windowsTailscale" "Windows の Tailscale" "tailscale" { })
    # tailnet から鍵でだけ入れる sshd。PC に外から入る口を開ける
    (windowsFilesTool "windowsSshd" "Windows の sshd (Tailscale から鍵で入る)" "sshd" { })
    # 自作のアプリ type-clipboard (個人の GitHub の repo の Release の exe)
    (windowsFilesTool "windowsTypeClipboard" "Windows の type-clipboard" "typeClipboard" { })
    (tool "gitIdentity" "git の名前とメール (pollenjp・pollenjp-sub)" [ "git" "identity" "enable" ] { })
  ];

  groupNamed =
    name:
    let
      found = builtins.filter (g: g.name == name) groups;
    in
    if found == [ ] then throw "groups.nix: そんなグループは無い: ${name}" else builtins.head found;
in
{
  inherit
    groups
    groupNames
    removedGroups
    envs
    base
    tools
    runnerTools
    runnerOnlyTools
    runnerDeps
    skills
    groupNamed
    ;

  # Linux のホストで skill name を出すか (skills の linux の道具が全部 on。表に無い skill はいつも出す)。cfg は config.dotfiles
  linuxSkillOn =
    cfg: name:
    builtins.all (
      k:
      let
        found = builtins.filter (t: t.key == k) tools;
      in
      if found == [ ] then
        throw "groups.nix: skills.${name}.linux の道具が表 (tools) に無い: ${k}"
      else
        builtins.foldl' (v: n: v.${n}) cfg (builtins.head found).option
    ) (skills.${name}.linux or [ ]);

  # グループ group に道具 t (tools の行) が入るか (follows の道具も、グループの集合としては同じ決まり)
  inGroup = group: t: group == "all" || t.minimum;

  # 環境の条件 name がホストで成り立つか。cfg は config.dotfiles、isLinux はホストの system が Linux か
  envHolds =
    { cfg, isLinux }:
    name:
    {
      linux = isLinux;
      wsl = cfg.wsl.enable;
      windowsFiles = cfg.wsl.windowsFiles.enable;
      noWindowsFiles = !cfg.wsl.windowsFiles.enable;
      windowsUser = !cfg.wsl.enable || cfg.wsl.onePassword.windowsUserName != null;
    }
    .${name};

  # dotfiles.group の値を確かめる (options.nix の apply)。やめたグループ (ADR 057) と知らない名前は、案内を出して評価を止める
  checkGroup =
    g:
    if builtins.elem g groupNames then
      g
    else if removedGroups ? ${g} then
      throw ''
        dotfiles.group = "${g}" は、もう使えません。設定グループは minimum・all の 2 つ (道具の集合) になりました (dotfiles-private の ADR 109)。
        group = "minimum"; にして、使う道具の switch (claude.enable など) をホストのファイルに書いてください。${removedGroups.${g}}。
        書き方は dotfiles の nix/README.md の「設定グループ」の「前のグループから移す」にあります。
      ''
    else
      throw "dotfiles.group は ${builtins.concatStringsSep "・" groupNames} のどれかで書いてください: ${g}";
}
