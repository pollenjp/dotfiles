# home/options.nix の dotfiles.onePassword.enable から作られる git の署名と ssh のラッパーを、
# 評価時に確かめる (ADR 021)。
#
# 合わなければ assert で評価が止まり、外れた項目の名前が出る。評価で止まるので、
# CI の `nix flake check --all-systems --no-build` (全 system の評価) でも落ちる。
# flake.nix の checks (one-password-state) から呼ぶ。
#
# ## 確かめること
#
#   - 既定 (1Password 無し) では、署名の設定 (gpg.* / commit.gpgSign) もラッパーも書き出さない
#   - WSL でないマシンで有効にすると、署名は home-manager の既定 (openssh の ssh-keygen) が
#     SSH_AUTH_SOCK のエージェントで行い、ラッパーは置かない
#   - WSL で有効にすると、署名は Windows 側の op-ssh-sign-wsl.exe で、ssh / ssh-add のラッパーを置く
#   - 鍵の選び方 (gpg.ssh.defaultKeyCommand) は WSL とそれ以外で同じ
#   - 旧名 dotfiles.wsl.onePassword.enable も同じ設定になり、改名の警告が出る
#   - WSL で windowsUserName が無いと assertion が落ちる
#   - 登録簿: pollenjp@laptop と pollenjp@wsl は有効、pollenjp@wsl-no-1password は無効
{
  lib,
  pkgs,
  mkHome,
  system,
}:

let
  configWith =
    args:
    (mkHome (
      {
        username = "tester";
        inherit system;
      }
      // args
    )).config;

  ini = cfg: cfg.programs.git.iniContent;
  hasWrappers = cfg: cfg.home.file ? ".local/bin/ssh" && cfg.home.file ? ".local/bin/ssh-add";
  hasNoSigning = cfg: !(ini cfg ? gpg) && !((ini cfg).commit or { } ? gpgSign);

  opSshSignWsl = "/mnt/c/Users/polle/AppData/Local/Microsoft/WindowsApps/op-ssh-sign-wsl.exe";

  none = configWith { };
  native = configWith { onePassword.enable = true; };
  wsl = configWith {
    wsl = {
      enable = true;
      windowsUserName = "polle";
    };
    onePassword.enable = true;
  };
  oldName = configWith {
    wsl = {
      enable = true;
      windowsUserName = "polle";
      onePassword.enable = true;
    };
  };
  # home-manager は assertion が落ちていると config を読んだ時点で throw する
  # ("Failed assertions")。評価で止まれば success が false になる
  wslNoName =
    builtins.tryEval
      (configWith {
        wsl.enable = true;
        onePassword.enable = true;
      }).home.username;

  hosts = import ../hosts { inherit mkHome; };
  hostEnabled = name: hosts.${name}.config.dotfiles.onePassword.enable;

  cases = [
    {
      name = "既定では署名の設定を書き出さない";
      ok = hasNoSigning none;
    }
    {
      name = "既定ではラッパーを置かない";
      ok = !(none.home.file ? ".local/bin/ssh");
    }
    {
      name = "WSL でないマシンの署名は ssh 形式で、commit と tag を既定で署名する";
      ok = (ini native).gpg.format == "ssh" && (ini native).commit.gpgSign && (ini native).tag.gpgSign;
    }
    {
      name = "WSL でないマシンの署名のプログラムは openssh の ssh-keygen";
      ok = (ini native).gpg.ssh.program == lib.getExe' pkgs.openssh "ssh-keygen";
    }
    {
      name = "WSL でないマシンにはラッパーを置かない";
      ok = !(native.home.file ? ".local/bin/ssh") && !(native.home.file ? ".local/bin/ssh-add");
    }
    {
      name = "WSL の署名のプログラムは op-ssh-sign-wsl.exe";
      ok = (ini wsl).gpg.ssh.program == opSshSignWsl;
    }
    {
      name = "WSL には ssh / ssh-add のラッパーを置く";
      ok = hasWrappers wsl;
    }
    {
      name = "鍵の選び方は WSL とそれ以外で同じで、Signing を含む鍵を選ぶ";
      ok =
        (ini native).gpg.ssh.defaultKeyCommand == (ini wsl).gpg.ssh.defaultKeyCommand
        && lib.hasInfix "Signing" (ini native).gpg.ssh.defaultKeyCommand;
    }
    {
      name = "旧名 wsl.onePassword.enable でも WSL と同じ署名とラッパーになる";
      ok = (ini oldName).gpg.ssh.program == opSshSignWsl && hasWrappers oldName;
    }
    {
      name = "旧名を使うと改名の警告が出る";
      ok = builtins.any (w: lib.hasInfix "dotfiles.wsl.onePassword.enable" w) oldName.warnings;
    }
    {
      name = "新しい名前だけなら改名の警告は出ない";
      ok = !(builtins.any (w: lib.hasInfix "dotfiles.wsl.onePassword.enable" w) wsl.warnings);
    }
    {
      name = "WSL で windowsUserName が無いと assertion で評価が止まる";
      ok = !wslNoName.success;
    }
    {
      name = "登録簿の pollenjp@laptop と pollenjp@wsl は 1Password を使う";
      ok = hostEnabled "pollenjp@laptop" && hostEnabled "pollenjp@wsl";
    }
    {
      name = "登録簿の pollenjp@wsl-no-1password は 1Password を使わない";
      ok = !(hostEnabled "pollenjp@wsl-no-1password");
    }
  ];

  failed = builtins.filter (c: !c.ok) cases;
in
assert lib.assertMsg (failed == [ ])
  "one-password-state: 合わない項目: ${lib.concatMapStringsSep " / " (c: c.name) failed}";
pkgs.runCommand "one-password-state" { } ''
  echo ${lib.escapeShellArg (lib.concatMapStringsSep "\n" (c: "ok   ${c.name}") cases)}
  touch $out
''
