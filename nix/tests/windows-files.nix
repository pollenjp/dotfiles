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
#   - win/ を配るマシンは windowsHome (/mnt/c/Users/<名前>) を持つ。minimum では type-clipboard・ntn・Claude Code を既定で入れず
#     (typeClipboard・ntn・claudeCode は false)、all なら入れる (どれも true)
#   - all で windowsFiles.ntn.enable = false なら ntn だけが false、windowsFiles.claudeCode.enable = false なら claudeCode だけが false
#   - windowsFiles.typeClipboard.enable = true なら typeClipboard が true になる (bootstrap-windows-type-clipboard.sh が入れる)
#   - windowsFiles.enable = false のマシンで typeClipboard.enable = true にすると、評価で止まる (配らないと
#     Install-TypeClipboard.ps1 が届かない)
#   - windows-sshd.json (Windows の sshd に入れる公開鍵) もどのホストにも置き、既定は authorizedKeys が null (dotfiles は鍵を
#     置かない)。sshd を入れて鍵の list を書いたホストだけ、その list (空の list も) が入る。鍵を書いても、sshd を入れない・
#     win/ を配らないホストでは null
#   - 改行を含む鍵の値は評価で止まる (写しの authorized_keys の 1 行を割るため)
{
  lib,
  pkgs,
  mkHome,
  system,
}:

let
  configWith = configIn "minimum";
  # グループを選んだホスト (Windows の道具の既定はグループで決まる。all なら win/ を配るマシンで on)
  configIn =
    group: wsl:
    (mkHome {
      username = "tester";
      inherit system group wsl;
    }).config;

  stateOf = cfg: builtins.fromJSON cfg.home.file.".local/state/dotfiles/windows-files.json".text;
  sshdOf = cfg: builtins.fromJSON cfg.home.file.".local/state/dotfiles/windows-sshd.json".text;
  # 例の鍵 (作り物。from= の IP は tailnet の範囲の例)
  exampleKey = "from=\"100.64.0.1\" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleExampleExampleExampleExampleExample phone";
  sshdWith =
    extra:
    configWith {
      enable = true;
      windowsUserName = "alice";
      windowsFiles = {
        enable = true;
      }
      // extra;
    };
  sshdKeys = sshdWith {
    sshd = {
      enable = true;
      authorizedKeys = [ exampleKey ];
    };
  };
  sshdNoKeys = sshdWith {
    sshd = {
      enable = true;
      authorizedKeys = [ ];
    };
  };
  sshdUnmanaged = sshdWith { sshd.enable = true; };
  # 鍵を書いても sshd を入れないホストでは渡さない
  keysWithoutSshd = sshdWith { sshd.authorizedKeys = [ exampleKey ]; };
  keysWithoutFiles = configWith {
    enable = true;
    windowsUserName = "alice";
    windowsFiles.sshd = {
      enable = true;
      authorizedKeys = [ exampleKey ];
    };
  };
  keyWithNewline =
    builtins.tryEval
      (sshdWith {
        sshd = {
          enable = true;
          authorizedKeys = [ "${exampleKey}\n${exampleKey}" ];
        };
      }).home.username;

  notWindows = configWith { };
  files = configWith {
    enable = true;
    windowsUserName = "alice";
    windowsFiles.enable = true;
  };
  filesAll = configIn "all" {
    enable = true;
    windowsUserName = "alice";
    windowsFiles.enable = true;
  };
  noNtn = configIn "all" {
    enable = true;
    windowsUserName = "alice";
    windowsFiles = {
      enable = true;
      ntn.enable = false;
    };
  };
  noClaudeCode = configIn "all" {
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
      name = "win/ を配るマシンは windowsHome を持ち、minimum では type-clipboard・ntn・Claude Code を既定で入れない (all なら入れる)";
      ok =
        stateOf files == {
          claudeCode = false;
          enable = true;
          ntn = false;
          typeClipboard = false;
          version = 1;
          windowsHome = "/mnt/c/Users/alice";
        }
        && !files.dotfiles.wsl.windowsFiles.typeClipboard.enable
        &&
          stateOf filesAll == {
            claudeCode = true;
            enable = true;
            ntn = true;
            typeClipboard = true;
            version = 1;
            windowsHome = "/mnt/c/Users/alice";
          };
    }
    {
      name = "all で windowsFiles.ntn.enable = false なら ntn だけが false";
      ok =
        (stateOf noNtn).ntn == false
        && (stateOf noNtn).claudeCode == true
        && (stateOf noNtn).enable == true;
    }
    {
      name = "all で windowsFiles.claudeCode.enable = false なら claudeCode だけが false";
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
    {
      name = "windows-sshd.json はどのホストにも置き、既定は authorizedKeys が null (dotfiles は鍵を置かない)";
      ok =
        sshdOf notWindows == {
          authorizedKeys = null;
          version = 1;
        }
        && (sshdOf files).authorizedKeys == null
        && (sshdOf sshdUnmanaged).authorizedKeys == null;
    }
    {
      name = "sshd を入れて鍵の list を書いたホストは、その list が入る (空の list も空のまま)";
      ok =
        (sshdOf sshdKeys).authorizedKeys == [ exampleKey ] && (sshdOf sshdNoKeys).authorizedKeys == [ ];
    }
    {
      name = "鍵を書いても、sshd を入れない・win/ を配らないホストでは null";
      ok =
        (sshdOf keysWithoutSshd).authorizedKeys == null && (sshdOf keysWithoutFiles).authorizedKeys == null;
    }
    {
      name = "改行を含む鍵の値は評価で止まる";
      ok = !keyWithNewline.success;
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
