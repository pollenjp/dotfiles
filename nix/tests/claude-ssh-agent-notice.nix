# home/options.nix の dotfiles.claude.sshAgentNotice.extraCommands から作られる
# ~/.local/state/dotfiles/claude-ssh-agent-notice.json と、配置される hook を、評価時に確かめる。
#
# 合わなければ assert で評価が止まり、外れた項目の名前が出る。評価で止まるので、
# CI の `nix flake check --all-systems --no-build` (全 system の評価) でも落ちる。
# flake.nix の checks (claude-ssh-agent-notice-state) から呼ぶ。
#
# ## 確かめること
#
#   - sshAgentNotice.extraCommands の既定は空のリストで、mkHome の claude 引数で項目を渡せる
#   - claude-ssh-agent-notice.json は {"extraCommands": [<option の値>]} で、改行で終わる。hook (ssh-agent-notice.sh)
#     がこれを読み、項目に当たるコマンドも打つ前に知らせる
#   - hook は ~/.claude/hooks/ssh-agent-notice.sh に、repo の script から実行できるファイルとして置かれる
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

  state = cfg: cfg.home.file.".local/state/dotfiles/claude-ssh-agent-notice.json".text;
  hook = cfg: cfg.home.file.".claude/hooks/ssh-agent-notice.sh";

  extra = [
    "nix run .#vm"
    "*/deploy.sh"
  ];
  byDefault = configWith { };
  withExtra = configWith { sshAgentNotice.extraCommands = extra; };

  cases = [
    {
      name = "sshAgentNotice.extraCommands の既定は空のリスト";
      ok = byDefault.dotfiles.claude.sshAgentNotice.extraCommands == [ ];
    }
    {
      name = "mkHome の claude 引数で sshAgentNotice.extraCommands を渡せる";
      ok = withExtra.dotfiles.claude.sshAgentNotice.extraCommands == extra;
    }
    {
      name = "既定の claude-ssh-agent-notice.json は extraCommands が空";
      ok = builtins.fromJSON (state byDefault) == { extraCommands = [ ]; };
    }
    {
      name = "項目を渡すと claude-ssh-agent-notice.json の extraCommands に入る";
      ok = builtins.fromJSON (state withExtra) == { extraCommands = extra; };
    }
    {
      name = "claude-ssh-agent-notice.json は改行で終わる";
      ok = lib.hasSuffix "\n" (state byDefault);
    }
    {
      name = "hook は repo の script から、実行できるファイルとして置かれる";
      ok =
        (hook byDefault).executable
        && "${(hook byDefault).source}" == "${../files/claude/hooks/ssh-agent-notice.sh}";
    }
  ];

  failed = builtins.filter (c: !c.ok) cases;
in
assert lib.assertMsg (failed == [ ])
  "claude-ssh-agent-notice-state: 合わない項目: ${lib.concatMapStringsSep " / " (c: c.name) failed}";
pkgs.runCommand "claude-ssh-agent-notice-state" { } ''
  echo ${lib.escapeShellArg (lib.concatMapStringsSep "\n" (c: "ok   ${c.name}") cases)}
  touch $out
''
