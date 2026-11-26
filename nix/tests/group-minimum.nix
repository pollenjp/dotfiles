# minimum のグループの作り物のホスト (lib/group-examples.nix の minimum と minimum-claude) に、minimum に入らない道具のものが
# 入らないことを、評価時に確かめる (dotfiles-private の docs/adr/109_host_groups_minimum_all_*。前は客先のグループの確かめ。ADR 057)。
#
# 合わなければ assert で評価が止まり、外れた項目の名前が出る。flake.nix の checks (group-minimum-state。x86_64-linux) から呼ぶ。
# minimum の build は別の check (home-group-minimum-example) が見る。
#
# ## 確かめること
#
#   - minimum に minimum の外の道具のものが無い: ~/.claude/ の下・Claude Code 向けの state (.local/state/dotfiles/claude-*.json。1Password の
#     道具も読む claude-op-reason.json を除く)・ntn.json・herdr の設定・~/.ssh/rc が無い。cc-pages の port を選んだ minimum のホストにも
#     cc-pages の config.toml と unit が無い。package に herdr・ntn・herdr-core・pjp-agent-link・claude-account (claude-personal・claude-work を
#     含む) が無い。systemd の user unit に cc-pages・pjp-agent-link-watch が無い。fish の abbr と bash の alias に h・hr・c が無い。ssh の
#     設定に PJP_SSH_CLIENT が無い。git の設定に名前とメール (settings.user) と pollenjp-sub の includes が無い
#   - minimum の group.json で on の道具は minimum に入る道具だけ、windows-files.json の claudeCode・ntn が false (win/ は配る)
#   - minimum に入る package の名前・home.file の置き先・systemd の user unit の名前が、fixture
#     (tests/fixtures/group-minimum/*.txt) と同じ。新しい道具を switch で止め忘れると、どの PC にも入り、ここで違いとして出る
#     (minimum に入れるかの決め忘れの見張り)。minimum に入れる道具なら fixture に足し、入れないなら switch で止める
#   - minimum-claude (minimum に Claude Code だけを足したホスト) には ~/.claude/CLAUDE.md と claude-account (claude-personal) があり、herdr の
#     skill・herdr・cc-pages・ntn・claude-skills の手順 (group.json の claudePrivateSkills) は入らない
{
  lib,
  pkgs,
  mkHome,
}:

let
  examples = import ../lib/group-examples.nix { inherit mkHome; };
  minimum = examples.minimum.config;
  minimumClaude = examples.minimum-claude.config;
  # cc-pages の port を選んだ minimum のホスト (port を選ぶと、cc-pages を入れるホストなら config.toml が置かれる)
  minimumPort =
    (mkHome {
      username = "user";
      system = "x86_64-linux";
      group = "minimum";
      modules = [ { dotfiles.ccPages.port = 7801; } ];
    }).config;

  sorted = l: lib.sort (a: b: a < b) (lib.unique l);
  rel = cfg: t: lib.removePrefix (cfg.home.homeDirectory + "/") t;
  packages = cfg: sorted (map lib.getName cfg.home.packages);
  files = cfg: sorted (map (f: rel cfg f.target) (builtins.attrValues cfg.home.file));
  units =
    cfg:
    sorted (
      lib.concatMap
        (k: map (n: "${n}.${lib.removeSuffix "s" k}") (builtins.attrNames cfg.systemd.user.${k}))
        [
          "services"
          "paths"
          "timers"
          "sockets"
        ]
    );

  # fixture の行 (# で始まる行と空行は読まない)
  fixture =
    name:
    builtins.filter (l: l != "" && !(lib.hasPrefix "#" l)) (
      lib.splitString "\n" (builtins.readFile (./fixtures/group-minimum + "/${name}.txt"))
    );
  # 違いを「足された: …・無くなった: …」の 1 文にする (同じなら "")
  diffOf =
    want: got:
    let
      added = builtins.filter (x: !(builtins.elem x want)) got;
      removed = builtins.filter (x: !(builtins.elem x got)) want;
    in
    lib.concatStringsSep "・" (
      lib.optional (added != [ ]) "fixture に無い: ${lib.concatStringsSep " " added}"
      ++ lib.optional (removed != [ ]) "fixture にあって無い: ${lib.concatStringsSep " " removed}"
    );
  snapshot =
    name: got:
    let
      d = diffOf (fixture name) got;
    in
    {
      name =
        "${name} が fixture (tests/fixtures/group-minimum/${name}.txt) と同じ"
        + lib.optionalString (d != "") " (${d})";
      ok = d == "";
    };

  hasFile = cfg: t: builtins.elem t (files cfg);
  hasPackage = cfg: n: builtins.elem n (packages cfg);
  hasUnit = cfg: n: builtins.elem n (units cfg);
  claudeStates =
    cfg:
    builtins.filter (
      t:
      lib.hasPrefix ".local/state/dotfiles/claude-" t
      && t != ".local/state/dotfiles/claude-op-reason.json"
    ) (files cfg);

  groupJson = cfg: builtins.fromJSON cfg.home.file.".local/state/dotfiles/group.json".text;
  windowsJson = cfg: builtins.fromJSON cfg.home.file.".local/state/dotfiles/windows-files.json".text;
  groups = import ../lib/groups.nix;
  onKeys =
    cfg: lib.sort (a: b: a < b) (lib.attrNames (lib.filterAttrs (_: v: v) (groupJson cfg).tools));
  minimumKeys = lib.sort (a: b: a < b) (map (t: t.key) (builtins.filter (t: t.minimum) groups.tools));

  noneOf = what: xs: {
    name = "minimum に ${what} が無い";
    ok = xs == [ ];
  };

  cases = [
    (noneOf "~/.claude/ の下のファイル" (builtins.filter (lib.hasPrefix ".claude/") (files minimum)))
    (noneOf "Claude Code 向けの state (claude-op-reason.json を除く)" (claudeStates minimum))
    (noneOf "ntn.json・herdr の設定・~/.ssh/rc" (
      builtins.filter (hasFile minimum) [
        ".local/state/dotfiles/ntn.json"
        ".config/herdr/config.toml"
        ".ssh/rc"
      ]
    ))
    {
      name = "cc-pages の port を選んだ minimum のホストにも、cc-pages の config.toml と unit が無い";
      ok =
        !(hasFile minimumPort ".config/cc-pages/config.toml") && !(hasUnit minimumPort "cc-pages.service");
    }
    (noneOf "minimum の外の package (herdr・ntn・herdr-core・pjp-agent-link・claude-account)" (
      builtins.filter (hasPackage minimum) [
        "herdr"
        "ntn"
        "herdr-core"
        "pjp-agent-link"
        "claude-account"
      ]
    ))
    (noneOf "cc-pages・pjp-agent-link-watch の unit" (
      builtins.filter (hasUnit minimum) [
        "cc-pages.service"
        "pjp-agent-link-watch.service"
        "pjp-agent-link-watch.path"
      ]
    ))
    (noneOf "fish の abbr・bash の alias の h・hr・c" (
      builtins.filter
        (n: minimum.programs.fish.shellAbbrs ? ${n} || minimum.programs.bash.shellAliases ? ${n})
        [
          "h"
          "hr"
          "c"
        ]
    ))
    {
      name = "minimum の ssh の設定に PJP_SSH_CLIENT が無い";
      ok =
        !(lib.hasInfix "PJP_SSH_CLIENT" (toString (minimum.home.file.".ssh/config".text or "")))
        && !(minimum.programs.ssh.settings ? "*");
    }
    {
      name = "minimum の git の設定に名前とメールと pollenjp-sub の includes が無い";
      ok = !(minimum.programs.git.settings ? user) && minimum.programs.git.includes == [ ];
    }
    {
      name = "minimum の group.json で on の道具は minimum に入る道具だけ";
      ok = onKeys minimum == minimumKeys;
    }
    {
      name = "minimum の windows-files.json は win/ を配り、claudeCode・ntn が false";
      ok =
        let
          w = windowsJson minimum;
        in
        w.enable && !w.claudeCode && !w.ntn;
    }
    (snapshot "packages" (packages minimum))
    (snapshot "files" (files minimum))
    (snapshot "units" (units minimum))
    {
      name = "minimum-claude には ~/.claude/CLAUDE.md と claude-account (claude-personal) がある";
      ok = hasFile minimumClaude ".claude/CLAUDE.md" && hasPackage minimumClaude "claude-account";
    }
    {
      name = "minimum-claude に herdr の skill・herdr・cc-pages・ntn・claude-skills の手順は入らない";
      ok =
        !(hasFile minimumClaude ".claude/skills/herdr")
        && !(hasPackage minimumClaude "herdr")
        && !(hasUnit minimumClaude "cc-pages.service")
        && !(hasPackage minimumClaude "ntn")
        && (groupJson minimumClaude).tools.claudePrivateSkills == false;
    }
  ];

  failed = builtins.filter (c: !c.ok) cases;
in
assert lib.assertMsg (failed == [ ])
  "group-minimum-state: 合わない項目: ${lib.concatMapStringsSep " / " (c: c.name) failed}";
pkgs.runCommand "group-minimum-state" { } ''
  echo ${lib.escapeShellArg (lib.concatMapStringsSep "\n" (c: "ok   ${c.name}") cases)}
  touch $out
''
