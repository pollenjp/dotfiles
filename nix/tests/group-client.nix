# 客先のグループの作り物のホスト (lib/group-examples.nix の client と client-claude) に、② AI の道具と ③ 個人のアカウントに
# つながるものが入らないことを、評価時に確かめる (dotfiles-private の docs/adr/057_host_setting_groups_*)。
#
# 合わなければ assert で評価が止まり、外れた項目の名前が出る。flake.nix の checks (group-client-state。x86_64-linux) から呼ぶ。
# client の build は別の check (home-group-client-example) が見る。
#
# ## 確かめること
#
#   - client に ② ③ のものが無い: ~/.claude/ の下・Claude Code 向けの state (.local/state/dotfiles/claude-*.json。1Password の
#     道具も読む claude-op-reason.json を除く)・ntn.json・herdr の設定・~/.ssh/rc・cc-pages の config.toml が無い。package に
#     herdr・ntn・herdr-core・pjp-agent-link・claude-personal・claude-work が無い。systemd の user unit に cc-pages・
#     pjp-agent-link-watch が無い。fish の abbr と bash の alias に h・hr・c が無い。ssh の設定に PJP_SSH_CLIENT が無い。git の
#     設定に名前とメール (settings.user) と pollenjp-sub の includes が無い
#   - client の group.json で段のある道具が全部 false、windows-files.json の claudeCode・ntn が false (win/ は配る)
#   - client に入る package の名前・home.file の置き先・systemd の user unit の名前が、fixture
#     (tests/fixtures/group-client/*.txt) と同じ。新しい道具を段 (lib/groups.nix) に入れ忘れると、客先の PC にも入り、ここで
#     違いとして出る (段の決め忘れの見張り)。① の道具なら fixture に足し、② ③ なら switch で止める
#   - client-claude (客先で Claude Code だけ許可が出たホスト) には ~/.claude/CLAUDE.md と claude-personal があり、herdr の skill・
#     herdr・cc-pages・ntn・claude-skills の手順 (group.json の claudePrivateSkills) は入らない
{
  lib,
  pkgs,
  mkHome,
}:

let
  examples = import ../lib/group-examples.nix { inherit mkHome; };
  client = examples.client.config;
  clientClaude = examples.client-claude.config;

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
      lib.splitString "\n" (builtins.readFile (./fixtures/group-client + "/${name}.txt"))
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
        "${name} が fixture (tests/fixtures/group-client/${name}.txt) と同じ"
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

  noneOf = what: xs: {
    name = "client に ${what} が無い";
    ok = xs == [ ];
  };

  cases = [
    (noneOf "~/.claude/ の下のファイル" (builtins.filter (lib.hasPrefix ".claude/") (files client)))
    (noneOf "Claude Code 向けの state (claude-op-reason.json を除く)" (claudeStates client))
    (noneOf "ntn.json・herdr の設定・~/.ssh/rc・cc-pages の config.toml" (
      builtins.filter (hasFile client) [
        ".local/state/dotfiles/ntn.json"
        ".config/herdr/config.toml"
        ".ssh/rc"
        ".config/cc-pages/config.toml"
      ]
    ))
    (noneOf "② ③ の package (herdr・ntn・herdr-core・pjp-agent-link・claude-<名前>)" (
      builtins.filter (hasPackage client) [
        "herdr"
        "ntn"
        "herdr-core"
        "pjp-agent-link"
        "claude-personal"
        "claude-work"
      ]
    ))
    (noneOf "cc-pages・pjp-agent-link-watch の unit" (
      builtins.filter (hasUnit client) [
        "cc-pages.service"
        "pjp-agent-link-watch.service"
        "pjp-agent-link-watch.path"
      ]
    ))
    (noneOf "fish の abbr・bash の alias の h・hr・c" (
      builtins.filter
        (n: client.programs.fish.shellAbbrs ? ${n} || client.programs.bash.shellAliases ? ${n})
        [
          "h"
          "hr"
          "c"
        ]
    ))
    {
      name = "client の ssh の設定に PJP_SSH_CLIENT が無い";
      ok =
        !(lib.hasInfix "PJP_SSH_CLIENT" (toString (client.home.file.".ssh/config".text or "")))
        && !(client.programs.ssh.settings ? "*");
    }
    {
      name = "client の git の設定に名前とメールと pollenjp-sub の includes が無い";
      ok = !(client.programs.git.settings ? user) && client.programs.git.includes == [ ];
    }
    {
      name = "client の group.json で段のある道具が全部 false";
      ok = builtins.all (t: t.tiers == [ ] || (groupJson client).tools.${t.key} == false) groups.tools;
    }
    {
      name = "client の windows-files.json は win/ を配り、claudeCode・ntn が false";
      ok =
        let
          w = windowsJson client;
        in
        w.enable && !w.claudeCode && !w.ntn;
    }
    (snapshot "packages" (packages client))
    (snapshot "files" (files client))
    (snapshot "units" (units client))
    {
      name = "client-claude には ~/.claude/CLAUDE.md と claude-personal がある";
      ok = hasFile clientClaude ".claude/CLAUDE.md" && hasPackage clientClaude "claude-personal";
    }
    {
      name = "client-claude に herdr の skill・herdr・cc-pages・ntn・claude-skills の手順は入らない";
      ok =
        !(hasFile clientClaude ".claude/skills/herdr")
        && !(hasPackage clientClaude "herdr")
        && !(hasUnit clientClaude "cc-pages.service")
        && !(hasPackage clientClaude "ntn")
        && (groupJson clientClaude).tools.claudePrivateSkills == false;
    }
  ];

  failed = builtins.filter (c: !c.ok) cases;
in
assert lib.assertMsg (failed == [ ])
  "group-client-state: 合わない項目: ${lib.concatMapStringsSep " / " (c: c.name) failed}";
pkgs.runCommand "group-client-state" { } ''
  echo ${lib.escapeShellArg (lib.concatMapStringsSep "\n" (c: "ok   ${c.name}") cases)}
  touch $out
''
