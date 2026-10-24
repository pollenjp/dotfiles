# nixpkgs の猶予の例外 (nix/release-age.nix の exceptions) を、system ごとの overlay と消し時の警告にする (ADR 032)。
# lib/mk-home.nix が home の pkgs に overlay を当て、警告を home-manager の warnings に出す (setup は switch の後に
# 警告のまとめへ写し、CI の check ジョブは落とさずに annotation にする)。
#
# 例外が何もしなくなったか (消し時) は、今日の日付ではなく pin の日時と package の版で決める (home-manager の評価は
# pure で今日の日付を読めない)。date は Asia/Tokyo の日の終わりで読む。
#
#   全体・一部 (nixpkgs から)  普段の pin (input の nixpkgs) の commit の日時が、date の日の終わりを越えた
#   一部 (upstream から)       普段の pin の nixpkgs のその package の版が、version 以上になった
#
# 全体の例外は flake-lock-age.sh が flake.lock の pin を動かすだけなので、ここは消し時の警告だけを出す。
# input の nixpkgs-exceptions は、消し時を過ぎていない一部 (nixpkgs から) の項目があるときだけ読む (読まなければ
# 取ってこない)。
{
  lib,
  # flake の inputs。nixpkgs と nixpkgs-exceptions の lastModifiedDate (commit の日時。UTC の YYYYMMDDHHMMSS) と
  # legacyPackages.<system> だけを読む
  inputs,
  settings ? import ../release-age.nix,
  # 一部 (upstream から) の package の置き場所。<package>.nix を、普段の pin の pkgs の callPackage で呼ぶ
  upstreamDir ? ../pkgs/upstream,
}:

let
  inherit (lib) mkOption types;
  calendarDate = import ./calendar-date.nix { inherit lib; };

  item =
    options:
    types.submodule {
      options = options // {
        reason = mkOption {
          type = types.nonEmptyStr;
          description = "なぜ要るか (CVE・待っている nixpkgs の PR)";
        };
      };
    };
  date = mkOption {
    type = calendarDate;
    description = "この日 (Asia/Tokyo) の終わりまでの公開を使う";
  };

  # 欄の型と必須の欄を確かめる。知らない欄・型の誤りは、値を読んだときに throw になる
  cfg =
    (lib.evalModules {
      modules = [
        {
          options = {
            minimumReleaseAgeDays = mkOption {
              type = types.ints.unsigned;
              default = 7;
            };
            exceptions = {
              all = mkOption {
                type = types.listOf (item {
                  inherit date;
                });
                default = [ ];
              };
              fromNixpkgs = mkOption {
                type = types.listOf (item {
                  packages = mkOption { type = types.nonEmptyListOf types.nonEmptyStr; };
                  inherit date;
                });
                default = [ ];
              };
              fromUpstream = mkOption {
                type = types.listOf (item {
                  package = mkOption { type = types.nonEmptyStr; };
                  version = mkOption { type = types.nonEmptyStr; };
                });
                default = [ ];
              };
            };
          };
        }
        {
          _file = "nix/release-age.nix";
          config = settings;
        }
      ];
    }).config;
  inherit (cfg) exceptions;
in
system:
let
  pkgs = inputs.nixpkgs.legacyPackages.${system};

  # date の日 (Asia/Tokyo) の終わりを lastModifiedDate の形で (その日の 14:59:59 UTC)。同じ桁数の数字の文字列なので
  # 大小は文字列で比べられる
  endOfDay = d: lib.replaceStrings [ "-" ] [ "" ] d + "145959";
  mainDate = inputs.nixpkgs.lastModifiedDate;
  # 普段の pin が date の日を越えた (例外は何もしない)
  passed = d: mainDate > endOfDay d;
  showDate =
    s:
    "${builtins.substring 0 4 s}-${builtins.substring 4 2 s}-${builtins.substring 6 2 s} "
    + "${builtins.substring 8 2 s}:${builtins.substring 10 2 s} UTC";
  pinPassed = "普段の pin の commit が ${showDate mainDate} で、その日を越えた";
  head = kind: "nixpkgs の例外 (${kind})";

  # 一部 (upstream から)。ファイルと版は下の problems で確かめてから使う
  upstream = map (
    i:
    let
      file = upstreamDir + "/${i.package}.nix";
      drv = pkgs.callPackage file { };
      nixVersion = lib.getVersion pkgs.${i.package};
    in
    {
      inherit i drv nixVersion;
      exists = builtins.pathExists file;
      newer = lib.versionOlder nixVersion i.version;
      available = lib.meta.availableOn pkgs.stdenv.hostPlatform drv;
    }
  ) exceptions.fromUpstream;

  # 型では見られない書き誤り
  partialNames =
    lib.concatMap (i: i.packages) exceptions.fromNixpkgs ++ map (i: i.package) exceptions.fromUpstream;
  nested = builtins.filter (lib.hasInfix ".") partialNames;
  problems =
    map (n: "${n}: 入れ子の名前は書けない (top-level の pkgs.<名前> だけ。ライブラリは exceptions.all で扱う)") nested
    ++ map (n: "${n}: nixpkgs に無い名前") (
      builtins.filter (n: !(lib.hasInfix "." n) && !(pkgs ? ${n})) partialNames
    )
    ++ map (n: "${n}: 一部の例外に 2 回書いてある") (
      lib.unique (builtins.filter (n: lib.count (m: m == n) partialNames > 1) partialNames)
    )
    ++ lib.concatMap (
      u:
      if !u.exists then
        [ "${u.i.package}: nix/pkgs/upstream/${u.i.package}.nix が無い" ]
      else
        lib.optional (u.drv.version != u.i.version)
          "${u.i.package}: nix/pkgs/upstream/${u.i.package}.nix の版 ${u.drv.version} と version ${u.i.version} が違う"
    ) (builtins.filter (u: !(builtins.elem u.i.package nested)) upstream);

  # 全体: pin は flake-lock-age.sh が動かすので、ここは消し時だけ
  allWarnings = map (
    i:
    "${head "全体"} ${i.date} は、もう何もしていない (${pinPassed})。"
    + "nix/release-age.nix の exceptions.all から消すこと。理由: ${i.reason}"
  ) (builtins.filter (i: passed i.date) exceptions.all);

  # 一部 (nixpkgs から)
  names = i: lib.concatStringsSep "・" i.packages;
  nixpkgsLive = builtins.filter (i: !passed i.date) exceptions.fromNixpkgs;
  # 例外の pin が普段の pin より新しいか。消し時を過ぎていない項目があるときだけ nixpkgs-exceptions を読む
  exceptionsNewer = nixpkgsLive != [ ] && inputs.nixpkgs-exceptions.lastModifiedDate > mainDate;
  pkgsX = inputs.nixpkgs-exceptions.legacyPackages.${system};
  nixpkgsReplaced = lib.optionals exceptionsNewer (lib.concatMap (i: i.packages) nixpkgsLive);
  nixpkgsWarnings =
    map (
      i:
      "${head "一部・nixpkgs から"} ${names i} の ${i.date} は、もう何もしていない (${pinPassed})。"
      + "nix/release-age.nix の exceptions.fromNixpkgs から消すこと。理由: ${i.reason}"
    ) (builtins.filter (i: passed i.date) exceptions.fromNixpkgs)
    ++ lib.optionals (!exceptionsNewer) (
      map (
        i:
        "${head "一部・nixpkgs から"} ${names i} の ${i.date} は、まだ何もしていない "
        + "(input の nixpkgs-exceptions が普段の pin より新しくない)。nix/scripts/flake-lock-age.sh update で選び直すこと "
        + "(その日までの公開が普段の pin より新しくなければ、選び直しても変わらない)"
      ) nixpkgsLive
    );

  # 一部 (upstream から)
  upstreamOn = builtins.filter (u: u.newer && u.available) upstream;
  upstreamWarnings =
    map (
      u:
      "${head "一部・upstream から"} ${u.i.package} ${u.i.version} は、もう何もしていない "
      + "(普段の pin の nixpkgs の ${u.i.package} が ${u.nixVersion})。nix/release-age.nix の exceptions.fromUpstream と "
      + "nix/pkgs/upstream/${u.i.package}.nix を消すこと。理由: ${u.i.reason}"
    ) (builtins.filter (u: !u.newer) upstream)
    ++ map (
      u:
      "${head "一部・upstream から"} ${u.i.package} ${u.i.version} は、この system (${system}) の配布物が無いので "
      + "何もしていない (nixpkgs の ${u.i.package} ${u.nixVersion} のまま)"
    ) (builtins.filter (u: u.newer && !u.available) upstream);

  replaced = nixpkgsReplaced ++ map (u: u.i.package) upstreamOn;
  overlay =
    _final: _prev:
    lib.genAttrs nixpkgsReplaced (
      n: pkgsX.${n} or (throw "nixpkgs の例外: ${n} が input の nixpkgs-exceptions に無い")
    )
    // lib.listToAttrs (map (u: lib.nameValuePair u.i.package u.drv) upstreamOn);
in
# 型の誤りは値を読むまで出ないので、先に全部を読む
builtins.deepSeq cfg (
  if problems != [ ] then
    throw "nix/release-age.nix の一部の例外の書き誤り:\n${lib.concatMapStringsSep "\n" (p: "  - ${p}") problems}"
  else
    {
      # 型を確かめた設定 (minimumReleaseAgeDays・exceptions)
      settings = cfg;
      # overlay で差し替える top-level の名前
      inherit replaced;
      overlays = lib.optional (replaced != [ ]) overlay;
      # 消し時など。どれも「nixpkgs の例外」で始まる
      warnings = allWarnings ++ nixpkgsWarnings ++ upstreamWarnings;
    }
)
