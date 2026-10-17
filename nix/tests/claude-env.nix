# home/options.nix の dotfiles.claude.gitViaGh.enable から作られるものと、Claude Code の Bash tool の
# shell (CLAUDE_CODE_SHELL) を、評価時に確かめる。
#
# 合わなければ assert で評価が止まり、外れた項目の名前が出る。評価で止まるので、
# CI の `nix flake check --all-systems --no-build` (全 system の評価) でも落ちる。
# flake.nix の checks (claude-env-state) から呼ぶ。
#
# ## 確かめること
#
#   - 既定は true
#   - ~/.local/state/dotfiles/claude-env.json の中身 (true / false それぞれ)。
#     nix/scripts/bootstrap-claude-env.sh がこれを ~/.claude/settings.json の env へ写す。
#     CLAUDE_CODE_SHELL は option によらず profile の bash (<home>/.nix-profile/bin/bash)
#   - home.packages に gh が入る (true の前提)
#   - home.packages に bash が入る (CLAUDE_CODE_SHELL が指す profile の bin/bash の元)。
#     programs.bash.package を null にすると評価で止まる
{
  lib,
  pkgs,
  mkHome,
  system,
}:

let
  # modules は mkHome にそのまま渡す (option 以外の設定を足して確かめるとき)
  homeWith =
    claude: modules:
    mkHome {
      username = "tester";
      inherit system claude modules;
    };
  configWith = claude: (homeWith claude [ ]).config;

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

  # Bash tool の shell。mkHome の既定の home (/home/<名前>、darwin は /Users/<名前>) の profile の bash
  managedVars = [ "CLAUDE_CODE_SHELL" ];
  vars = {
    CLAUDE_CODE_SHELL =
      if lib.hasSuffix "darwin" system then
        "/Users/tester/.nix-profile/bin/bash"
      else
        "/home/tester/.nix-profile/bin/bash";
  };

  byDefault = configWith { };
  disabled = configWith { gitViaGh.enable = false; };

  # programs.bash.package を null にした設定。評価 (.config を読む) で止まれば success が false になる
  noBashPackage = builtins.tryEval (
    (homeWith { } [ { programs.bash.package = null; } ]).config.home.username
  );

  cases = [
    {
      name = "gitViaGh.enable の既定は true";
      ok = byDefault.dotfiles.claude.gitViaGh.enable;
    }
    {
      name = "既定 (true) の状態ファイルは無署名の 2 組と HTTPS の 3 組で、管理キーは 4 つ。CLAUDE_CODE_SHELL は profile の bash";
      ok =
        builtins.fromJSON (textOf byDefault) == {
          inherit managed managedVars vars;
          gitConfig = base ++ gh;
        };
    }
    {
      name = "false の状態ファイルは無署名の 2 組だけで、管理キーは 4 つのまま。CLAUDE_CODE_SHELL は変わらない";
      ok =
        builtins.fromJSON (textOf disabled) == {
          inherit managed managedVars vars;
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
    {
      name = "home.packages に bash (bash-interactive) が入る";
      ok = builtins.any (p: lib.getName p == "bash-interactive") byDefault.home.packages;
    }
    {
      name = "programs.bash.package を null にすると評価で止まる";
      ok = !noBashPackage.success;
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
