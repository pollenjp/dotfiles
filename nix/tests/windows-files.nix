# home/options.nix の dotfiles.wsl.windowsFiles から作られる windows-files.json (home/modules/windows-files.nix。
# Windows 側の bootstrap が読む、配るかどうか・配り先・type-clipboard・ntn・Claude Code を入れるか) を、評価時に確かめる。
#
# 合わなければ assert で評価が止まり、外れた項目の名前が出る。評価で止まるので、CI の
# `nix flake check --all-systems --no-build` (全 system の評価) でも落ちる。flake.nix の checks (windows-files-state)
# から呼ぶ。
#
# ## 確かめること
#
#   - win/ を配らないマシンでも windows-files.json を置き、enable・typeClipboard・ntn・claudeCode は false、windowsHome は null
#     (ntn・claudeCode の option は既定の true のままでも、評価は止まらない)
#   - win/ を配るマシンは windowsHome (/mnt/c/Users/<名前>) を持ち、type-clipboard は既定で入れない (typeClipboard は false)。
#     ntn と Claude Code は既定で入れる (ntn・claudeCode は true)
#   - windowsFiles.ntn.enable = false なら ntn だけが false、windowsFiles.claudeCode.enable = false なら claudeCode だけが false
#   - windowsFiles.typeClipboard.enable = true なら typeClipboard が true になる (bootstrap-windows-type-clipboard.sh が入れる)
#   - windowsFiles.enable = false のマシンで typeClipboard.enable = true にすると、評価で止まる (配らないと
#     Install-TypeClipboard.ps1 が届かない)
{
  lib,
  pkgs,
  mkHome,
  system,
}:

let
  configWith =
    wsl:
    (mkHome {
      username = "tester";
      inherit system wsl;
    }).config;

  stateOf = cfg: builtins.fromJSON cfg.home.file.".local/state/dotfiles/windows-files.json".text;

  notWindows = configWith { };
  files = configWith {
    enable = true;
    windowsUserName = "alice";
    windowsFiles.enable = true;
  };
  noNtn = configWith {
    enable = true;
    windowsUserName = "alice";
    windowsFiles = {
      enable = true;
      ntn.enable = false;
    };
  };
  noClaudeCode = configWith {
    enable = true;
    windowsUserName = "alice";
    windowsFiles = {
      enable = true;
      claudeCode.enable = false;
    };
  };
  typeClipboard = configWith {
    enable = true;
    windowsUserName = "alice";
    windowsFiles = {
      enable = true;
      typeClipboard.enable = true;
    };
  };
  # home-manager は assertion が落ちていると config を読んだ時点で throw する ("Failed assertions")。
  # 評価で止まれば success が false になる
  withoutFiles =
    builtins.tryEval
      (configWith {
        enable = true;
        windowsUserName = "alice";
        windowsFiles.typeClipboard.enable = true;
      }).home.username;

  cases = [
    {
      name = "win/ を配らないマシンでも置き、enable・typeClipboard・ntn・claudeCode は false、windowsHome は null";
      ok =
        stateOf notWindows == {
          claudeCode = false;
          enable = false;
          ntn = false;
          typeClipboard = false;
          version = 1;
          windowsHome = null;
        };
    }
    {
      name = "win/ を配るマシンは windowsHome を持ち、type-clipboard は既定で入れず、ntn と Claude Code は既定で入れる";
      ok =
        stateOf files == {
          claudeCode = true;
          enable = true;
          ntn = true;
          typeClipboard = false;
          version = 1;
          windowsHome = "/mnt/c/Users/alice";
        }
        && !files.dotfiles.wsl.windowsFiles.typeClipboard.enable;
    }
    {
      name = "windowsFiles.ntn.enable = false なら ntn だけが false";
      ok =
        (stateOf noNtn).ntn == false
        && (stateOf noNtn).claudeCode == true
        && (stateOf noNtn).enable == true;
    }
    {
      name = "windowsFiles.claudeCode.enable = false なら claudeCode だけが false";
      ok =
        (stateOf noClaudeCode).claudeCode == false
        && (stateOf noClaudeCode).ntn == true
        && (stateOf noClaudeCode).enable == true;
    }
    {
      name = "windowsFiles.typeClipboard.enable = true なら typeClipboard が true";
      ok = (stateOf typeClipboard).typeClipboard == true && (stateOf typeClipboard).enable == true;
    }
    {
      name = "windowsFiles.enable = false のマシンで typeClipboard.enable = true にすると評価で止まる";
      ok = !withoutFiles.success;
    }
  ];

  failed = builtins.filter (c: !c.ok) cases;
in
assert lib.assertMsg (failed == [ ])
  "windows-files-state: 合わない項目: ${lib.concatMapStringsSep " / " (c: c.name) failed}";
pkgs.runCommand "windows-files-state" { } ''
  echo ${lib.escapeShellArg (lib.concatMapStringsSep "\n" (c: "ok   ${c.name}") cases)}
  touch $out
''
