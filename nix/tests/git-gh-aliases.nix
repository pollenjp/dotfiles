# home/options.nix の dotfiles.claude.gitViaGh.enable で変わる、fetch 系の fish の abbr・bash の alias と
# function を、評価時に確かめる。
#
# 合わなければ assert で評価が止まり、外れた項目の名前が出る。評価で止まるので、
# CI の `nix flake check --all-systems --no-build` (全 system の評価) でも落ちる。
# flake.nix の checks (git-gh-aliases-state) から呼ぶ。git gh そのものの振る舞いは git-gh.test.sh。
#
# ## 確かめること
#
#   - gfp-base は今までの gfp (git fetch --prune && git pull)、gfp-gh は git gh で同じことをする。
#     どちらも option によらず fish と bash にある
#   - gfp は true (既定) なら gfp-gh と、false なら gfp-base と同じ中身 (fish の abbr は展開した結果を
#     もう一度は展開しないので、名前ではなく中身を書く)
#   - fetch 系の gf・gpul・gpull・gcl は、true なら git gh を、false なら git を使う (fish と bash で同じ中身)
#   - fetch 系の function (default branch を引く・branch を fetch する・cleanup とその force 版・PR を fetch
#     する) は、true なら remote show・fetch・pull をすべて git gh で打ち、false なら git gh を使わない
#     (fish の function と bash の initExtra)
#   - push 系の gp・gpf は option によらず git のまま
#   - git-gh は option によらず home.packages に入る
{
  lib,
  pkgs,
  mkHome,
  system,
}:

let
  configWith =
    claude:
    (mkHome {
      username = "tester";
      inherit system claude;
    }).config;

  byDefault = configWith { };
  disabled = configWith { gitViaGh.enable = false; };

  gfpBase = "git fetch --prune && git pull";
  gfpGh = "git gh fetch --prune && git gh pull";

  # fish の abbr と bash の alias を、名前ごとに 1 組の値として並べる (無い名前は null。評価を止めずに外れにする)
  both = cfg: name: [
    (cfg.programs.fish.shellAbbrs.${name} or null)
    (cfg.programs.bash.shellAliases.${name} or null)
  ];
  bothAre =
    cfg: name: value:
    both cfg name == [
      value
      value
    ];

  # fetch 系の abbr / alias。git の後ろの部分
  fetchAliases = {
    gf = "fetch --prune";
    gpul = "pull";
    gpull = "pull";
    gcl = "clone --recurse-submodules";
  };
  fetchAliasesUse =
    git: cfg: lib.all (n: bothAre cfg n "${git} ${fetchAliases.${n}}") (lib.attrNames fetchAliases);

  # fetch 系の function。fish は function ごとの body、bash は initExtra (function をまとめて書いている)
  fishFns = cfg: cfg.programs.fish.functions;
  fetchFns = [
    "git_get_default_branch"
    "git_fetch_branch"
    "git_branch_cleanup"
    "git_branch_cleanup_force"
    "git_fetch_pull_request"
  ];
  fishFetchText = cfg: lib.concatMapStringsSep "\n" (n: (fishFns cfg).${n}.body) fetchFns;
  bashText = cfg: cfg.programs.bash.initExtra;

  # 素の git で通信する形 (true なら残っていてはいけない)
  bare = [
    "git remote show"
    "git fetch"
    "git pull"
  ];
  hasNoBare = text: !(lib.any (b: lib.hasInfix b text) bare);
  hasAll = text: lib.all (s: lib.hasInfix s text);

  hasGitGh = cfg: lib.any (p: lib.getName p == "git-gh") cfg.home.packages;

  cases = [
    {
      name = "gfp-base は今までの gfp の中身 (true / false とも、fish と bash)";
      ok = bothAre byDefault "gfp-base" gfpBase && bothAre disabled "gfp-base" gfpBase;
    }
    {
      name = "gfp-gh は git gh で fetch と pull をする (true / false とも、fish と bash)";
      ok = bothAre byDefault "gfp-gh" gfpGh && bothAre disabled "gfp-gh" gfpGh;
    }
    {
      name = "true (既定) の gfp は gfp-gh と同じ中身";
      ok = bothAre byDefault "gfp" gfpGh;
    }
    {
      name = "false の gfp は gfp-base と同じ中身";
      ok = bothAre disabled "gfp" gfpBase;
    }
    {
      name = "true の gf・gpul・gpull・gcl は git gh を使う";
      ok = fetchAliasesUse "git gh" byDefault;
    }
    {
      name = "false の gf・gpul・gpull・gcl は git を使う";
      ok = fetchAliasesUse "git" disabled;
    }
    {
      name = "true の fish の fetch 系の function は remote show・fetch・pull を git gh で打つ";
      ok =
        let
          f = fishFns byDefault;
        in
        hasNoBare (fishFetchText byDefault)
        && hasAll f.git_get_default_branch.body [ "git gh remote show origin" ]
        && hasAll f.git_fetch_branch.body [ "git gh fetch origin" ]
        && hasAll f.git_branch_cleanup.body [
          "git gh fetch --prune"
          "git gh pull"
        ]
        && hasAll f.git_branch_cleanup_force.body [
          "git gh fetch --prune"
          "git gh pull"
        ]
        && hasAll f.git_fetch_pull_request.body [ "git gh fetch origin" ];
    }
    {
      # git gh が止まったときの案内 (gh auth login・gfp-base) は stderr に出る。捨てると、呼んだ側
      # (git_fetch_base・git_branch_cleanup) が空の branch 名で進み、理由の分からない git のエラーだけが残る
      name = "fish の git_get_default_branch は stderr を捨てない (bash と同じ)";
      ok = !(lib.hasInfix "2>/dev/null" (fishFns byDefault).git_get_default_branch.body);
    }
    {
      name = "false の fish の fetch 系の function は git gh を使わない";
      ok =
        !(lib.hasInfix "git gh" (fishFetchText disabled))
        && hasAll (fishFetchText disabled) [
          "git remote show origin"
          "git fetch origin"
          "git fetch --prune"
          "git pull"
        ];
    }
    {
      name = "true の bash の fetch 系の function は remote show・fetch・pull を git gh で打つ";
      ok =
        hasNoBare (bashText byDefault)
        && hasAll (bashText byDefault) [
          "git gh remote show origin"
          "git gh fetch origin"
          "git gh fetch --prune"
          "git gh pull"
        ];
    }
    {
      name = "false の bash の fetch 系の function は git gh を使わない";
      ok =
        !(lib.hasInfix "git gh" (bashText disabled))
        && hasAll (bashText disabled) [
          "git remote show origin"
          "git fetch origin"
          "git fetch --prune"
          "git pull"
        ];
    }
    {
      name = "push 系の gp・gpf は true / false とも git のまま";
      ok = lib.all (cfg: bothAre cfg "gp" "git push" && bothAre cfg "gpf" "git push --force-with-lease") [
        byDefault
        disabled
      ];
    }
    {
      name = "git-gh は true / false とも home.packages に入る";
      ok = hasGitGh byDefault && hasGitGh disabled;
    }
  ];

  failed = builtins.filter (c: !c.ok) cases;
in
assert lib.assertMsg (failed == [ ])
  "git-gh-aliases-state: 合わない項目: ${lib.concatMapStringsSep " / " (c: c.name) failed}";
pkgs.runCommand "git-gh-aliases-state" { } ''
  echo ${lib.escapeShellArg (lib.concatMapStringsSep "\n" (c: "ok   ${c.name}") cases)}
  touch $out
''
