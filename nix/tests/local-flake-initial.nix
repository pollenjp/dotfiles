# setup-local-flake.sh --initial がローカル flake に差し込む初期用のホスト initial を、評価時に確かめる。
# 差し込む塊を作り物の値で書いたもの (fixtures/local-flake-initial/initial.nix。差し込んだ塊と同じかは
# setup-local-flake.test.sh が見る) を、本体の mkHome で組む。
#
# 合わなければ assert で評価が止まり、外れた項目の名前が出る。評価で止まるので、
# CI の `nix flake check --all-systems --no-build` (全 system の評価) でも落ちる。
# flake.nix の checks (local-flake-initial-state) から呼ぶ。build は checks の home-wsl-initial-example (x86_64-linux)。
#
# ## 確かめること
#
#   - initial は評価でき、activationPackage の drvPath が出る
#   - WSL の値 (windowsUserName・windowsFiles) が入り、windows-files.json が win/ を配るマシンとして配り先
#     (/mnt/c/Users/alice) を持つ。type-clipboard (windowsFiles.typeClipboard) は入れず、ntn と Claude Code は既定どおり入れる
#   - 1Password・exeExecTrace・mtuGuard は無効 (鍵も sudo の手順も要らない初回)。git の署名を既定にせず、ssh のラッパー
#     (~/.local/bin/ssh) も置かない
#   - Dev Tracker は使わず、gitViaGh は本体の既定 (true) のまま
#   - config.warnings は空。ただし nixpkgs の猶予の例外の消し時 (「nixpkgs の例外」で始まる文。lib/release-age.nix) は
#     数えない (例外が何もしなくなっても CI は落とさない。ADR 032)
{
  lib,
  pkgs,
  mkHome,
}:

let
  initial =
    (import ./fixtures/local-flake-initial/initial.nix { dotfiles.lib = { inherit mkHome; }; }).initial;
  cfg = initial.config;
  d = cfg.dotfiles;

  cases = [
    {
      name = "initial は評価でき、activationPackage の drvPath が出る";
      ok = lib.hasSuffix ".drv" initial.activationPackage.drvPath;
    }
    {
      name = "WSL の値 (windowsUserName・windowsFiles) が入る";
      ok = d.wsl.enable && d.wsl.windowsUserName == "alice" && d.wsl.windowsFiles.enable;
    }
    {
      name = "windows-files.json は win/ を配るマシンとして配り先 (/mnt/c/Users/alice) を持ち、type-clipboard は入れず、ntn と Claude Code は入れる";
      ok =
        builtins.fromJSON cfg.home.file.".local/state/dotfiles/windows-files.json".text == {
          claudeCode = true;
          enable = true;
          ntn = true;
          typeClipboard = false;
          version = 1;
          windowsHome = "/mnt/c/Users/alice";
        };
    }
    {
      name = "1Password・exeExecTrace・mtuGuard は無効";
      ok = !d.onePassword.enable && !d.wsl.exeExecTrace.enable && !d.wsl.mtuGuard.enable;
    }
    {
      name = "git の署名を既定にせず、ssh のラッパー (~/.local/bin/ssh) を置かない";
      ok = cfg.programs.git.signing.signByDefault != true && !(cfg.home.file ? ".local/bin/ssh");
    }
    {
      name = "Dev Tracker は使わず、gitViaGh は本体の既定 (true) のまま";
      ok = !d.claude.devTracker.enable && d.claude.gitViaGh.enable;
    }
    {
      name = "config.warnings は空 (nixpkgs の例外の消し時は数えない)";
      ok = builtins.filter (w: !lib.hasPrefix "nixpkgs の例外" w) cfg.warnings == [ ];
    }
  ];

  failed = builtins.filter (c: !c.ok) cases;
in
assert lib.assertMsg (failed == [ ])
  "local-flake-initial-state: 合わない項目: ${lib.concatMapStringsSep " / " (c: c.name) failed}";
pkgs.runCommand "local-flake-initial-state" { } ''
  echo ${lib.escapeShellArg (lib.concatMapStringsSep "\n" (c: "ok   ${c.name}") cases)}
  touch $out
''
