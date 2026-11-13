# files/claude/hooks/install-iac-guard.sh と、home/options.nix の dotfiles.claude.iacGuard.enable から作られる
# ~/.local/state/dotfiles/claude-iac-guard.json を、評価時に確かめる。
#
# 合わなければ assert で評価が止まり、外れた項目の名前が出る。評価で止まるので、
# CI の `nix flake check --all-systems --no-build` (全 system の評価) でも落ちる。
# flake.nix の checks (claude-install-iac-guard-state) から呼ぶ。
#
# ## 確かめること
#
#   - hook は ~/.claude/hooks/install-iac-guard.sh に、repo の script から実行できるファイルとして置かれる (どのホストにも
#     置く。登録は bootstrap-claude-hook.sh)
#   - iacGuard.enable の既定は true で、mkHome の claude 引数で false を渡せる
#   - claude-iac-guard.json は {"enable": <option の値>} で、改行で終わる。既定のままでも必ず書く (hook は無い・壊れている
#     ときは止める側に倒す)
#   - false にしても hook は置かれる (install は止め続ける。外れるのは IaC の分だけ)
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

  byDefault = configWith { };
  off = configWith { iacGuard.enable = false; };

  hook = cfg: cfg.home.file.".claude/hooks/install-iac-guard.sh" or null;
  state = cfg: cfg.home.file.".local/state/dotfiles/claude-iac-guard.json".text;

  placed =
    cfg:
    hook cfg != null
    && (hook cfg).executable
    && "${(hook cfg).source}" == "${../files/claude/hooks/install-iac-guard.sh}";

  cases = [
    {
      name = "hook は ~/.claude/hooks/install-iac-guard.sh に、repo の script から実行できるファイルとして置かれる";
      ok = placed byDefault;
    }
    {
      name = "iacGuard.enable の既定は true";
      ok = byDefault.dotfiles.claude.iacGuard.enable;
    }
    {
      name = "mkHome の claude 引数で iacGuard.enable = false を渡せる";
      ok = !off.dotfiles.claude.iacGuard.enable;
    }
    {
      name = "既定の claude-iac-guard.json は enable が true";
      ok = builtins.fromJSON (state byDefault) == { enable = true; };
    }
    {
      name = "iacGuard.enable = false の claude-iac-guard.json は enable が false";
      ok = builtins.fromJSON (state off) == { enable = false; };
    }
    {
      name = "claude-iac-guard.json は改行で終わる";
      ok = lib.hasSuffix "\n" (state byDefault) && lib.hasSuffix "\n" (state off);
    }
    {
      name = "iacGuard.enable = false でも hook は置かれる (install は止め続ける)";
      ok = placed off;
    }
  ];

  failed = builtins.filter (c: !c.ok) cases;
in
assert lib.assertMsg (failed == [ ])
  "claude-install-iac-guard-state: 合わない項目: ${lib.concatMapStringsSep " / " (c: c.name) failed}";
pkgs.runCommand "claude-install-iac-guard-state" { } ''
  echo ${lib.escapeShellArg (lib.concatMapStringsSep "\n" (c: "ok   ${c.name}") cases)}
  touch $out
''
