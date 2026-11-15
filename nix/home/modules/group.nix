# 設定グループ (dotfiles.group) と段・道具の switch の値を ~/.local/state/dotfiles/group.json に置き、道具どうしの依存を
# 評価で確かめる (dotfiles-private の docs/adr/057_host_setting_groups_*。表は lib/groups.nix)。
#
#   {"group":"client","tiers":{"aiTools":false,"personalAccounts":false},"tools":{"ccPages":false,"claude":false,…},"version":1}
#
#   tools  lib/groups.nix の表の各行の key と、その option の値そのもの (効く条件 requires はかけない)
#
# setup.sh が読み、bootstrap-*.sh の冒頭の見出し (# tool: <key>) の key が false なら、その手順を飛ばす。setup.sh は Nix より
# 前にも走るので jq を使わず、"<key>":false の文字で見る (builtins.toJSON は空白を入れない)。bootstrap-mise.sh も
# tools.claude を読んで、claude を入れるかを決める。
#
# どのホストにも置く。ファイルが無いのは「この仕組みの前の世代へ switch したまま」で、setup は今までどおり全部流す
# (windows-files.json・cursor-agent.json と同じく、無いことと off を見分ける)。
{ config, lib, ... }:

let
  groups = import ../../lib/groups.nix;
  cfg = config.dotfiles;
in
{
  # 道具を 1 つずつ足すホスト (自社・客先) で、足し忘れを評価で気づけるようにする。段が全部 on の personal では成り立つ
  assertions = [
    {
      assertion = cfg.claude.privateSkills.enable -> cfg.claude.enable;
      message = ''
        dotfiles.claude.privateSkills.enable が true ですが dotfiles.claude.enable が false です。
        claude-skills は ~/.claude に繋ぐ Claude Code の skill 置き場なので、Claude Code を入れるホストでだけ有効にしてください
        (claude.enable = true; も書く)。
      '';
    }
    {
      assertion = cfg.claude.devTracker.enable -> cfg.claude.privateSkills.enable;
      message = ''
        dotfiles.claude.devTracker.enable が true ですが dotfiles.claude.privateSkills.enable が false です。
        Dev Tracker の skill (pjp-dev-tracker) は claude-skills にあるので、claude.privateSkills.enable = true; も書いてください
        (設定グループが company・client のホストでは、既定で false です)。
      '';
    }
    {
      assertion = cfg.herdr.hub.enable -> (cfg.herdr.enable && cfg.claude.privateSkills.enable);
      message = ''
        dotfiles.herdr.hub.enable が true ですが dotfiles.herdr.enable か dotfiles.claude.privateSkills.enable が false です。
        集約ハブ ~/h は herdr の会話の受け口で、作る hub-init.sh は claude-skills にあります。両方を true にしてください。
      '';
    }
  ];

  home.file.".local/state/dotfiles/group.json".text =
    builtins.toJSON {
      version = 1;
      inherit (cfg) group;
      tiers = {
        aiTools = cfg.aiTools.enable;
        personalAccounts = cfg.personalAccounts.enable;
      };
      tools = builtins.listToAttrs (
        map (t: {
          name = t.key;
          value = lib.getAttrFromPath t.option cfg;
        }) groups.tools
      );
    }
    + "\n";
}
