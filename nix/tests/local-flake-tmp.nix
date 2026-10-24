# ローカル flake の雛形 (nix/scripts/setup-local-flake.sh) の tmp の例を、評価時に確かめる (ADR 027)。
# 例のコメントを 1 段外したもの (fixtures/local-flake-tmp/tmp.nix。雛形の本文と同じかは setup-local-flake.test.sh が
# 見る) を、本体の mkHome で組む。
#
# 合わなければ assert で評価が止まり、外れた項目の名前が出る。評価で止まるので、
# CI の `nix flake check --all-systems --no-build` (全 system の評価) でも落ちる。
# flake.nix の checks (local-flake-tmp-state) から呼ぶ。
#
# ## 確かめること
#
#   - tmp の例は、雛形に local が無くても mkForce なしで評価でき、activationPackage の drvPath が出る
#   - 例の有効な行の値が config に入る: WSL (windowsUserName・windowsFiles・exeExecTrace)・1Password・
#     Dev Tracker (true)・Notion の宛先 ("personal")
#   - 例の中でコメントのままの行 (gitViaGh・Notion の routes と override・解説動画の autoStart・cc-pages の port) は、
#     本体の既定のまま
#   - 例のままなら config.warnings は空 (Dev Tracker を使い、宛先も選んでいる)。ただし nixpkgs の猶予の例外の消し時
#     (「nixpkgs の例外」で始まる文。lib/release-age.nix) は数えない (例外が何もしなくなっても CI は落とさない。ADR 032)
{
  lib,
  pkgs,
  mkHome,
}:

let
  tmp = (import ./fixtures/local-flake-tmp/tmp.nix { dotfiles.lib = { inherit mkHome; }; }).tmp;
  cfg = tmp.config;
  d = cfg.dotfiles;

  cases = [
    {
      name = "tmp の例は mkForce なしで評価でき、activationPackage の drvPath が出る";
      ok = lib.hasSuffix ".drv" tmp.activationPackage.drvPath;
    }
    {
      name = "WSL の行 (windowsUserName・windowsFiles・exeExecTrace) と 1Password が入る";
      ok =
        d.wsl.enable
        && d.wsl.windowsUserName == "alice"
        && d.wsl.windowsFiles.enable
        && d.wsl.exeExecTrace.enable
        && d.onePassword.enable;
    }
    {
      name = "Dev Tracker を使い (true)、Notion の宛先は personal";
      ok = d.claude.devTracker.enable && d.claude.notion.profile == "personal";
    }
    {
      name = "コメントのままの行は本体の既定のまま (gitViaGh は true、routes と override は空、autoStart は false、port は null)";
      ok =
        d.claude.gitViaGh.enable
        && d.claude.notion.routes == { }
        && d.claude.notion.override == { }
        && !d.claude.videoOffer.autoStart.enable
        && d.ccPages.port == null;
    }
    {
      name = "例のままなら config.warnings は空 (nixpkgs の例外の消し時は数えない)";
      ok = builtins.filter (w: !lib.hasPrefix "nixpkgs の例外" w) cfg.warnings == [ ];
    }
  ];

  failed = builtins.filter (c: !c.ok) cases;
in
assert lib.assertMsg (failed == [ ])
  "local-flake-tmp-state: 合わない項目: ${lib.concatMapStringsSep " / " (c: c.name) failed}";
pkgs.runCommand "local-flake-tmp-state" { } ''
  echo ${lib.escapeShellArg (lib.concatMapStringsSep "\n" (c: "ok   ${c.name}") cases)}
  touch $out
''
