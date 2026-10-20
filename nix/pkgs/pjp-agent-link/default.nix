# herdr の session ごとの固定名 (~/.ssh/agent.sock・~/.ssh/agent.<session>.sock) の向け先を決める
# pjp-agent-link と、手で打つ逃げ道の ssh-agent-link (ADR 025)。何をするかは pjp-agent-link.sh の先頭のコメント。
#
# herdr を包む実行ファイル (herdr.nix)・~/.ssh/rc・見張りの systemd の unit は、home/modules/agent-link.nix が
# これを store のパスで呼ぶ。
#
# runtimeInputs の openssh は、生死を見る ssh-add を SSH_AUTH_SOCK を見る実体に揃えるため (WSL の PATH の ssh-add は
# Windows の ssh-add.exe へのラッパーのことがある。ADR 004)。flock は張り替えの排他、coreutils は timeout・
# readlink・mv -T・date・stat。
{
  lib,
  symlinkJoin,
  writeShellApplication,
  writeShellScriptBin,
  coreutils,
  openssh,
  flock,
}:

let
  agentLink = writeShellApplication {
    name = "pjp-agent-link";
    runtimeInputs = [
      coreutils
      openssh
      flock
    ];
    text = builtins.readFile ./pjp-agent-link.sh;
  };

  # 手で打つ逃げ道。前は fish・bash の関数だった (ADR 008)。打つ名前は変えない
  sshAgentLink = writeShellScriptBin "ssh-agent-link" ''
    exec ${lib.getExe agentLink} link "$@"
  '';
in
symlinkJoin {
  name = "pjp-agent-link";
  paths = [
    agentLink
    sshAgentLink
  ];
  meta.mainProgram = "pjp-agent-link";
}
