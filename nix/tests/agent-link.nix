# home/modules/agent-link.nix が home に入れるもの (herdr を包んだもの・~/.ssh/rc・見張りの systemd の unit) と、
# それに合わせて変えた shell と ssh の設定を確かめる (ADR 025)。
#
# 合わなければ assert で評価が止まり、外れた項目の名前が出る。評価で止まるので、CI の
# `nix flake check --all-systems --no-build` (全 system の評価) でも落ちる。flake.nix の checks (agent-link-state)
# から呼ぶ。
#
# ## 確かめること
#
#   評価時 (assert)
#     - home.packages の herdr は 1 つだけで、包む前 (passthru.unwrapped) は pkgs.herdr
#     - home.packages に pjp-agent-link の package がある
#     - ~/.ssh/rc は pjp-agent-link rc を exec し、stdout を /dev/null へ向ける
#     - Linux では pjp-agent-link-watch の path unit が ~/.ssh/agent と記録の conn/ を PathChanged で見て、
#       default.target で起き、service が oneshot で pjp-agent-link watch を打つ。service は起動の上限を外す
#       (StartLimitIntervalSec = 0。接続が続くと上限に当たって見張りが止まる)。darwin には unit を置かない
#     - fish の functions と bash の initExtra に herdr・ssh-agent-link の関数が無い
#     - 299_ssh_agent (フォールバック) が ~/.ssh/agent.<session>.sock の shell でも何もしない
#       (bash は "${HOME}"/.ssh/agent.*.sock の pattern、fish は string match)
#     - ~/.ssh/config は Include の後ろに Host * と SetEnv PJP_SSH_CLIENT="%u@%L" を持つ
#   ビルド時 (このランナーの system だけ)
#     - 包んだ herdr の bin/herdr は、本物の herdr と pjp-agent-link を store のパスで呼び、置き換えの印が残っていない
#     - bin/herdr --version が本物の herdr の版を出す。bin/ssh-agent-link が pjp-agent-link link を呼ぶ
{
  lib,
  pkgs,
  mkHome,
  system,
}:

let
  cfg =
    (mkHome {
      username = "tester";
      inherit system;
    }).config;

  isLinux = pkgs.stdenv.hostPlatform.isLinux;
  herdrs = builtins.filter (p: lib.getName p == "herdr") cfg.home.packages;
  herdr = builtins.head herdrs;
  agentLink = lib.findFirst (p: lib.getName p == "pjp-agent-link") null cfg.home.packages;

  # hasInfix (正規表現) は store のパスを含む文字列を受け付けないので、context を外して比べる
  noCtx = builtins.unsafeDiscardStringContext;
  rc = noCtx (cfg.home.file.".ssh/rc".text or "");
  sshConfig = cfg.home.file.".ssh/config".text or "";
  bashInit = cfg.programs.bash.initExtra;
  fishInit = cfg.programs.fish.interactiveShellInit;
  pathUnit = cfg.systemd.user.paths.pjp-agent-link-watch or null;
  serviceUnit = cfg.systemd.user.services.pjp-agent-link-watch or null;

  # ~/.ssh/config の中の、Include の行と Host * のブロックの位置
  lines = lib.splitString "\n" sshConfig;
  indexOf = line: lib.lists.findFirstIndex (l: l == line) null lines;
  includeAt = indexOf "Include config.d/*.ssh_config";
  hostAllAt = indexOf "Host *";
  # '' … '' だと先頭の空白が落ちるので、"…" で書く
  setEnvAt = indexOf "  SetEnv PJP_SSH_CLIENT=\"%u@%L\"";

  cases = [
    {
      name = "home.packages の herdr は 1 つだけ";
      ok = builtins.length herdrs == 1;
    }
    {
      name = "home.packages の herdr は pkgs.herdr を包んだもの";
      ok = (herdr.unwrapped or null) != null && "${herdr.unwrapped}" == "${pkgs.herdr}";
    }
    {
      name = "home.packages に pjp-agent-link がある";
      ok = agentLink != null;
    }
    {
      name = "~/.ssh/rc は pjp-agent-link rc を exec し、stdout を /dev/null へ向ける";
      ok = agentLink != null && lib.hasInfix (noCtx "exec ${lib.getExe agentLink} rc >/dev/null") rc;
    }
    {
      name =
        if isLinux then
          "Linux: path unit が ~/.ssh/agent と conn/ を PathChanged で見て、default.target で起きる"
        else
          "darwin: 見張りの path unit を置かない";
      ok =
        if isLinux then
          pathUnit != null
          &&
            pathUnit.Path.PathChanged == [
              "%h/.ssh/agent"
              "%h/.local/state/pjp-agent-link/conn"
            ]
          && pathUnit.Install.WantedBy == [ "default.target" ]
        else
          pathUnit == null;
    }
    {
      name =
        if isLinux then
          "Linux: service は oneshot で pjp-agent-link watch を打ち、起動の上限を外す"
        else
          "darwin: 見張りの service を置かない";
      ok =
        if isLinux then
          serviceUnit != null
          && serviceUnit.Service.Type == "oneshot"
          && agentLink != null
          && serviceUnit.Service.ExecStart == [ "${lib.getExe agentLink} watch" ]
          && (serviceUnit.Unit.StartLimitIntervalSec or null) == 0
        else
          serviceUnit == null;
    }
    {
      name = "fish に herdr・ssh-agent-link の関数が無い";
      ok = !(cfg.programs.fish.functions ? herdr) && !(cfg.programs.fish.functions ? ssh-agent-link);
    }
    {
      name = "bash に herdr・ssh-agent-link の関数が無い";
      ok = !(lib.hasInfix "herdr() {" bashInit) && !(lib.hasInfix "ssh-agent-link() {" bashInit);
    }
    {
      name = "bash の 299_ssh_agent は ~/.ssh/agent.<session>.sock の shell でフォールバックしない";
      ok = lib.hasInfix ''[[ "''${SSH_AUTH_SOCK:-}" != "''${HOME}"/.ssh/agent.*.sock ]]'' bashInit;
    }
    {
      name = "fish の 299_ssh_agent は ~/.ssh/agent.<session>.sock の shell でフォールバックしない";
      ok = lib.hasInfix ''and not string match -q -- "$HOME/.ssh/agent.*.sock" "$SSH_AUTH_SOCK"'' fishInit;
    }
    {
      name = "~/.ssh/config は Include の後ろの Host * に SetEnv PJP_SSH_CLIENT=\"%u@%L\" を持つ";
      ok =
        includeAt != null
        && hostAllAt != null
        && setEnvAt != null
        && includeAt < hostAllAt
        && hostAllAt + 1 == setEnvAt;
    }
  ];

  failed = builtins.filter (c: !c.ok) cases;
in
assert lib.assertMsg (failed == [ ])
  "agent-link-state: 合わない項目: ${lib.concatMapStringsSep " / " (c: c.name) failed}";
pkgs.runCommand "agent-link-state" { } ''
  echo ${lib.escapeShellArg (lib.concatMapStringsSep "\n" (c: "ok   ${c.name}") cases)}
  wrapper=${herdr}/bin/herdr
  if ! grep -qF 'real=${pkgs.herdr}/bin/herdr' "$wrapper" \
    || ! grep -qF 'agent=${lib.getExe agentLink}' "$wrapper"; then
    echo "agent-link-state: $wrapper が本物の herdr と pjp-agent-link を store のパスで呼んでいない" >&2
    exit 1
  fi
  if grep -qE '@(herdr|agentLink|timeout)@' "$wrapper"; then
    echo "agent-link-state: $wrapper に置き換えの印が残っている" >&2
    exit 1
  fi
  version=$(HOME=$TMPDIR "$wrapper" --version)
  if [[ $version != "herdr ${pkgs.herdr.version}" ]]; then
    echo "agent-link-state: $wrapper --version が herdr ${pkgs.herdr.version} を出さない ($version)" >&2
    exit 1
  fi
  echo "ok   bin/herdr は本物の herdr と pjp-agent-link を store のパスで呼び、--version は $version"
  # 中で呼ぶのは symlinkJoin で並べる前の pjp-agent-link (store のパスは package と違う)
  if ! grep -qE '^exec /nix/store/[^ ]+/bin/pjp-agent-link link "\$@"$' ${agentLink}/bin/ssh-agent-link; then
    echo "agent-link-state: bin/ssh-agent-link が pjp-agent-link link を呼んでいない" >&2
    exit 1
  fi
  echo "ok   bin/ssh-agent-link は pjp-agent-link link を呼ぶ"
  touch $out
''
