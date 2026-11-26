# home/options.nix の dotfiles.claude.notion.tokens (このマシンで Notion の API キーを使うプロファイルと、その種類の宣言) から作られる
# ~/.local/state/dotfiles/notion-tokens.json の中身と、書けない値で評価が止まることを、評価時に確かめる。
#
# 合わなければ assert で評価が止まり、外れた項目の名前が出る。評価で止まるので、
# CI の `nix flake check --all-systems --no-build` (全 system の評価) でも落ちる。
# flake.nix の checks (claude-notion-tokens-state) から呼ぶ。
#
# ## 確かめること
#
#   - 宣言が無くても notion-tokens.json を置き、中身は {"tokens":{}} と改行だけ
#   - mkHome の claude 引数 (claude.notion.tokens) でも、modules (dotfiles.claude.notion.tokens) でも同じ宣言を書ける
#   - プロファイルごとに kind・item・var が入る。var はプロファイルの名前を大文字にし、- を _ にしたものの頭に
#     PJP_NOTION_TOKEN_ を付けた名前 (personal → PJP_NOTION_TOKEN_PERSONAL、my-ws → PJP_NOTION_TOKEN_MY_WS)。item は
#     書かなければ null で、書けば参照の字のまま入る (欄まで書いた op://<vault>/<項目>/<欄> と、セクションのある
#     op://<vault>/<項目>/<セクション>/<欄>。op read にそのまま渡せる形)
#   - item は欄まで書いた op:// の参照だけを受け、値 (ntn_…)・空の字・欄の無い op://<vault>/<項目>・区切りが 5 つ以上・前に空白・
#     改行を含む字は評価で止まる。
#     止めるときの文 (assertions の message) にその字を出さず、プロファイルの名前だけを出す (値を書いてしまったときに、評価の
#     誤りの文から端末や CI のログへ値が出ないように。型の誤りの文は定義の値をそのまま出すので、型では止めない)
#   - kind は integration・personal だけ。ほかの字と、kind を書かない宣言は評価で止まる
#   - プロファイルの名前は profiles.toml の名前と同じ形 (英小文字か数字で始まり、英小文字・数字・- と _ だけ)。大文字・空白・
#     - で始まる名前と、同じ var になる 2 つの名前 (my-ws と my_ws) は評価で止まる
#   - Claude Code を入れないホスト (claude.enable = false) には置かない (読む resolver と pjp が無い)
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
      # Claude Code 一式と claude-skills (resolver) は minimum に入らない (使うホストが足す) ので、作り物のホストで足す
      claude = {
        enable = true;
        privateSkills.enable = true;
      }
      // claude;
    };
  configWith = claude: (homeWith claude [ ]).config;

  file = ".local/state/dotfiles/notion-tokens.json";
  text = cfg: cfg.home.file.${file}.text;
  stateOf = cfg: builtins.fromJSON (text cfg);

  # その宣言を書くと評価で止まる (型の誤りの throw と、assertions の throw を tryEval で拾う)
  rejects =
    tokens:
    !(builtins.tryEval (
      builtins.deepSeq (text (configWith {
        notion.tokens = tokens;
      })) true
    )).success;

  # 止めるときの文は、home/modules/claude.nix が assertions に渡す lib/notion-tokens.nix の list から読む (home-manager は失敗した
  # assertion があると config と options を読むところで止めるので、組み立てたホストからは文を読めない。claude.nix がこの list を
  # 渡していることは、上の rejects で確かめる)
  notionTokens = import ../lib/notion-tokens.nix { inherit lib; };
  failedMessages =
    tokens: map (a: a.message) (builtins.filter (a: !a.assertion) (notionTokens.assertions tokens));
  # 作り物の値 (token の形の字)。止めるときの文に出てはいけない
  fakeValue = "ntn_0000000000000000000000000000000000000000000000";

  byDefault = configWith { };
  personal = configWith {
    notion.tokens.personal = {
      kind = "integration";
    };
  };
  viaModules =
    (homeWith { } [
      {
        dotfiles.claude.notion.tokens.personal = {
          kind = "integration";
        };
      }
    ]).config;
  # 値は作り物 (vault と項目の ID の形の字と、欄・セクションの ID)
  itemBase = "op://abcdefghijklmnopqrstuvwxyz/zyxwvutsrqponmlkjihgfedcba";
  item = "${itemBase}/credential";
  itemSection = "${itemBase}/s0000000000000000000000000/credential";
  two = configWith {
    notion.tokens = {
      personal = {
        kind = "integration";
        inherit item;
      };
      my-ws = {
        kind = "personal";
        item = itemSection;
      };
    };
  };
  noClaude =
    (mkHome {
      username = "tester";
      inherit system;
      claude = {
        enable = false;
        notion.tokens.personal = {
          kind = "integration";
        };
      };
    }).config;

  cases = [
    {
      name = "宣言が無くても notion-tokens.json を置き、中身は {\"tokens\":{}} と改行だけ";
      ok = text byDefault == "{\"tokens\":{}}\n";
    }
    {
      name = "mkHome の claude 引数で tokens.personal を書くと kind・item (null)・var が入る";
      ok =
        stateOf personal == {
          tokens = {
            personal = {
              kind = "integration";
              item = null;
              var = "PJP_NOTION_TOKEN_PERSONAL";
            };
          };
        };
    }
    {
      name = "modules の dotfiles.claude.notion.tokens でも同じ宣言を書ける";
      ok = text viaModules == text personal;
    }
    {
      name = "var は名前を大文字にし - を _ にしたもの。item は参照の字のまま入る (欄まで・セクションと欄まで)";
      ok =
        stateOf two == {
          tokens = {
            personal = {
              kind = "integration";
              inherit item;
              var = "PJP_NOTION_TOKEN_PERSONAL";
            };
            my-ws = {
              kind = "personal";
              item = itemSection;
              var = "PJP_NOTION_TOKEN_MY_WS";
            };
          };
        };
    }
    {
      name = "notion-tokens.json は改行で終わる";
      ok = lib.hasSuffix "\n" (text two);
    }
    {
      name = "item に値 (ntn_…)・空の字・欄の無い op://<vault>/<項目>・区切りが 5 つ以上・前に空白・改行を含む字を書くと評価で止まる";
      ok =
        builtins.all
          (
            v:
            rejects {
              personal = {
                kind = "integration";
                item = v;
              };
            }
          )
          [
            fakeValue
            ""
            "op://abcdefghijklmnopqrstuvwxyz"
            itemBase
            "${itemBase}/"
            "${itemSection}/x"
            " ${item}"
            "${item}\n"
          ];
    }
    {
      name = "item に値を書いて止めるときの文は、プロファイルの名前を出し、値を出さない";
      ok =
        let
          msgs = failedMessages {
            personal = {
              kind = "integration";
              item = fakeValue;
            };
          };
        in
        msgs != [ ]
        && builtins.any (lib.hasInfix "dotfiles.claude.notion.tokens.personal.item") msgs
        && !(builtins.any (lib.hasInfix fakeValue) msgs);
    }
    {
      name = "kind が integration・personal の外 (api) なら評価で止まる。kind を書かない宣言も止まる";
      ok = rejects { personal.kind = "api"; } && rejects { personal = { }; };
    }
    {
      name = "名前が profiles.toml の形でない (大文字・空白・- で始まる) と評価で止まる";
      ok = builtins.all (n: rejects { ${n}.kind = "integration"; }) [
        "Personal"
        "my ws"
        "-x"
      ];
    }
    {
      name = "同じ var になる 2 つの名前 (my-ws と my_ws) は評価で止まる";
      ok = rejects {
        my-ws.kind = "integration";
        my_ws.kind = "personal";
      };
    }
    {
      name = "ふつうの名前と item (書かない・op://<vault>/<項目>/<欄>) は通る";
      ok =
        !(rejects { personal.kind = "integration"; })
        && !(rejects {
          personal = {
            kind = "personal";
            inherit item;
          };
        });
    }
    {
      name = "Claude Code を入れないホスト (claude.enable = false) には notion-tokens.json を置かない";
      ok = !(noClaude.home.file ? ${file});
    }
  ];

  failed = builtins.filter (c: !c.ok) cases;
in
assert lib.assertMsg (failed == [ ])
  "claude-notion-tokens-state: 合わない項目: ${lib.concatMapStringsSep " / " (c: c.name) failed}";
pkgs.runCommand "claude-notion-tokens-state" { } ''
  echo ${lib.escapeShellArg (lib.concatMapStringsSep "\n" (c: "ok   ${c.name}") cases)}
  touch $out
''
