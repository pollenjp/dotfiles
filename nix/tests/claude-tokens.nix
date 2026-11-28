# home/options.nix の dotfiles.claude.tokens (このホストのどのアカウントに、どの claude setup-token の token を置いたかの宣言) から作られる
# ~/.local/state/dotfiles/claude-tokens.json の中身と、素の claude (default) を宣言したときの wrapper と PATH、書けない値で評価が止まることを、
# 評価時に確かめる。
#
# 合わなければ assert で評価が止まり、外れた項目の名前が出る。評価で止まるので、
# CI の `nix flake check --all-systems --no-build` (全 system の評価) でも落ちる。
# flake.nix の checks (claude-tokens-state) から呼ぶ。
#
# ## 確かめること
#
#   - 宣言が無くても claude-tokens.json を置き、中身は {"accounts":{}} と改行だけ。wrapper を置かず、login の PATH も変えない
#   - mkHome の claude 引数 (claude.tokens) でも、modules (dotfiles.claude.tokens) でも同じ宣言を書ける
#   - アカウントごとに label・item が入る。label は書かなければアカウントの名前、item は書かなければ null で、書けば参照の字のまま
#   - default (素の claude) を宣言すると、~/.local/share/claude-account/bin/claude を claude-account の script への link にし、login の
#     環境の PATH (home.sessionPath) の頭と、対話のシェル (fish・bash) の mise activate の後 (順番 2000) で PATH の頭に置き直す行を足す
#   - 名前は claude-account のアカウントの名前の形 (英小文字・数字で始まり、英小文字・数字・- と _ だけで 32 字まで。sk-ant- で始まらない。
#     account・selector は使えない)。label は英小文字・数字で始まり、英小文字・数字・. - _ だけで 64 字まで (sk-ant- で始まらない)。
#     item は欄まで書いた op:// の参照か null。どれも外れると評価で止まり、止めるときの文に書いた字 (token の値を書いてしまったときの値) を
#     出さない (名前は数だけ、label と item は宣言の名前だけを出す)
#   - Claude Code を入れないホスト (claude.enable = false) には置かない (読む claude-account が無い)
{
  lib,
  pkgs,
  mkHome,
  system,
}:

let
  homeWith =
    claude: modules:
    mkHome {
      username = "tester";
      inherit system modules;
      # Claude Code 一式は minimum に入らない (使うホストが足す) ので、作り物のホストで足す
      claude = {
        enable = true;
      }
      // claude;
    };
  configWith = claude: (homeWith claude [ ]).config;

  file = ".local/state/dotfiles/claude-tokens.json";
  wrapper = ".local/share/claude-account/bin/claude";
  bareDir = "$HOME/.local/share/claude-account/bin";
  text = cfg: cfg.home.file.${file}.text;
  stateOf = cfg: builtins.fromJSON (text cfg);

  # その宣言を書くと評価で止まる (型の誤りの throw と、assertions の throw を tryEval で拾う)
  rejects =
    tokens:
    !(builtins.tryEval (
      builtins.deepSeq (text (configWith {
        inherit tokens;
      })) true
    )).success;

  # 止めるときの文は、home/modules/claude.nix が assertions に渡す lib/claude-tokens.nix の list から読む (home-manager は失敗した
  # assertion があると config と options を読むところで止めるので、組み立てたホストからは文を読めない。claude.nix がこの list を
  # 渡していることは、上の rejects で確かめる)
  claudeTokens = import ../lib/claude-tokens.nix { inherit lib; };
  failedMessages =
    tokens:
    map (a: a.message) (
      builtins.filter (a: !a.assertion) (
        claudeTokens.assertions (
          lib.mapAttrs (n: t: {
            label = t.label or n;
            item = t.item or null;
          }) tokens
        )
      )
    );
  # 作り物の値 (token の形の字)。止めるときの文に出てはいけない
  fakeValue = "sk-ant-oat01-000000000000000000000000000000000000000000000000";

  byDefault = configWith { };
  three = configWith {
    tokens."alt" = { };
  };
  viaModules =
    (homeWith { } [
      {
        dotfiles.claude.tokens."alt" = { };
      }
    ]).config;
  # 値は作り物 (vault と項目の ID の形の字と、欄の ID)
  item = "op://abcdefghijklmnopqrstuvwxyz/zyxwvutsrqponmlkjihgfedcba/credential";
  bare = configWith {
    tokens = {
      default = {
        label = "main";
        inherit item;
      };
      "alt" = { };
    };
  };
  noClaude =
    (mkHome {
      username = "tester";
      inherit system;
      claude = {
        enable = false;
        tokens.default = { };
      };
    }).config;

  cases = [
    {
      name = "宣言が無くても claude-tokens.json を置き、中身は {\"accounts\":{}} と改行だけ";
      ok = text byDefault == "{\"accounts\":{}}\n";
    }
    {
      name = "宣言が無ければ素の claude の wrapper を置かず、login の PATH の頭に足さない";
      ok = !(byDefault.home.file ? ${wrapper}) && !(builtins.elem bareDir byDefault.home.sessionPath);
    }
    {
      name = "mkHome の claude 引数で tokens.\"alt\" を書くと、label (アカウントの名前)・item (null) が入る";
      ok =
        stateOf three == {
          accounts = {
            "alt" = {
              label = "alt";
              item = null;
            };
          };
        };
    }
    {
      name = "modules の dotfiles.claude.tokens でも同じ宣言を書ける";
      ok = text viaModules == text three;
    }
    {
      name = "label・item は書いた字のまま入り、claude-tokens.json は改行で終わる";
      ok =
        stateOf bare == {
          accounts = {
            default = {
              label = "main";
              inherit item;
            };
            "alt" = {
              label = "alt";
              item = null;
            };
          };
        }
        && lib.hasSuffix "\n" (text bare);
    }
    {
      name = "alt だけの宣言 (default なし) では wrapper を置かない";
      ok = !(three.home.file ? ${wrapper});
    }
    {
      name = "default を宣言すると、~/.local/share/claude-account/bin/claude を claude-account の script への link にする";
      ok =
        bare.home.file ? ${wrapper}
        && lib.hasSuffix "/bin/claude-account" (toString bare.home.file.${wrapper}.source);
    }
    {
      name = "default を宣言すると、wrapper の dir を login の環境の PATH (home.sessionPath) の頭に足す";
      ok = builtins.head bare.home.sessionPath == bareDir;
    }
    {
      name = "default を宣言すると、対話の fish と bash で mise activate の後に wrapper の dir を PATH の頭に置き直す";
      ok =
        let
          fish = bare.programs.fish.interactiveShellInit;
          bash = bare.programs.bash.initExtra;
          fishLine = "set -gx PATH \"$HOME/.local/share/claude-account/bin\"";
          miseFish = "activate fish | source";
          miseBash = "activate bash)\"";
          after =
            s: a: b:
            lib.hasInfix a s && lib.hasInfix b s && lib.hasInfix b (lib.last (lib.splitString a s));
        in
        after fish miseFish fishLine
        && after bash miseBash "_claude_bare_bin=\"$HOME/.local/share/claude-account/bin\"";
    }
    {
      name = "名前が claude-account の名前の形でない (大文字・空白・- で始まる・33 字・sk-ant- で始まる・account・selector) と評価で止まる";
      ok = builtins.all (n: rejects { ${n} = { }; }) [
        "Personal"
        "my ws"
        "-x"
        "a23456789012345678901234567890123"
        fakeValue
        "account"
        "selector"
      ];
    }
    {
      name = "名前に token を書いて止めるときの文は、数だけを出し、書いた字を出さない";
      ok =
        let
          msgs = failedMessages { ${fakeValue} = { }; };
        in
        msgs != [ ]
        && builtins.any (lib.hasInfix "1 個") msgs
        && !(builtins.any (lib.hasInfix fakeValue) msgs);
    }
    {
      name = "label が呼び名の形でない (大文字・空白・空・65 字・sk-ant- で始まる) と評価で止まる";
      ok = builtins.all (l: rejects { "alt".label = l; }) [
        "Main"
        "a b"
        ""
        "a2345678901234567890123456789012345678901234567890123456789012345"
        fakeValue
      ];
    }
    {
      name = "label に値を書いて止めるときの文は、宣言の名前を出し、値を出さない";
      ok =
        let
          msgs = failedMessages { "alt".label = fakeValue; };
        in
        msgs != [ ]
        && builtins.any (lib.hasInfix "dotfiles.claude.tokens.alt.label") msgs
        && !(builtins.any (lib.hasInfix fakeValue) msgs);
    }
    {
      name = "item に値・空の字・欄の無い op://<vault>/<項目>・改行を含む字を書くと評価で止まり、文に値を出さない";
      ok =
        builtins.all (v: rejects { "alt".item = v; }) [
          fakeValue
          ""
          "op://abcdefghijklmnopqrstuvwxyz/zyxwvutsrqponmlkjihgfedcba"
          "${item}\n"
        ]
        && (
          let
            msgs = failedMessages { "alt".item = fakeValue; };
          in
          builtins.any (lib.hasInfix "dotfiles.claude.tokens.alt.item") msgs
          && !(builtins.any (lib.hasInfix fakeValue) msgs)
        );
    }
    {
      name = "ふつうの名前・label・item (書かない・op://<vault>/<項目>/<欄>) は通る";
      ok =
        !(rejects { "alt" = { }; })
        && !(rejects {
          default = {
            label = "main.v2_x-1";
            inherit item;
          };
        });
    }
    {
      name = "Claude Code を入れないホスト (claude.enable = false) には claude-tokens.json も wrapper も置かない";
      ok = !(noClaude.home.file ? ${file}) && !(noClaude.home.file ? ${wrapper});
    }
  ];

  failed = builtins.filter (c: !c.ok) cases;
in
assert lib.assertMsg (failed == [ ])
  "claude-tokens-state: 合わない項目: ${lib.concatMapStringsSep " / " (c: c.name) failed}";
pkgs.runCommand "claude-tokens-state" { } ''
  echo ${lib.escapeShellArg (lib.concatMapStringsSep "\n" (c: "ok   ${c.name}") cases)}
  touch $out
''
