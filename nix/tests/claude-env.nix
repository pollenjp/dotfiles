# home/options.nix の dotfiles.claude.gitViaGh.enable から作られるものを、評価時に確かめる。
#
#   - 既定は true
#   - ~/.local/state/dotfiles/claude-env.json の中身 (true / false それぞれ)。
#     nix/scripts/bootstrap-claude-env.sh がこれを ~/.claude/settings.json の env へ写す
#   - home.packages に gh が入る (true の前提)
#
# 合わなければ assert で評価が止まり、外れた項目の名前が出る。評価で止まるので、
# CI の `nix flake check --all-systems --no-build` (全 system の評価) でも落ちる。
# flake.nix の checks (claude-env-state) から呼ぶ。
{
  lib,
  pkgs,
  mkHome,
  system,
}:

let
  configWith =
    claude:
    (mkHome {
      username = "tester";
      inherit system claude;
    }).config;

  textOf = cfg: cfg.home.file.".local/state/dotfiles/claude-env.json".text;

  managed = [
    "commit.gpgsign"
    "tag.gpgsign"
    "url.https://github.com/.insteadOf"
    "credential.https://github.com.helper"
  ];
  base = [
    {
      k = "commit.gpgsign";
      v = "false";
    }
    {
      k = "tag.gpgsign";
      v = "false";
    }
  ];
  gh = [
    {
      k = "url.https://github.com/.insteadOf";
      v = "git@github.com:";
    }
    {
      k = "url.https://github.com/.insteadOf";
      v = "ssh://git@github.com/";
    }
    {
      k = "credential.https://github.com.helper";
      v = "!gh auth git-credential";
    }
  ];

  byDefault = configWith { };
  disabled = configWith { gitViaGh.enable = false; };

  cases = [
    {
      name = "gitViaGh.enable の既定は true";
      ok = byDefault.dotfiles.claude.gitViaGh.enable;
    }
    {
      name = "既定 (true) の状態ファイルは無署名の 2 組と HTTPS の 3 組で、管理キーは 4 つ";
      ok =
        builtins.fromJSON (textOf byDefault) == {
          inherit managed;
          gitConfig = base ++ gh;
        };
    }
    {
      name = "false の状態ファイルは無署名の 2 組だけで、管理キーは 4 つのまま";
      ok =
        builtins.fromJSON (textOf disabled) == {
          inherit managed;
          gitConfig = base;
        };
    }
    {
      name = "状態ファイルは改行で終わる";
      ok = lib.hasSuffix "\n" (textOf byDefault);
    }
    {
      name = "home.packages に gh が入る";
      ok = builtins.any (p: lib.getName p == "gh") byDefault.home.packages;
    }
  ];

  failed = builtins.filter (c: !c.ok) cases;
in
assert lib.assertMsg (failed == [ ])
  "claude-env-state: 合わない項目: ${lib.concatMapStringsSep " / " (c: c.name) failed}";
pkgs.runCommand "claude-env-state" { } ''
  echo ${lib.escapeShellArg (lib.concatMapStringsSep "\n" (c: "ok   ${c.name}") cases)}
  touch $out
''
