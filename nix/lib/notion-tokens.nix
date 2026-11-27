# dotfiles.claude.notion.tokens (このマシンで Notion の API キーを使うプロファイルと、その種類の宣言。home/options.nix) から、
# ~/.local/state/dotfiles/notion-tokens.json の中身と、宣言を確かめる home-manager の assertions を作る。
#
# home/modules/claude.nix が使う。tests/claude-notion-tokens.nix は、止めるときの文に item の字 (値を書いてしまったときの値) が
# 出ないことを、ここの assertions の list で確かめる (home-manager は失敗した assertion があると config も options も読めなくする
# ので、組み立てたホストからは文を読めない)。
#
#   var <名前>          ~/.config/pjp/env の変数名。名前を大文字にし、- を _ にする (claude-skills の resolver と同じ規則。
#                       personal → PJP_NOTION_TOKEN_PERSONAL、my-ws → PJP_NOTION_TOKEN_MY_WS)
#   stateText <tokens>  notion-tokens.json の中身 (改行で終わる)。宣言が無くても {"tokens":{}}
#   assertions <tokens> 名前の形・同じ変数になる名前・item の形を確かめる assertions の list
#
# Windows の runner (win/runner/src/host.rs の parse_tokens・tokens_json) が、ホストの値の [claude.notion.tokens] から同じ中身の JSON を
# 書き、同じ見方で宣言を止める。ここを直したら runner も直す (Linux の CI が win/runner/tests/claude_parity.rs で、stateText と assertions を
# runner と突き合わせる)。
{ lib }:

let
  var = name: "PJP_NOTION_TOKEN_" + lib.toUpper (builtins.replaceStrings [ "-" ] [ "_" ] name);
in
{
  inherit var;

  #   {"tokens": {"personal": {"kind": "integration", "item": null, "var": "PJP_NOTION_TOKEN_PERSONAL"}}}
  #
  # submodule の値は _module も持つので、kind と item を名指しで写す
  stateText =
    tokens:
    builtins.toJSON {
      tokens = lib.mapAttrs (name: t: {
        inherit (t) kind item;
        var = var name;
      }) tokens;
    }
    + "\n";

  assertions =
    tokens:
    let
      names = builtins.attrNames tokens;
      # profiles.toml の名前の形 (notion.profile の型と同じ) でない名前。変数名と ~/.config/pjp/env の行が壊れる
      badNames = builtins.filter (n: builtins.match "[a-z0-9][a-z0-9_-]*" n == null) names;
      # 同じ変数になる名前の組 (my-ws と my_ws)。~/.config/pjp/env の 1 行を 2 つのプロファイルで取り合う
      sameVar = lib.filterAttrs (_: ns: builtins.length ns > 1) (lib.groupBy var names);
      # item が、欄まで書いた 1Password の参照 (op://<vault>/<項目>/<欄>、セクションがあれば op://<vault>/<項目>/<セクション>/<欄>。
      # op read にそのまま渡せる形) でない名前。区切りの間は / と制御文字 (改行・タブ) の外 (名前の参照の空白は通す)。形を型 (strMatching) で確かめないのは、型の誤りの文が定義の値を
      # そのまま出すため (値 (ntn_…) を書いてしまったときに、評価の誤りの文から端末や CI のログへ値が出る)
      badItems = builtins.filter (
        n:
        let
          item = tokens.${n}.item or null;
        in
        item != null
        && !(
          builtins.isString item
          && builtins.match "op://[^/[:cntrl:]]+/[^/[:cntrl:]]+/[^/[:cntrl:]]+(/[^/[:cntrl:]]+)?" item != null
        )
      ) names;
    in
    [
      {
        assertion = badNames == [ ];
        message = ''
          claude.nix: dotfiles.claude.notion.tokens のキー (プロファイルの名前) が profiles.toml の名前の形ではありません:
          ${lib.concatMapStringsSep " " builtins.toJSON badNames}
          英小文字か数字で始め、英小文字・数字・- と _ だけにしてください (変数名 PJP_NOTION_TOKEN_<名前> を作るため)。
        '';
      }
      {
        assertion = sameVar == { };
        message = ''
          claude.nix: dotfiles.claude.notion.tokens の次の名前は、同じ変数になります (- は _ に読み替える):
          ${lib.concatStringsSep "; " (
            lib.mapAttrsToList (v: ns: "${lib.concatStringsSep "・" ns} → ${v}") sameVar
          )}
          どれか 1 つにしてください。
        '';
      }
      # 文には書いた字を出さない (値を書いてしまったとき、端末や CI のログへ出ないように)。名前だけを出す
      {
        assertion = badItems == [ ];
        message = ''
          claude.nix: ${
            lib.concatMapStringsSep "・" (n: "dotfiles.claude.notion.tokens.${n}.item") badItems
          } が、欄まで書いた 1Password の参照 (op://<vault の ID>/<項目の ID>/<欄の ID>。セクションがあれば
          op://<vault>/<項目>/<セクション>/<欄>) の形ではありません (書いた字は出しません)。
          pjp-op-ref が出す ID の形の参照を書くか、分かるまで null にしてください。token の値そのものを書いたのなら、その行を消して、token を作り直してください
          (commit した値は履歴に残ります)。
        '';
      }
    ];
}
