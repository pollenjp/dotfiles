# herdr の session ごとの固定名 (~/.ssh/agent.sock・~/.ssh/agent.<session>.sock) の向け先を決める
# pjp-agent-link と、手で打つ逃げ道の ssh-agent-link (ADR 025)。何をするかは pjp-agent-link.sh の先頭のコメント。
#
# herdr を包む実行ファイル (herdr.nix)・~/.ssh/rc・見張りの systemd の unit は、home/modules/agent-link.nix が
# これを store のパスで呼ぶ。
#
# runtimeInputs は coreutils (timeout・readlink・mv -T・date・stat) だけ。ssh-add と flock は PATH の system のもの
# (ssh 先の OpenSSH と util-linux) を使い、home の閉包に openssh と flock を入れない。入れると、閉包の脆弱性スキャン
# (nix/scripts/closure-scan.sh) が openssh の CVE と、名前の一致する別の製品 (Flock というブラウザ) の CVE を拾う
# (CI で実測)。WSL の ssh-add のラッパーと、flock の無いホストの扱いは pjp-agent-link.sh の先頭のコメント。
{
  lib,
  symlinkJoin,
  writeShellApplication,
  writeShellScriptBin,
  coreutils,
}:

let
  agentLink = writeShellApplication {
    name = "pjp-agent-link";
    runtimeInputs = [ coreutils ];
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
