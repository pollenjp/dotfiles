# 設定グループごとの作り物のホスト (dotfiles-private の docs/adr/057_host_setting_groups_*)。
#
# flake の checks (客先のホストを build し、② ③ のものが無いことを確かめる。tests/group-client.nix) と、グループの説明の
# 生成物 (nix/groups.md) が使う。homeConfigurations には出さない (setup の一覧に出さない・--host で選ばせない)。
#
# どれも WSL で win/ を配るホストにしてある (Windows のアプリの switch も、グループで決まる値を見せるため)。名前と値は
# 作り物 (ユーザー名・Windows のユーザー名は user)。
#
#   personal       group = "personal" (書かないホストと同じ)
#   company        group = "company" (③ を足さない、自社のグループの既定のまま)
#   client         group = "client" (① だけ)
#   client-claude  客先で Claude Code だけ許可が出たホスト (group = "client" と claude.enable = true)
{ mkHome }:

let
  host =
    args:
    mkHome (
      {
        username = "user";
        system = "x86_64-linux";
        wsl = {
          enable = true;
          windowsUserName = "user";
          windowsFiles.enable = true;
        };
      }
      // args
    );
in
{
  personal = host { group = "personal"; };
  company = host { group = "company"; };
  client = host { group = "client"; };
  client-claude = host {
    group = "client";
    claude.enable = true;
  };
}
