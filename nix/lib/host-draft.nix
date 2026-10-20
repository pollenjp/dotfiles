# dotfiles-private の nix/hosts/<user>@<hostname>.nix の下書きを描く (ADR 025)。nix/scripts/private-host.sh draft が、
# 元にするホスト (登録簿か手で足したホストに、ローカル flake の local が当たったもの) を評価して呼ぶ。
#
#   collect   元のホストの options.dotfiles から、既定でない定義を持つ option を [ { path; value; } ] で出す
#   render    それを、mkHome を受け取って呼ぶ関数 (private-hosts.nix が読む形) のファイルの本文にする
#
# 「既定でない定義」は、option の既定 (優先度 1500 の mkOptionDefault) より強い定義があること。mkHome の引数・
# 登録簿の modules・local のどこで書いたかは問わず、既定と同じ値を書いたもの (local の devTracker.enable = true
# など) も入る。既定が別の option から決まるもの (wsl.onePassword.windowsUserName) と、改名した旧名 (visible = false。
# 値は新しい名前の option に入る) は入らない。dotfiles の option の外 (programs.git など) は見ないので、local にそういう
# 行があれば private-host.sh draft が notes で知らせる。
{ lib }:

let
  # mkHome が dotfiles.<組> にそのまま入れる引数 (lib/mk-home.nix)。この順で描く
  argGroups = [
    "wsl"
    "onePassword"
    "claude"
  ];

  walk =
    path: v:
    if lib.isOption v then
      lib.optional ((v.visible or true) != false && v.isDefined && v.highestPrio < 1500) {
        inherit path;
        inherit (v) value;
      }
    else if builtins.isAttrs v then
      lib.concatMap (k: walk (path ++ [ k ]) v.${k}) (builtins.attrNames v)
    else
      [ ];

  dotted = lib.concatMapStringsSep "." lib.strings.escapeNixIdentifier;

  # Nix の字句にできる値か (関数・derivation・path は書き出さない)
  writable =
    v:
    v == null
    || builtins.isBool v
    || builtins.isInt v
    || builtins.isFloat v
    || builtins.isString v
    || (builtins.isList v && builtins.all writable v)
    || (builtins.isAttrs v && !lib.isDerivation v && builtins.all writable (builtins.attrValues v));

  # 値の字句。複数行になる値 (空でない attrset・list) の 2 行目からは indent で字下げする
  literal =
    indent: v:
    if v == null then
      "null"
    else if builtins.isBool v then
      lib.boolToString v
    else if builtins.isString v then
      lib.strings.escapeNixString v
    else if builtins.isList v then
      if v == [ ] then
        "[ ]"
      else
        "[\n" + lib.concatMapStrings (x: "${indent}  ${literal "${indent}  " x}\n") v + "${indent}]"
    else if builtins.isAttrs v then
      if v == { } then
        "{ }"
      else
        "{\n"
        + lib.concatMapStrings (
          k: "${indent}  ${lib.strings.escapeNixIdentifier k} = ${literal "${indent}  " v.${k}};\n"
        ) (builtins.attrNames v)
        + "${indent}}"
    else
      toString v;

  # 1 つの値の行。字句にできない値は TODO のコメントにする。full は dotfiles. からの path (TODO の行に書く)
  line =
    indent: path: full: v:
    if writable v then
      "${indent}${dotted path} = ${literal indent v};"
    else
      "${indent}# TODO: dotfiles.${dotted full} は値を書き出せない (関数・derivation・path)。要るなら手で書く";
in
{
  collect =
    options:
    lib.sort (a: b: lib.concatStringsSep "." a.path < lib.concatStringsSep "." b.path) (
      walk [ ] options
    );

  render =
    {
      name,
      username,
      system,
      homeDirectory ? null,
      base ? null,
      values,
      notes ? [ ],
    }:
    let
      inGroup = g: builtins.filter (v: builtins.head v.path == g) values;
      others = builtins.filter (v: !(builtins.elem (builtins.head v.path) argGroups)) values;
      groupLines =
        g:
        let
          vs = inGroup g;
        in
        if vs == [ ] then
          [ ]
        else if builtins.length vs == 1 then
          map (v: line "  " v.path v.path v.value) vs
        else
          [ "  ${lib.strings.escapeNixIdentifier g} = {" ]
          ++ map (v: line "    " (builtins.tail v.path) v.path v.value) vs
          ++ [ "  };" ];
      moduleLines = lib.optionals (others != [ ]) (
        [
          "  modules = ["
          "    {"
        ]
        ++ map (v: line "      " ([ "dotfiles" ] ++ v.path) v.path v.value) others
        ++ [
          "    }"
          "  ];"
        ]
      );
    in
    lib.concatMapStrings (l: l + "\n") (
      [
        "# この PC (${name}) のホストの定義と値の全部 (dotfiles の ADR 025)。ホストの名前はファイル名から .nix を除いたもの。"
        "# ローカル flake (~/dotfiles/flake.nix) の local はこのホストには当たらない。値を変えるときはこのファイルを直す。"
      ]
      ++ lib.optional (
        base != null
      ) "# 下書きは dotfiles の nix/scripts/private-host.sh draft が描いた (元にしたホスト: ${base} とローカル flake の local)。"
      ++ map (n: "# ${n}") notes
      ++ [
        "{ mkHome, ... }:"
        "mkHome {"
        "  username = ${lib.strings.escapeNixString username};"
        "  system = ${lib.strings.escapeNixString system};"
      ]
      ++ lib.optional (
        homeDirectory != null
      ) "  homeDirectory = ${lib.strings.escapeNixString homeDirectory};"
      ++ lib.concatMap groupLines argGroups
      ++ moduleLines
      ++ [ "}" ]
    );
}
