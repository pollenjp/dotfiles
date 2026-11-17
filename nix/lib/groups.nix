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
# lib/host-summary.nix (ホストの要約)・tests/groups.nix・tests/group-client.nix。
#
#   groups   グループ。tiers は on にする段 (① は全グループが入れるので書かない)。並びは既定の personal から
#   tiers    段。option は段の switch の dotfiles からの path (① は switch を持たないので null)
#   tools    道具の switch。並びは段の順、段の中は要約に出す順
#     key       group.json の tools のキーと、setup が読む bootstrap の見出し (# tool: <key>) の名前
#     option    dotfiles からの path (bool の option)
#     tiers     その道具が属する段 (① の道具は [ ])
#     derived   既定が段から決まるか。false は既定が段によらない (false の既定のまま、ホストが入れる option)
#     requires  効くための条件 (どれかが false なら値によらず効かない。要約は「–」と出す)
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
    }
    // extra;

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

    # ② と ③ の両方 (両方が on のときだけ入る)
    (tool "claudePrivateSkills" "private な skill (claude-skills の clone)" [
      "claude"
      "privateSkills"
      "enable"
    ] both { })
    (tool "ccPages" "cc-pages" [ "ccPages" "enable" ] both { })
    (tool "herdrHub" "集約ハブ ~/h" [ "herdr" "hub" "enable" ] both { })
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
  inherit groups tiers tools;

  groupNames = map (g: g.name) groups;

  inherit groupNamed;

  # グループ group が段 tier ("aiTools"・"personalAccounts") を入れるか (段の switch の既定)
  groupHasTier = group: tier: builtins.elem tier (groupNamed group).tiers;
}
