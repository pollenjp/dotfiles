# 設定グループと、道具の段 (①②③) への割り当ての表 (dotfiles-private の docs/adr/057_host_setting_groups_*)。
#
# ホストは設定グループ (personal・company・client) を 1 つ選び (dotfiles.group。mkHome の group)、グループは「どの段まで
# 入れるか」で決まる。
#
#   ① エンジニアの道具              shell・git・ssh・vim・tmux・CLI・mise・direnv・python・CA の束・WSL の手当て・Windows のアプリ
#   ② AI の道具                     Claude Code 一式・herdr・cursor-agent・Windows の Claude Code と herdr
#   ③ 個人のアカウントにつながるもの  1Password・Notion (ntn・Dev Tracker)・private な repo の clone・個人の git の名前とメール
#
# ② と ③ の両方に当たるもの (claude-skills の clone・cc-pages・~/h・Dev Tracker) は、両方が on のときだけ入る。
#
# ここは表 (data) だけを持つ。option の既定は home/options.nix に素の式で書く (段の switch は dotfiles.group から、道具の
# switch は段の switch から)。表と既定が合っていることは tests/groups.nix (flake の checks の groups-state) が、段の on/off の
# 4 つの組み合わせで確かめる。道具の switch を足す・段を変えるときは、ここと options.nix の両方を直す。
#
# 表を読むもの: home/modules/group.nix (~/.local/state/dotfiles/group.json。setup が読んで手順を飛ばす)・
# lib/host-summary/ (ホストの要約)・tests/groups.nix・tests/group-client.nix。
#
#   groups   グループ。tiers は on にする段 (① は全グループが入れるので書かない)。並びは既定の personal から
#   tiers    段。option は段の switch の dotfiles からの path (① は switch を持たないので null)
#   tools    道具の switch。並びは段の順、段の中は要約に出す順
#     key       group.json の tools のキーと、setup が読む bootstrap の見出し (# tool: <key>) の名前
#     option    dotfiles からの path (bool の option)
#     tiers     その道具が属する段 (① の道具は [ ])
#     derived   既定が段から決まるか。false は既定が段によらない (false の既定のまま、ホストが入れる option)
#     requires  効くための条件 (どれかが false なら値によらず効かない。要約は「–」と出す)
#     short     ホストの要約の図の箱に出す短い名前 (下の shorts。無ければ label)
#     runner    Windows の runner (win/runner/) が手順の gate で読む道具か (下の runnerTools)
let
  # win/ を配るマシンでだけ効く Windows のアプリの switch の条件
  windowsFiles = [
    "wsl"
    "windowsFiles"
    "enable"
  ];

  groups = [
    {
      name = "personal";
      label = "個人";
      description = "個人の開発用の PC。① ② ③ を全部入れる (グループを選ばないホストもこれ)";
      tiers = [
        "aiTools"
        "personalAccounts"
      ];
    }
    {
      name = "company";
      label = "自社";
      description = "自社の PC。① と ② を入れ、③ は要るものだけをホストで足す";
      tiers = [ "aiTools" ];
    }
    {
      name = "client";
      label = "客先";
      description = "客先の PC。① だけを入れ、許可の出た道具をホストで 1 つずつ足す";
      tiers = [ ];
    }
  ];

  tiers = [
    {
      name = "engineer";
      mark = "①";
      label = "エンジニアの道具";
      option = null;
    }
    {
      name = "aiTools";
      mark = "②";
      label = "AI の道具";
      option = [
        "aiTools"
        "enable"
      ];
    }
    {
      name = "personalAccounts";
      mark = "③";
      label = "個人のアカウント";
      option = [
        "personalAccounts"
        "enable"
      ];
    }
  ];

  tool =
    key: label: option: tiers: extra:
    {
      inherit
        key
        label
        option
        tiers
        ;
      derived = true;
      requires = [ ];
      short = shorts.${key} or label;
      runner = builtins.elem key runnerTools;
    }
    // extra;

  # ホストの要約の図 (lib/host-summary/ の HTML) の箱に出す短い名前。箱の幅に収まる長さにし、label (表とポップアップに出す) と
  # 同じ道具だと分かる名前にする
  shorts = {
    wsl = "WSL の手当て";
    windowsFiles = "win/ の配布";
    windowsTypeClipboard = "Win の type-clipboard";
    exeExecTrace = ".exe の起動の記録";
    mtuGuard = "MTU の見張り";
    osCaBundle = "証明書の束 (OS)";
    cleanup = "store・mise の掃除";
    claude = "Claude Code";
    herdrCore = "herdr-core (hc)";
    windowsClaudeCode = "Win の Claude Code";
    windowsHerdr = "Win の herdr";
    t3Code = "T3 Code";
    windowsT3Code = "Win の T3 Code";
    claudePrivateSkills = "private な skill";
    herdrHub = "集約ハブ ~/h";
    windowsClaudeAccounts = "Win の claude アカウント";
    devTracker = "Dev Tracker";
    devTrackerInbox = "Dev Tracker の見回り";
    onePassword = "1Password";
    opReasonSshRelay = "SSH の中継";
    ntn = "ntn";
    windowsNtn = "Win の ntn";
    windowsTailscale = "Win の Tailscale";
    windowsSshd = "Win の sshd";
    gitIdentity = "git の名前とメール";
  };

  # Windows の runner が手順の gate で読む道具 (win/README.md の「ホストの値」の一覧と同じ)。ホストの要約は、dotfiles-private の
  # win/hosts/*.toml (Windows のホストの値) のページに、この道具だけを箱にして出す。runner に道具を足したら、ここにも足す
  runnerTools = [
    "windowsTypeClipboard"
    "windowsClaudeCode"
    "windowsHerdr"
    "windowsT3Code"
    "claudePrivateSkills"
    "herdrHub"
    "windowsClaudeAccounts"
    "devTracker"
    "onePassword"
    "opReasonSshRelay"
    "windowsNtn"
    "windowsTailscale"
    "windowsSshd"
    "gitIdentity"
  ];

  both = [
    "aiTools"
    "personalAccounts"
  ];

  tools = [
    # ① エンジニアの道具 (段の switch は無い。既定は今のまま)
    (tool "wsl" "WSL の手当て" [ "wsl" "enable" ] [ ] { })
    (tool "windowsFiles" "Windows のアプリと設定 (win/)" [ "wsl" "windowsFiles" "enable" ] [ ] { })
    (tool "windowsTypeClipboard" "Windows の type-clipboard"
      [ "wsl" "windowsFiles" "typeClipboard" "enable" ]
      [ ]
      {
        requires = [ windowsFiles ];
      }
    )
    (tool "exeExecTrace" ".exe の起動の記録 (WSL)" [ "wsl" "exeExecTrace" "enable" ] [ ] { })
    (tool "mtuGuard" "eth0 の MTU の見張り (WSL)" [ "wsl" "mtuGuard" "enable" ] [ ] { })
    (tool "osCaBundle" "証明書の束を OS の信頼ストアに寄せる" [ "osCaBundle" "enable" ] [ ] { })
    (tool "cleanup" "使わない store path・mise の版の掃除" [ "cleanup" "enable" ] [ ] { })

    # ② AI の道具
    (tool "claude" "Claude Code 一式" [ "claude" "enable" ] [ "aiTools" ] { })
    (tool "herdr" "herdr" [ "herdr" "enable" ] [ "aiTools" ] { })
    (tool "herdrCore" "herdr-core (hc)" [ "herdrCore" "enable" ] [ "aiTools" ] { })
    (tool "windowsClaudeCode" "Windows の Claude Code"
      [ "wsl" "windowsFiles" "claudeCode" "enable" ]
      [ "aiTools" ]
      {
        requires = [ windowsFiles ];
      }
    )
    (tool "windowsHerdr" "Windows の herdr・herdr-app"
      [ "wsl" "windowsFiles" "herdr" "enable" ]
      [ "aiTools" ]
      {
        requires = [ windowsFiles ];
      }
    )
    (tool "cursorAgent" "cursor-agent" [ "cursorAgent" "enable" ] [ "aiTools" ] { derived = false; })
    # T3 Code (CLI と常駐の service・設定)。Claude の会話を別の UI と端末から使う道具で、どのグループでも既定で入れない (入れるホストが
    # 足す)。claude のアカウント t3 と Claude の設定を前提にするので、claude が off なら効かない
    (tool "t3Code" "T3 Code (t3 と t3code.service)" [ "t3Code" "enable" ] [ "aiTools" ] {
      derived = false;
      requires = [
        [
          "claude"
          "enable"
        ]
      ];
    })
    # Windows の T3 Code (desktop app と設定)。Windows の runner の手順 t3-code・t3-code-settings だけが読む switch (WSL の setup に同じ
    # 手順は無い)。どのグループでも既定で入れない (入れるホストが足す)
    (tool "windowsT3Code" "Windows の T3 Code" [ "wsl" "windowsFiles" "t3Code" "enable" ] [ "aiTools" ] {
      derived = false;
      requires = [ windowsFiles ];
    })

    # ② と ③ の両方 (両方が on のときだけ入る)
    (tool "claudePrivateSkills" "private な skill (claude-skills の clone)" [
      "claude"
      "privateSkills"
      "enable"
    ] both { })
    (tool "ccPages" "cc-pages" [ "ccPages" "enable" ] both { })
    (tool "herdrHub" "集約ハブ ~/h" [ "herdr" "hub" "enable" ] both { })
    # 初回の apply で UAC の確認 (管理者の権限) が出る手順なので、会社や客先の PC では既定で走らせない (personal だけ既定で on)。
    # Windows の runner の手順 claude-accounts だけが読む switch (WSL の setup に同じ手順は無い)
    (tool "windowsClaudeAccounts" "Windows の claude-personal・claude-work"
      [ "wsl" "windowsFiles" "claudeAccounts" "enable" ]
      both
      {
        requires = [
          windowsFiles
          [
            "wsl"
            "windowsFiles"
            "claudeCode"
            "enable"
          ]
        ];
      }
    )
    (tool "devTracker" "Notion Dev Tracker" [ "claude" "devTracker" "enable" ] both {
      derived = false;
    })
    (tool "devTrackerInbox" "Dev Tracker の見回り役" [ "claude" "devTracker" "inbox" "enable" ] both {
      derived = false;
    })

    # ③ 個人のアカウントにつながるもの
    (tool "onePassword" "1Password" [ "onePassword" "enable" ] [ "personalAccounts" ] {
      derived = false;
    })
    # op-reason の SSH の中継 (Windows の logon の task と、ssh の設定の IdentityAgent・WSL の ssh の向け先)。鍵を使う ssh の通り道を
    # 替えるので、personal でも既定で入れない (入れるホストが足す)。Windows の runner の手順 op-reason・ssh-config と、WSL の option
    # (home/modules/op-reason.nix。Windows の受け持ちを runner に切り替えたマシンだけ) が同じ名前で引く
    (tool "opReasonSshRelay" "op-reason の SSH の中継"
      [ "opReason" "sshRelay" "enable" ]
      [ "personalAccounts" ]
      {
        derived = false;
        requires = [
          [
            "onePassword"
            "enable"
          ]
        ];
      }
    )
    (tool "ntn" "ntn (Notion の CLI)" [ "ntn" "enable" ] [ "personalAccounts" ] { })
    (tool "windowsNtn" "Windows の ntn" [ "wsl" "windowsFiles" "ntn" "enable" ] [ "personalAccounts" ] {
      requires = [ windowsFiles ];
    })
    # tailnet にログインして使う VPN の道具。会社の PC などに勝手に入れないよう、personal でも既定で入れない (入れるホストが足す)
    (tool "windowsTailscale" "Windows の Tailscale"
      [ "wsl" "windowsFiles" "tailscale" "enable" ]
      [ "personalAccounts" ]
      {
        derived = false;
        requires = [ windowsFiles ];
      }
    )
    # tailnet から鍵でだけ入れる sshd。PC に外から入る口を開けるので、personal でも既定で入れない (入れるホストが足す)
    (tool "windowsSshd" "Windows の sshd (Tailscale から鍵で入る)"
      [ "wsl" "windowsFiles" "sshd" "enable" ]
      [ "personalAccounts" ]
      {
        derived = false;
        requires = [ windowsFiles ];
      }
    )
    (tool "gitIdentity" "git の名前とメール (pollenjp・pollenjp-sub)"
      [ "git" "identity" "enable" ]
      [
        "personalAccounts"
      ]
      { }
    )
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
    tiers
    tools
    runnerTools
    ;

  groupNames = map (g: g.name) groups;

  inherit groupNamed;

  # グループ group が段 tier ("aiTools"・"personalAccounts") を入れるか (段の switch の既定)
  groupHasTier = group: tier: builtins.elem tier (groupNamed group).tiers;
}
