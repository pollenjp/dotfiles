# nix/lib/release-age.nix (nixpkgs の猶予の例外を、home の pkgs に当てる overlay と消し時の警告にする lib) を、偽の
# inputs と偽の upstream の package (fixtures/release-age/upstream) で、評価時に確かめる。
#
# 合わなければ assert で評価が止まり、外れた項目の名前が出る。評価で止まるので、
# CI の `nix flake check --all-systems --no-build` (全 system の評価) でも落ちる。
# flake.nix の checks (release-age-state) から呼ぶ。
#
# ## 確かめること
#
#   - 例外が無ければ overlay も警告も無く、猶予の既定は 7 日。このとき input の nixpkgs-exceptions を読まない
#   - 日付は Asia/Tokyo の日の終わりで読む: 全体の例外の date = 2026-10-23 は、普段の pin の commit が
#     2026-10-23 14:59:59 UTC までなら効いていて、15:00:00 UTC からは「もう何もしていない」の警告になる
#   - 一部 (nixpkgs から): 例外の pin が普段の pin より新しく、普段の pin が date を越えていなければ、package を例外の
#     pin から取る。例外の pin が新しくなければ「まだ何もしていない」、普段の pin が date を越えたら「もう何もしていない」
#     の警告 (このとき nixpkgs-exceptions を読まない)
#   - 一部 (upstream から): nixpkgs の版が version より古ければ upstream の package に差し替える。nixpkgs の版が
#     version 以上なら「もう何もしていない」の警告 (nixpkgs の版を出す)、その system の配布物が無ければその旨の警告
#   - 一部 (upstream から) の package は、overlay を当てた先の pkgs で組む: unfree の package は、当てた先の pkgs の
#     config が許せば (home-manager が home の nixpkgs.config で import し直した pkgs と同じ形) 評価でき、許さなければ止まる
#   - 警告はどれも「nixpkgs の例外」で始まる (CI がこの文だけを落とさずに annotation にする)
#   - 書き誤りは評価で止まる: 知らない欄 (上の段と項目)・暦に無い日付・空の reason・負の日数・入れ子の名前・pkgs に
#     無い名前・一部の例外に同じ package が 2 回・upstream の package のファイルが無い・その版と version が違う
#   - 差し替えた package を使っているほかの package は、例外の有無で home.packages の drvPath を比べると見つかる
#     (hello を差し替えると、hello を呼ぶ uses-hello が見つかり、jq は見つからない)
#   - 実の設定 (nix/release-age.nix) で: 設定が評価でき、差し替えた名前は home の pkgs で overlay の package になり、
#     home.packages のほかの package はそれを使っていない (一部の例外は、ほかの package から使われないアプリだけ)。
#     home の warnings の「nixpkgs の例外」の文は lib が出したものと同じ
#   - 消し時の警告が出ていても、warnings を見るほかの check (local-flake-tmp-state) は落ちない (CI は落とさない)
{
  lib,
  pkgs,
  system,
  # flake の inputs・mkHome・releaseAge (lib/release-age.nix を flake の inputs で呼んだもの)
  inputs,
  mkHome,
  releaseAge,
}:

let
  upstreamDir = ./fixtures/release-age/upstream;
  pkgsX = {
    hello = pkgs.writeText "hello-from-exceptions" "";
  };
  # 普段の pin (main) と例外の pin (x) の commit の日時 (UTC の YYYYMMDDHHMMSS)
  fake =
    {
      main,
      x ? main,
    }:
    {
      nixpkgs = {
        lastModifiedDate = main;
        legacyPackages.${system} = pkgs;
      };
      nixpkgs-exceptions = {
        lastModifiedDate = x;
        legacyPackages.${system} = pkgsX;
      };
    };
  # nixpkgs-exceptions を読んだら評価が止まる
  untouched = main: {
    nixpkgs = {
      lastModifiedDate = main;
      legacyPackages.${system} = pkgs;
    };
    nixpkgs-exceptions = throw "nixpkgs-exceptions を読んだ";
  };
  run =
    inputs: settings:
    import ../lib/release-age.nix {
      inherit
        lib
        inputs
        settings
        upstreamDir
        ;
    } system;
  # 評価で止まるか
  rejects = r: !(builtins.tryEval (builtins.deepSeq (r.replaced ++ r.warnings) true)).success;
  # 1 つだけの警告が、すべての断片を含むか
  warnsOnce =
    r: parts:
    builtins.length r.warnings == 1
    && builtins.all (p: lib.hasInfix p (builtins.head r.warnings)) parts;
  # overlay を当てた pkgs
  applied = r: pkgs.appendOverlays r.overlays;

  allItem = {
    date = "2026-10-23";
    reason = "全体の理由";
  };
  nixpkgsItem = {
    packages = [ "hello" ];
    date = "2026-10-23";
    reason = "一部 nixpkgs の理由";
  };
  upstreamItem = package: version: {
    inherit package version;
    reason = "一部 upstream の理由";
  };

  none = run (untouched "20261023000000") { };
  allBefore = run (untouched "20261023145959") { exceptions.all = [ allItem ]; };
  allAfter = run (untouched "20261023150000") { exceptions.all = [ allItem ]; };
  nixpkgsOn = run (fake {
    main = "20261020000000";
    x = "20261022000000";
  }) { exceptions.fromNixpkgs = [ nixpkgsItem ]; };
  nixpkgsPending = run (fake { main = "20261020000000"; }) {
    exceptions.fromNixpkgs = [ nixpkgsItem ];
  };
  nixpkgsPassed = run (untouched "20261024000000") { exceptions.fromNixpkgs = [ nixpkgsItem ]; };
  upstreamOn = run (untouched "20261020000000") {
    exceptions.fromUpstream = [ (upstreamItem "hello" "99.0") ];
  };
  upstreamPassed = run (untouched "20261020000000") {
    exceptions.fromUpstream = [ (upstreamItem "jq" "1.0") ];
  };
  upstreamNoAsset = run (untouched "20261020000000") {
    exceptions.fromUpstream = [ (upstreamItem "tree" "99.0") ];
  };
  upstreamUnfree = run (untouched "20261020000000") {
    exceptions.fromUpstream = [ (upstreamItem "cowsay" "99.0") ];
  };
  # overlay を、names の unfree を許す config で import し直した nixpkgs に当てる (home-manager が home の
  # nixpkgs.config と pkgs.overlays で nixpkgs を import し直すのと同じ形)
  appliedAllowing =
    names: r:
    import pkgs.path {
      inherit system;
      config.allowUnfreePackages = names;
      inherit (r) overlays;
    };

  # 書き誤りのケースは、どれも評価が先へ進む pin で流す
  bad =
    settings:
    rejects (
      run (fake {
        main = "20261020000000";
        x = "20261022000000";
      }) settings
    );

  # 同じ添字どうしで比べ、差し替えた名前でないのに drvPath が違う package (差し替えたものを使っている) の名前
  usedBy =
    replaced: withList: withoutList:
    if builtins.length withList != builtins.length withoutList then
      [ "(home.packages の数が違う)" ]
    else
      map (p: lib.getName p.fst) (
        builtins.filter (
          p: !(builtins.elem (lib.getName p.fst) replaced) && p.fst.drvPath != p.snd.drvPath
        ) (lib.zipLists withList withoutList)
      );
  sample = p: [
    p.hello
    (p.writeShellScriptBin "uses-hello" "${p.hello}/bin/hello")
    p.jq
  ];
  helloReplaced = pkgs.appendOverlays [
    # 版を変えると src を変えていない警告が出るので、install の後に何もしない 1 行を足して drv だけを変える
    (_: prev: {
      hello = prev.hello.overrideAttrs (old: {
        postInstall = (old.postInstall or "") + "\n: release-age-state";
      });
    })
  ];

  # 実の設定と home。例外を当てない home は、mk-home.nix に何もしない releaseAge を渡して組む
  real = releaseAge system;
  home = mkHome {
    username = "tester";
    inherit system;
  };
  homeWithout =
    import ../lib/mk-home.nix
      {
        inherit inputs;
        releaseAge = _: {
          settings = { };
          replaced = [ ];
          overlays = [ ];
          warnings = [ ];
        };
      }
      {
        username = "tester";
        inherit system;
      };
  used = usedBy real.replaced home.config.home.packages homeWithout.config.home.packages;

  # 消し時の警告が出ている home。warnings を空と決め打ちする check が無いかを見る
  mkHomeExpired = import ../lib/mk-home.nix {
    inherit inputs;
    releaseAge = _: {
      settings = { };
      replaced = [ ];
      overlays = [ ];
      warnings = [ "nixpkgs の例外 (全体) 2026-09-01 は、もう何もしていない (release-age-state の作り物)" ];
    };
  };

  cases = [
    {
      name = "例外が無ければ overlay も警告も無く、猶予は既定の 7 日 (nixpkgs-exceptions を読まない)";
      ok =
        none.replaced == [ ]
        && none.overlays == [ ]
        && none.warnings == [ ]
        && none.settings.minimumReleaseAgeDays == 7;
    }
    {
      name = "minimumReleaseAgeDays を書けばその値になる";
      ok =
        (run (untouched "20261023000000") { minimumReleaseAgeDays = 10; }).settings.minimumReleaseAgeDays
        == 10;
    }
    {
      name = "全体: 普段の pin の commit が date の日の 14:59:59 UTC (23:59:59 JST) までなら警告は無い";
      ok = allBefore.warnings == [ ] && allBefore.replaced == [ ];
    }
    {
      name = "全体: 普段の pin の commit が date の日の 15:00:00 UTC からは、exceptions.all から消すよう警告する";
      ok = warnsOnce allAfter [
        "もう何もしていない"
        "exceptions.all"
        "2026-10-23"
        "全体の理由"
      ];
    }
    {
      name = "一部 (nixpkgs から): 例外の pin が新しく date を越えていなければ、package を例外の pin から取る";
      ok =
        nixpkgsOn.replaced == [ "hello" ]
        && nixpkgsOn.warnings == [ ]
        && (applied nixpkgsOn).hello.name == "hello-from-exceptions";
    }
    {
      name = "一部 (nixpkgs から): 例外の pin が普段の pin より新しくなければ「まだ何もしていない」";
      ok =
        nixpkgsPending.replaced == [ ]
        && warnsOnce nixpkgsPending [
          "まだ何もしていない"
          "flake-lock-age.sh"
          "hello"
        ];
    }
    {
      name = "一部 (nixpkgs から): 普段の pin が date を越えたら「もう何もしていない」(nixpkgs-exceptions を読まない)";
      ok =
        nixpkgsPassed.replaced == [ ]
        && warnsOnce nixpkgsPassed [
          "もう何もしていない"
          "exceptions.fromNixpkgs"
          "一部 nixpkgs の理由"
        ];
    }
    {
      name = "一部 (upstream から): nixpkgs の版が古ければ upstream の package に差し替える";
      ok =
        upstreamOn.replaced == [ "hello" ]
        && upstreamOn.warnings == [ ]
        && (applied upstreamOn).hello.version == "99.0";
    }
    {
      name = "一部 (upstream から): nixpkgs の版が version 以上なら、その版を添えて「もう何もしていない」";
      ok =
        upstreamPassed.replaced == [ ]
        && warnsOnce upstreamPassed [
          "もう何もしていない"
          "exceptions.fromUpstream"
          pkgs.jq.version
          "一部 upstream の理由"
        ];
    }
    {
      name = "一部 (upstream から): その system の配布物が無ければ、system の名前を添えて nixpkgs のまま";
      ok =
        upstreamNoAsset.replaced == [ ]
        && warnsOnce upstreamNoAsset [
          "配布物が無い"
          system
        ];
    }
    {
      name = "一部 (upstream から): unfree の package は、当てた先の pkgs の config が許せば評価でき、許さなければ止まる";
      ok =
        upstreamUnfree.replaced == [ "cowsay" ]
        && upstreamUnfree.warnings == [ ]
        && (appliedAllowing [ "cowsay" ] upstreamUnfree).cowsay.version == "99.0"
        && (builtins.tryEval (appliedAllowing [ "cowsay" ] upstreamUnfree).cowsay.drvPath).success
        && !(builtins.tryEval (applied upstreamUnfree).cowsay.drvPath).success;
    }
    {
      name = "警告はどれも「nixpkgs の例外」で始まる";
      ok = builtins.all (lib.hasPrefix "nixpkgs の例外") (
        allAfter.warnings
        ++ nixpkgsPending.warnings
        ++ nixpkgsPassed.warnings
        ++ upstreamPassed.warnings
        ++ upstreamNoAsset.warnings
      );
    }
    {
      name = "知らない欄は評価で止まる (上の段の foo・全体の項目の until)";
      ok =
        bad { foo = 1; }
        && bad {
          exceptions.all = [ (allItem // { until = "2026-10-30"; }) ];
        };
    }
    {
      name = "暦に無い日付 (2026-02-30)・空の reason・負の日数は評価で止まる";
      ok =
        bad { exceptions.all = [ (allItem // { date = "2026-02-30"; }) ]; }
        && bad { exceptions.all = [ (allItem // { reason = ""; }) ]; }
        && bad { minimumReleaseAgeDays = -1; };
    }
    {
      name = "一部の例外に、入れ子の名前 (python3Packages.certifi) と pkgs に無い名前は書けない";
      ok =
        bad { exceptions.fromNixpkgs = [ (nixpkgsItem // { packages = [ "python3Packages.certifi" ]; }) ]; }
        && bad { exceptions.fromNixpkgs = [ (nixpkgsItem // { packages = [ "no-such-package-xyz" ]; }) ]; };
    }
    {
      name = "同じ package を一部の例外に 2 回は書けない (fromNixpkgs と fromUpstream の両方)";
      ok = bad {
        exceptions = {
          fromNixpkgs = [ nixpkgsItem ];
          fromUpstream = [ (upstreamItem "hello" "99.0") ];
        };
      };
    }
    {
      name = "upstream の package のファイルが無い (jo)・その版と version が違う (98.0) と評価で止まる";
      ok =
        bad { exceptions.fromUpstream = [ (upstreamItem "jo" "1.9") ]; }
        && bad { exceptions.fromUpstream = [ (upstreamItem "hello" "98.0") ]; };
    }
    {
      name = "差し替えた package (hello) を使っている package (uses-hello) は見つかり、使っていない jq は見つからない";
      ok = usedBy [ "hello" ] (sample helloReplaced) (sample pkgs) == [ "uses-hello" ];
    }
    {
      name = "実の設定 (nix/release-age.nix) が評価できる";
      ok = builtins.isInt real.settings.minimumReleaseAgeDays;
    }
    {
      name = "実の設定で差し替えた名前 (${toString real.replaced}) は、home の pkgs で overlay の package になっている";
      ok = builtins.all (n: home.pkgs.${n}.drvPath != homeWithout.pkgs.${n}.drvPath) real.replaced;
    }
    {
      name =
        "実の設定で差し替えた package を、home.packages のほかの package は使っていない"
        + lib.optionalString (used != [ ]) " (使っている: ${lib.concatStringsSep ", " used})";
      ok = used == [ ];
    }
    {
      name = "消し時の警告が出ていても、warnings を見るほかの check (local-flake-tmp-state) は落ちない";
      ok =
        (builtins.tryEval
          (import ./local-flake-tmp.nix {
            inherit lib pkgs;
            mkHome = mkHomeExpired;
          }).drvPath
        ).success;
    }
    {
      name = "home の warnings の「nixpkgs の例外」の文は、lib が出したものと同じ";
      ok = builtins.filter (lib.hasPrefix "nixpkgs の例外") home.config.warnings == real.warnings;
    }
  ];

  failed = builtins.filter (c: !c.ok) cases;
in
assert lib.assertMsg (failed == [ ])
  "release-age-state: 合わない項目: ${lib.concatMapStringsSep " / " (c: c.name) failed}";
pkgs.runCommand "release-age-state" { } ''
  echo ${lib.escapeShellArg (lib.concatMapStringsSep "\n" (c: "ok   ${c.name}") cases)}
  touch $out
''
