# 設定グループごとの作り物のホスト (dotfiles-private の docs/adr/109_host_groups_minimum_all_*)。
#
# flake の checks (minimum のホストを build し、minimum に入らない道具のものが無いことを確かめる。tests/group-minimum.nix。all のホストを
# 2 つ build し、全部 on でも止まらないことを確かめる) と、グループの説明の生成物 (nix/groups.md) が使う。homeConfigurations には
# 出さない (setup の一覧に出さない・--host で選ばせない)。名前と値は作り物 (ユーザー名・Windows のユーザー名は user)。
#
#   minimum         group = "minimum" (書かないホストと同じ)。WSL で win/ を配る (Windows の道具もグループで決まる値を見せるため)
#   minimum-claude  minimum に Claude Code だけを足したホスト (group = "minimum" と claude.enable = true。WSL で win/ を配る)
#   all-wsl         group = "all"。WSL で win/ を配る (Windows の道具・WSL だけの道具も入る。SSH の中継は win/ を配るので効かない)
#   all-linux       group = "all"。WSL でない Linux (Windows の道具・WSL だけの道具は、グループに入っても効かない)
#
# all の 2 つは Dev Tracker も入るので、Notion の宛先を選んでおく (選ばないと評価のたびに警告が出る)。
{ mkHome }:

let
  host =
    args:
    mkHome (
      {
        username = "user";
        system = "x86_64-linux";
      }
      // args
    );
  wsl = {
    enable = true;
    windowsUserName = "user";
    windowsFiles.enable = true;
  };
in
{
  minimum = host {
    group = "minimum";
    inherit wsl;
  };
  minimum-claude = host {
    group = "minimum";
    inherit wsl;
    claude.enable = true;
  };
  all-wsl = host {
    group = "all";
    inherit wsl;
    claude.notion.profile = "personal";
  };
  all-linux = host {
    group = "all";
    claude.notion.profile = "personal";
  };
}
