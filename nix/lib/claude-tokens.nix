# dotfiles.claude.tokens (このホストのどのアカウントに、どの claude setup-token の token を置いたかの宣言。home/options.nix) から、
# ~/.local/state/dotfiles/claude-tokens.json の中身と、宣言を確かめる home-manager の assertions を作る。
#
# home/modules/claude.nix が使う。tests/claude-tokens.nix は、止めるときの文に名前・label・item の字 (token の値を書いてしまったときの
# 値) が出ないことを、ここの assertions の list で確かめる (home-manager は失敗した assertion があると config も options も読めなくする
# ので、組み立てたホストからは文を読めない)。
#
#   stateText <tokens>   claude-tokens.json の中身 (改行で終わる)。宣言が無くても {"accounts":{}}。label は書かなければアカウントの名前、
#                        item は書かなければ null。形の違う宣言では、字を出さない文で止まる (assertions が先に止める)
#   assertions <tokens>  表か・名前の形・値が表か・知らないキー・label の形・item の形を確かめる assertions の list
#   hasBare <tokens>     素の claude (default) を宣言したか
#   bareName             素の claude (~/.claude) の名前 (default)。この名前を宣言すると、素の claude がその token で起きる
#
# option の型は anything (home/options.nix) で、形はここの assertions だけで見る。型 (attrsOf submodule・str) の誤りの文は、定義の値を
# そのまま出すため (宣言に token の値を書いてしまったとき (`claude.tokens.alt = "sk-ant-…"`・`{ token = "sk-ant-…"; }`) に、評価の
# 誤りの文から端末や CI のログへ値が出る)。止める文には、名前は数だけ、label・item・知らないキーは宣言の名前だけを出す。
#
# 名前は claude-account のアカウントの名前 (英小文字・数字で始まり、英小文字・数字・- と _ だけで 32 字まで。sk-ant- で始まらない。
# account・selector は使えない。nix/pkgs/claude-account の name_ok と同じ)。default は素の claude。
#
# Windows の runner (win/runner/src/host.rs の parse_claude_tokens・claude_tokens_json) が、ホストの値の [claude.tokens] から同じ中身の JSON を
# 書き、同じ見方で宣言を止める。ここを直したら runner も直す (Linux の CI が win/runner/tests/claude_parity.rs で、stateText と assertions を
# runner と突き合わせる)。設計は dotfiles-private の docs/adr/123_claude_token_watch_*。
{ lib }:

let
  bareName = "default";
  # 宣言の値 (表) に書けるキー
  keys = [
    "label"
    "item"
  ];

  nameOk =
    n:
    builtins.match "[a-z0-9][a-z0-9_-]*" n != null
    && builtins.stringLength n <= 32
    && !(lib.hasPrefix "sk-ant-" n)
    && !(builtins.elem n [
      "account"
      "selector"
    ]);

  # 同じ token を置いた所 (ほかのホスト・ほかのアカウント) で同じにする呼び名。英小文字・数字で始まり、英小文字・数字・. - _ だけで 64 字まで。
  # sk-ant- で始まるものは断る (token の値を label に書いたとき)
  labelOk =
    l:
    builtins.isString l
    && builtins.match "[a-z0-9][a-z0-9._-]*" l != null
    && builtins.stringLength l <= 64
    && !(lib.hasPrefix "sk-ant-" l);

  # 欄まで書いた 1Password の参照 (op://<vault>/<項目>/<欄>、セクションがあれば op://<vault>/<項目>/<セクション>/<欄>)。lib/notion-tokens.nix と同じ形
  itemOk =
    i:
    i == null
    || (
      builtins.isString i
      && builtins.match "op://[^/[:cntrl:]]+/[^/[:cntrl:]]+/[^/[:cntrl:]]+(/[^/[:cntrl:]]+)?" i != null
    );

  # 宣言の形が全部合っているか (stateText が値に触る前に見る。合わない形は assertions が字を出さずに止める)
  entryOk =
    n: t:
    builtins.isAttrs t
    && builtins.all (k: builtins.elem k keys) (builtins.attrNames t)
    && labelOk (t.label or n)
    && itemOk (t.item or null);
  shapeOk =
    tokens:
    builtins.isAttrs tokens
    && builtins.all (n: nameOk n && entryOk n tokens.${n}) (builtins.attrNames tokens);
in
{
  inherit bareName;

  hasBare = tokens: builtins.isAttrs tokens && tokens ? ${bareName};

  #   {"accounts": {"alt": {"item": null, "label": "alt"}, "default": {"item": null, "label": "main"}}}
  stateText =
    tokens:
    if shapeOk tokens then
      builtins.toJSON {
        accounts = lib.mapAttrs (n: t: {
          label = t.label or n;
          item = t.item or null;
        }) tokens;
      }
      + "\n"
    else
      throw "claude.nix: dotfiles.claude.tokens の形が違います (書いた字は出しません。assertions の文を見てください)";

  assertions =
    tokens:
    let
      isSet = builtins.isAttrs tokens;
      names = if isSet then builtins.attrNames tokens else [ ];
      badNames = builtins.filter (n: !(nameOk n)) names;
      goodNames = builtins.filter nameOk names;
      notSets = builtins.filter (n: !(builtins.isAttrs tokens.${n})) goodNames;
      sets = builtins.filter (n: builtins.isAttrs tokens.${n}) goodNames;
      unknownKeys = builtins.filter (
        n: builtins.any (k: !(builtins.elem k keys)) (builtins.attrNames tokens.${n})
      ) sets;
      badLabels = builtins.filter (n: !(labelOk (tokens.${n}.label or n))) sets;
      badItems = builtins.filter (n: !(itemOk (tokens.${n}.item or null))) sets;
      opt = n: "dotfiles.claude.tokens.${n}";
    in
    [
      {
        assertion = isSet;
        message = ''
          claude.nix: dotfiles.claude.tokens は、アカウントの名前ごとの表 ({ <名前> = { label = …; item = …; }; }) で書いてください (書いた字は出しません)。
          token の値そのものを書いたのなら、その行を消して、token を作り直してください (commit した値は履歴に残ります)。
        '';
      }
      # 名前に token の値を書いてしまったときに、端末や CI のログへ出ないよう、規則に合わない名前は数だけを出す
      {
        assertion = badNames == [ ];
        message = ''
          claude.nix: dotfiles.claude.tokens のキー (アカウントの名前) のうち ${toString (builtins.length badNames)} 個が、アカウントの名前の形ではありません (書いた字は出しません)。
          英小文字・数字で始め、英小文字・数字・- と _ だけで 32 字までにしてください (sk-ant- で始まる字・account・selector は使えない)。
          素の claude (~/.claude) は default と書きます。token の値そのものを書いたのなら、その行を消して、token を作り直してください。
        '';
      }
      # 文には書いた字を出さない (値を書いてしまったとき、端末や CI のログへ出ないように)。名前だけを出す
      {
        assertion = notSets == [ ];
        message = ''
          claude.nix: ${
            lib.concatMapStringsSep "・" opt notSets
          } は、表 ({ label = …; item = …; }。どちらも書かなければ { }) で書いてください (書いた字は出しません)。
          token の値そのものを書いたのなら、その行を消して、token を作り直してください (commit した値は履歴に残ります)。
        '';
      }
      {
        assertion = unknownKeys == [ ];
        message = ''
          claude.nix: ${
            lib.concatMapStringsSep "・" opt unknownKeys
          } に、知らないキーがあります (書けるのは label・item。書いた字は出しません)。
          token の値は宣言に書きません (token のファイルに claude-account set-token で入れる)。値そのものを書いたのなら、その行を消して、token を
          作り直してください (commit した値は履歴に残ります)。
        '';
      }
      {
        assertion = badLabels == [ ];
        message = ''
          claude.nix: ${
            lib.concatMapStringsSep "・" (n: "${opt n}.label") badLabels
          } が、token の呼び名の形ではありません (書いた字は出しません)。
          英小文字・数字で始め、英小文字・数字・. - _ だけで 64 字までにしてください (sk-ant- で始まる字は使えない)。同じ token を置いた
          ホスト・アカウントで同じ呼び名にします (書かなければアカウントの名前)。token の値そのものを書いたのなら、その行を消して、token を
          作り直してください (commit した値は履歴に残ります)。
        '';
      }
      {
        assertion = badItems == [ ];
        message = ''
          claude.nix: ${
            lib.concatMapStringsSep "・" (n: "${opt n}.item") badItems
          } が、欄まで書いた 1Password の参照 (op://<vault の ID>/<項目の ID>/<欄の ID>。セクションがあれば
          op://<vault>/<項目>/<セクション>/<欄>) の形ではありません (書いた字は出しません)。
          pjp-op-ref が出す ID の形の参照を書くか、分かるまで null にしてください。token の値そのものを書いたのなら、その行を消して、token を作り直してください
          (commit した値は履歴に残ります)。
        '';
      }
    ];
}
