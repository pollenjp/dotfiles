# herdr を包む (ADR 025)。bin/herdr を herdr.sh (固定名を渡してから本物の herdr を exec する script) に替え、
# 残り (share/ の補完と agent skill) は本物の herdr への symlink のまま並べる。何をするかは herdr.sh の先頭のコメント。
#
# home には home/modules/agent-link.nix が入れる (modules/packages.nix の herdr の代わり)。passthru.unwrapped は
# 包む前の herdr (tests/claude-herdr-skill.nix が skill の置き場所を見るのに使う)。
{
  runtimeShell,
  symlinkJoin,
  replaceVars,
  coreutils,
  herdr,
  agentLink,
}:

let
  script = replaceVars ./herdr.sh {
    herdr = "${herdr}/bin/herdr";
    agentLink = "${agentLink}/bin/pjp-agent-link";
    timeout = "${coreutils}/bin/timeout";
  };
in
symlinkJoin {
  name = "herdr-${herdr.version}";
  paths = [ herdr ];
  postBuild = ''
    rm "$out/bin/herdr"
    install -m 755 ${script} "$out/bin/herdr"
    substituteInPlace "$out/bin/herdr" --replace-fail '#!/usr/bin/env bash' '#!${runtimeShell}'
  '';
  passthru.unwrapped = herdr;
  meta = herdr.meta // {
    mainProgram = "herdr";
  };
}
